#!/usr/bin/env node
"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const http = require("node:http");
const https = require("node:https");
const path = require("node:path");

const CONFIG_PATH = process.env.DANIOS_VAULT_CONFIG || path.join(__dirname, "vault.config.json");
const FINGERPRINT_PATTERN = /^[a-f0-9]{64}$/i;
const SHA256_PATTERN = /^[a-f0-9]{64}$/i;
const BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const MASTER_KEY_HEX = process.env.DANIOS_VAULT_MASTER_KEY || "";

if (!/^[a-f0-9]{64}$/i.test(MASTER_KEY_HEX)) {
  throw new Error("DANIOS_VAULT_MASTER_KEY must be a 64-character hex string (32 bytes).");
}
const MASTER_KEY = Buffer.from(MASTER_KEY_HEX, "hex");

function loadConfig() {
  let fileConfig = {};
  if (fs.existsSync(CONFIG_PATH)) {
    fileConfig = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  }

  const allowHttp = process.env.DANIOS_VAULT_ALLOW_HTTP !== undefined
    ? process.env.DANIOS_VAULT_ALLOW_HTTP.toLowerCase() === "true"
    : fileConfig.allowHttp === true;
  const configuredStorage = process.env.DANIOS_VAULT_STORAGE
    ? path.resolve(process.env.DANIOS_VAULT_STORAGE)
    : fileConfig.storageDir
      ? path.resolve(path.dirname(path.resolve(CONFIG_PATH)), fileConfig.storageDir)
      : path.join(__dirname, "vault_data");
  const configuredTlsKey = process.env.DANIOS_VAULT_TLS_KEY
    ? path.resolve(process.env.DANIOS_VAULT_TLS_KEY)
    : fileConfig.tls?.keyFile
      ? path.resolve(path.dirname(path.resolve(CONFIG_PATH)), fileConfig.tls.keyFile)
      : "";
  const configuredTlsCert = process.env.DANIOS_VAULT_TLS_CERT
    ? path.resolve(process.env.DANIOS_VAULT_TLS_CERT)
    : fileConfig.tls?.certFile
      ? path.resolve(path.dirname(path.resolve(CONFIG_PATH)), fileConfig.tls.certFile)
      : "";
  const config = {
    host: process.env.DANIOS_VAULT_HOST || fileConfig.host || "127.0.0.1",
    port: Number(process.env.DANIOS_VAULT_PORT || fileConfig.port || 8443),
    storageDir: configuredStorage,
    defaultAccountSecret: process.env.DANIOS_VAULT_SECRET || fileConfig.defaultAccountSecret || "",
    maxClockSkewSec: Number(fileConfig.maxClockSkewSec || 300),
    maxPayloadBytes: Number(fileConfig.maxPayloadBytes || 262144),
    retainRevisions: Math.max(1, Number(fileConfig.retainRevisions || 3)),
    allowAutoBindNewFingerprints: fileConfig.allowAutoBindNewFingerprints !== false,
    allowHttp,
    tlsKeyFile: configuredTlsKey,
    tlsCertFile: configuredTlsCert
  };

  if (typeof config.host !== "string" || config.host.length === 0) throw new Error("Vault host is invalid.");
  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535) throw new Error("Vault port is invalid.");
  if (!Number.isFinite(config.maxClockSkewSec) || config.maxClockSkewSec < 1) throw new Error("Vault maxClockSkewSec is invalid.");
  if (!Number.isSafeInteger(config.maxPayloadBytes) || config.maxPayloadBytes < 1) throw new Error("Vault maxPayloadBytes is invalid.");
  if (!Number.isSafeInteger(config.retainRevisions) || config.retainRevisions < 1) throw new Error("Vault retainRevisions is invalid.");
  if (config.defaultAccountSecret === "REPLACE_WITH_PROVISIONED_ACCOUNT_SECRET") config.defaultAccountSecret = "";
  return config;
}

const CONFIG = loadConfig();
const hasTlsKey = Boolean(CONFIG.tlsKeyFile);
const hasTlsCert = Boolean(CONFIG.tlsCertFile);

const ROUTE_PATTERN = /^(?:\/api)?\/v1\/savepoints\/([a-f0-9]{64})$/i;
const savePointQueues = new Map();

function decodeBase64(value, expectedLength, fieldName) {
  if (typeof value !== "string" || !BASE64_PATTERN.test(value)) throw Object.assign(new Error(`Invalid${fieldName}`), { statusCode: 400 });
  const decoded = Buffer.from(value, "base64");
  if (expectedLength !== null && decoded.length !== expectedLength) throw Object.assign(new Error(`Invalid${fieldName}`), { statusCode: 400 });
  return decoded;
}

function encryptSecretAtRest(plaintextSecret) {
  if (typeof plaintextSecret !== "string" || plaintextSecret.length === 0) throw new TypeError("Vault secret must be a non-empty string.");
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", MASTER_KEY, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintextSecret, "utf8"), cipher.final()]);
  return { version: 1, iv: iv.toString("base64"), tag: cipher.getAuthTag().toString("base64"), ciphertext: ciphertext.toString("base64") };
}

function decryptSecretAtRest(record) {
  try {
    if (!record || record.version !== 1) throw new TypeError("Unsupported vault record.");
    const iv = decodeBase64(record.iv, 12, "VaultRecordIv");
    const tag = decodeBase64(record.tag, 16, "VaultRecordTag");
    const ciphertext = decodeBase64(record.ciphertext, null, "VaultRecordCiphertext");
    const decipher = crypto.createDecipheriv("aes-256-gcm", MASTER_KEY, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
  } catch {
    throw new Error("SecurityFault [VaultDecryptionFailed]: Unable to decrypt record; key mismatch or corrupt data.");
  }
}

async function assertNotSymlink(targetPath, { allowMissing = false } = {}) {
  try {
    const stat = await fsp.lstat(targetPath);
    if (stat.isSymbolicLink()) throw new Error("VaultPathSymlinkBlocked");
    return stat;
  } catch (error) {
    if (allowMissing && error.code === "ENOENT") return null;
    throw error;
  }
}

async function atomicWriteJson(filePath, data) {
  const resolved = path.resolve(filePath);
  const directory = path.dirname(resolved);
  await fsp.mkdir(directory, { recursive: true, mode: 0o700 });
  await assertNotSymlink(directory);
  await assertNotSymlink(resolved, { allowMissing: true });
  const tempPath = path.join(directory, `vault.${process.pid}.${crypto.randomBytes(16).toString("hex")}.tmp`);
  let handle;
  try {
    handle = await fsp.open(tempPath, "wx", 0o600);
    await handle.writeFile(JSON.stringify(data, null, 2), "utf8");
    await handle.sync();
    await handle.close();
    handle = null;
    await assertNotSymlink(resolved, { allowMissing: true });
    await fsp.rename(tempPath, resolved);
    if (process.platform !== "win32") await fsp.chmod(resolved, 0o600);
  } finally {
    if (handle) await handle.close();
    await fsp.rm(tempPath, { force: true }).catch(() => {});
  }
}

async function resolveSecretForFingerprint(fingerprint) {
  if (typeof fingerprint !== "string" || !FINGERPRINT_PATTERN.test(fingerprint)) throw new TypeError("Invalid vault fingerprint.");
  await fsp.mkdir(CONFIG.storageDir, { recursive: true, mode: 0o700 });
  await assertNotSymlink(CONFIG.storageDir);
  const storageRoot = await fsp.realpath(CONFIG.storageDir);
  if (storageRoot !== CONFIG.storageDir) throw new Error("VaultStorageRootCanonicalizationFailed");

  const deviceDir = path.join(storageRoot, fingerprint);
  const bindingPath = path.join(deviceDir, "binding.json");
  const deviceStat = await assertNotSymlink(deviceDir, { allowMissing: true });
  if (!deviceStat) {
    return CONFIG.allowAutoBindNewFingerprints && CONFIG.defaultAccountSecret
      ? { secret: CONFIG.defaultAccountSecret, isBound: false }
      : { secret: null, isBound: false };
  }
  if (!deviceStat.isDirectory()) throw new Error("VaultFingerprintPathNotDirectory");

  const bindingStat = await assertNotSymlink(bindingPath);
  if (!bindingStat.isFile()) throw new Error("VaultBindingPathNotFile");
  const record = JSON.parse(await fsp.readFile(bindingPath, "utf8"));
  if (record && typeof record.accountSecret === "string" && record.accountSecret.length > 0 && !record.ciphertext) {
    const migratedRecord = {
      fingerprint,
      ...encryptSecretAtRest(record.accountSecret),
      migratedAtUtc: new Date().toISOString()
    };
    await atomicWriteJson(bindingPath, migratedRecord);
    return { secret: record.accountSecret, isBound: true };
  }
  if (record.fingerprint !== fingerprint || record.version !== 1) throw new Error("MalformedBindingRecord");
  return { secret: decryptSecretAtRest(record), isBound: true };
}

function readRawBody(request, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let rejected = false;
    request.on("data", chunk => {
      if (rejected) return;
      total += chunk.length;
      if (total > maxBytes) {
        rejected = true;
        reject(Object.assign(new Error("PayloadTooLarge"), { statusCode: 413 }));
        request.resume();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => { if (!rejected) resolve(Buffer.concat(chunks)); });
    request.on("error", error => { if (!rejected) reject(error); });
  });
}

function sendJson(response, statusCode, data) {
  if (response.headersSent || response.destroyed) return;
  const body = JSON.stringify(data);
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff"
  });
  response.end(body);
}

async function authenticateRequest(request, fingerprint, rawBody) {
  const headerFingerprint = String(request.headers["x-danios-fingerprint"] || "").toLowerCase();
  const timestamp = String(request.headers["x-danios-timestamp"] || "");
  const bodyHash = String(request.headers["x-danios-body-sha256"] || "").toLowerCase();
  const signature = String(request.headers["x-danios-signature"] || "").toLowerCase();
  if (!FINGERPRINT_PATTERN.test(headerFingerprint) || headerFingerprint !== fingerprint) throw Object.assign(new Error("FingerprintMismatch"), { statusCode: 401 });
  if (!SHA256_PATTERN.test(bodyHash) || !SHA256_PATTERN.test(signature) || !/^\d{1,12}$/.test(timestamp)) throw Object.assign(new Error("MalformedSecurityHeaders"), { statusCode: 401 });
  const epoch = Number(timestamp);
  if (Math.abs(Math.floor(Date.now() / 1000) - epoch) > CONFIG.maxClockSkewSec) throw Object.assign(new Error("TimestampOutOfWindow"), { statusCode: 401 });
  const computedHash = crypto.createHash("sha256").update(rawBody).digest("hex");
  if (computedHash !== bodyHash) throw Object.assign(new Error("BodyIntegrityMismatch"), { statusCode: 400 });
  const { secret, isBound } = await resolveSecretForFingerprint(fingerprint);
  if (!secret) throw Object.assign(new Error("UnregisteredDeviceFingerprint"), { statusCode: 403 });
  const canonical = `${request.method.toUpperCase()}|${fingerprint}|${timestamp}|${computedHash}`;
  const expected = crypto.createHmac("sha256", secret).update(canonical, "utf8").digest();
  const supplied = Buffer.from(signature, "hex");
  if (supplied.length !== expected.length || !crypto.timingSafeEqual(supplied, expected)) throw Object.assign(new Error("InvalidHmacSignature"), { statusCode: 401 });
  return { secret, isBound };
}

function validateEnvelope(rawBody, fingerprint) {
  let envelope;
  try { envelope = JSON.parse(rawBody.toString("utf8")); }
  catch { throw Object.assign(new Error("InvalidJsonPayload"), { statusCode: 400 }); }
  if (!envelope || typeof envelope !== "object" || Array.isArray(envelope) || String(envelope.fingerprint || "").toLowerCase() !== fingerprint) {
    throw Object.assign(new Error("EnvelopeFingerprintMismatch"), { statusCode: 400 });
  }
  decodeBase64(envelope.nonce, 12, "Nonce");
  decodeBase64(envelope.tag, 16, "Tag");
  const ciphertext = decodeBase64(envelope.ciphertext, null, "Ciphertext");
  if (ciphertext.length === 0) throw Object.assign(new Error("InvalidCiphertext"), { statusCode: 400 });
  if (envelope.meta !== undefined && (!envelope.meta || typeof envelope.meta !== "object" || Array.isArray(envelope.meta))) {
    throw Object.assign(new Error("InvalidEnvelopeMetadata"), { statusCode: 400 });
  }
  return envelope;
}

async function writeSavePoint(fingerprint, envelope, auth) {
  const deviceDir = path.join(CONFIG.storageDir, fingerprint);
  await fsp.mkdir(deviceDir, { recursive: true, mode: 0o700 });
  await assertNotSymlink(CONFIG.storageDir);
  await assertNotSymlink(deviceDir);
  const bindingPath = path.join(deviceDir, "binding.json");
  if (!auth.isBound) {
    const encryptedBinding = { fingerprint, ...encryptSecretAtRest(auth.secret), boundAtUtc: new Date().toISOString() };
    await atomicWriteJson(bindingPath, encryptedBinding);
  }

  const latestPath = path.join(deviceDir, "latest.json");
  let revision = 1;
  try {
    await assertNotSymlink(latestPath);
    const latest = JSON.parse(await fsp.readFile(latestPath, "utf8"));
    if (latest.fingerprint !== fingerprint || !Number.isSafeInteger(latest.revision) || latest.revision < 1) throw new Error("MalformedLatestSavePoint");
    revision = latest.revision + 1;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  const record = {
    fingerprint,
    revision,
    storedAtUtc: new Date().toISOString(),
    nonce: envelope.nonce,
    tag: envelope.tag,
    ciphertext: envelope.ciphertext,
    meta: envelope.meta || {}
  };
  await atomicWriteJson(path.join(deviceDir, `rev_${revision}.json`), record);
  await atomicWriteJson(latestPath, record);

  const entries = await fsp.readdir(deviceDir, { withFileTypes: true });
  const revisions = entries
    .filter(entry => entry.isFile() && /^rev_\d+\.json$/.test(entry.name))
    .map(entry => Number(entry.name.slice(4, -5)))
    .sort((a, b) => b - a);
  for (const oldRevision of revisions.slice(CONFIG.retainRevisions)) {
    const oldPath = path.join(deviceDir, `rev_${oldRevision}.json`);
    await assertNotSymlink(oldPath);
    await fsp.unlink(oldPath);
  }
  return record;
}

async function storeSavePoint(fingerprint, envelope, auth) {
  const previous = savePointQueues.get(fingerprint) || Promise.resolve();
  let release;
  const current = new Promise(resolve => { release = resolve; });
  savePointQueues.set(fingerprint, current);
  await previous;
  try {
    return await writeSavePoint(fingerprint, envelope, auth);
  } finally {
    release();
    if (savePointQueues.get(fingerprint) === current) savePointQueues.delete(fingerprint);
  }
}

async function handleRequest(request, response) {
  try {
    const requestUrl = new URL(request.url || "/", "http://localhost");
    if (request.method === "GET" && ["/health", "/api/health"].includes(requestUrl.pathname)) {
      sendJson(response, 200, { ok: true, service: "DaniOs-Cloud-Origin", timestampUtc: new Date().toISOString() });
      return;
    }
    const match = requestUrl.pathname.match(ROUTE_PATTERN);
    if (!match) { sendJson(response, 404, { ok: false, error: "EndpointNotFound" }); return; }
    const fingerprint = match[1].toLowerCase();
    const method = String(request.method || "").toUpperCase();
    if (method !== "PUT" && method !== "GET") { sendJson(response, 405, { ok: false, error: "MethodNotAllowed" }); return; }

    const body = await readRawBody(request, CONFIG.maxPayloadBytes);
    const auth = await authenticateRequest(request, fingerprint, body);
    if (method === "PUT") {
      const envelope = validateEnvelope(body, fingerprint);
      const saved = await storeSavePoint(fingerprint, envelope, auth);
      sendJson(response, 200, { ok: true, fingerprint, revision: saved.revision, storedAtUtc: saved.storedAtUtc });
      return;
    }

    const latestPath = path.join(CONFIG.storageDir, fingerprint, "latest.json");
    let latest;
    try {
      await assertNotSymlink(path.dirname(latestPath));
      await assertNotSymlink(latestPath);
      latest = JSON.parse(await fsp.readFile(latestPath, "utf8"));
    } catch (error) {
      if (error.code === "ENOENT") { sendJson(response, 404, { ok: false, error: "SavePointNotFound" }); return; }
      throw error;
    }
    if (latest.fingerprint !== fingerprint) throw Object.assign(new Error("SavePointFingerprintMismatch"), { statusCode: 500 });
    sendJson(response, 200, latest);
  } catch (error) {
    sendJson(response, Number(error.statusCode || 500), { ok: false, error: error.message || "InternalVaultError" });
  }
}

const server = CONFIG.tlsKeyFile
  ? https.createServer({ key: fs.readFileSync(CONFIG.tlsKeyFile), cert: fs.readFileSync(CONFIG.tlsCertFile) }, handleRequest)
  : http.createServer(handleRequest);

if (require.main === module) {
  if (hasTlsKey !== hasTlsCert) throw new Error("Configure both DANIOS_VAULT_TLS_KEY and DANIOS_VAULT_TLS_CERT (or both tls config paths).");
  if (!hasTlsKey && !CONFIG.allowHttp) throw new Error("TLS is required unless DANIOS_VAULT_ALLOW_HTTP=true is explicitly set for local development.");
  if (!hasTlsKey && !["127.0.0.1", "::1"].includes(CONFIG.host.toLowerCase())) {
    throw new Error("Development HTTP may only bind to loopback. Configure TLS for a non-local host.");
  }
  server.listen(CONFIG.port, CONFIG.host, () => {
    const protocol = CONFIG.tlsKeyFile ? "https" : "http (development only)";
    process.stdout.write(`[DaniOs::CloudOrigin] Listening on ${protocol}://${CONFIG.host}:${CONFIG.port} | Storage: ${CONFIG.storageDir}\n`);
  });
}

module.exports = { encryptSecretAtRest, decryptSecretAtRest, resolveSecretForFingerprint, atomicWriteJson, authenticateRequest, validateEnvelope, storeSavePoint, server };
