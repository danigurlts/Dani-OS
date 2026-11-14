#!/usr/bin/env node
"use strict";

const http = require("node:http");
const crypto = require("node:crypto");
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");

const CONFIG_PATH = process.env.DANIOS_VAULT_CONFIG || path.join(__dirname, "vault.config.json");

function loadConfig() {
  let fileCfg = {};
  if (fs.existsSync(CONFIG_PATH)) {
    fileCfg = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  }

  return {
    host: process.env.DANIOS_VAULT_HOST || fileCfg.host || "0.0.0.0",
    port: Number(process.env.DANIOS_VAULT_PORT || fileCfg.port || 8443),
    storageDir: path.resolve(process.env.DANIOS_VAULT_STORAGE || fileCfg.storageDir || path.join(__dirname, "vault_data")),
    defaultAccountSecret: process.env.DANIOS_VAULT_SECRET || fileCfg.defaultAccountSecret || "",
    maxClockSkewSec: Number(fileCfg.maxClockSkewSec || 300),
    maxPayloadBytes: Number(fileCfg.maxPayloadBytes || 262144),
    retainRevisions: Math.max(1, Number(fileCfg.retainRevisions || 3)),
    allowAutoBindNewFingerprints: fileCfg.allowAutoBindNewFingerprints !== false
  };
}

const CONFIG = loadConfig();
fs.mkdirSync(CONFIG.storageDir, { recursive: true });

const FINGERPRINT_REGEX = /^[a-f0-9]{64}$/;
const SHA256_HEX_REGEX = /^[a-f0-9]{64}$/;
const ROUTE_REGEX = /^(?:\/api)?\/v1\/savepoints\/([a-f0-9]{64})$/;

function readRawBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalBytes = 0;
    req.on("data", (chunk) => {
      totalBytes += chunk.length;
      if (totalBytes > maxBytes) {
        req.destroy();
        reject(Object.assign(new Error("PayloadTooLarge"), { statusCode: 413 }));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", (err) => reject(err));
  });
}

function sendJson(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store"
  });
  res.end(body);
}

async function resolveSecretForFingerprint(fingerprint) {
  const bindingFile = path.join(CONFIG.storageDir, fingerprint, "binding.json");
  try {
    const raw = await fsp.readFile(bindingFile, "utf8");
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed.accountSecret === "string" && parsed.accountSecret.length > 0) {
      return { secret: parsed.accountSecret, isBound: true };
    }
  } catch {}

  if (CONFIG.allowAutoBindNewFingerprints && CONFIG.defaultAccountSecret) {
    return { secret: CONFIG.defaultAccountSecret, isBound: false };
  }
  return { secret: null, isBound: false };
}

async function authenticateRequest(req, routeFingerprint, rawBodyBuffer) {
  const headerFp = String(req.headers["x-danios-fingerprint"] || "").toLowerCase();
  const timestampStr = String(req.headers["x-danios-timestamp"] || "");
  const headerBodyHash = String(req.headers["x-danios-body-sha256"] || "").toLowerCase();
  const headerSignature = String(req.headers["x-danios-signature"] || "").toLowerCase();

  if (!FINGERPRINT_REGEX.test(headerFp) || headerFp !== routeFingerprint) {
    throw Object.assign(new Error("FingerprintMismatch"), { statusCode: 401 });
  }
  if (!SHA256_HEX_REGEX.test(headerBodyHash) || !SHA256_HEX_REGEX.test(headerSignature)) {
    throw Object.assign(new Error("MalformedSecurityHeaders"), { statusCode: 401 });
  }

  const reqEpochSec = Number(timestampStr);
  const nowEpochSec = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(reqEpochSec) || Math.abs(nowEpochSec - reqEpochSec) > CONFIG.maxClockSkewSec) {
    throw Object.assign(new Error("TimestampOutOfWindow"), { statusCode: 401 });
  }

  const computedBodyHash = crypto.createHash("sha256").update(rawBodyBuffer).digest("hex");
  if (computedBodyHash !== headerBodyHash) {
    throw Object.assign(new Error("BodyIntegrityMismatch"), { statusCode: 400 });
  }

  const { secret, isBound } = await resolveSecretForFingerprint(routeFingerprint);
  if (!secret) {
    throw Object.assign(new Error("UnregisteredDeviceFingerprint"), { statusCode: 403 });
  }

  const method = (req.method || "GET").toUpperCase();
  const canonical = `${method}|${routeFingerprint}|${timestampStr}|${computedBodyHash}`;
  const expectedSigHex = crypto.createHmac("sha256", secret).update(canonical, "utf8").digest("hex");

  const providedBuf = Buffer.from(headerSignature, "hex");
  const expectedBuf = Buffer.from(expectedSigHex, "hex");

  if (providedBuf.length !== expectedBuf.length || !crypto.timingSafeEqual(providedBuf, expectedBuf)) {
    throw Object.assign(new Error("InvalidHmacSignature"), { statusCode: 401 });
  }

  return { secret, isBound };
}

function validateEncryptedEnvelope(rawBuffer, expectedFingerprint) {
  let parsed;
  try {
    parsed = JSON.parse(rawBuffer.toString("utf8"));
  } catch {
    throw Object.assign(new Error("InvalidJsonPayload"), { statusCode: 400 });
  }

  if (!parsed || typeof parsed !== "object" || String(parsed.fingerprint || "").toLowerCase() !== expectedFingerprint) {
    throw Object.assign(new Error("EnvelopeFingerprintMismatch"), { statusCode: 400 });
  }

  const nonceBytes = Buffer.from(String(parsed.nonce || ""), "base64");
  const tagBytes = Buffer.from(String(parsed.tag || ""), "base64");
  const cipherBytes = Buffer.from(String(parsed.ciphertext || ""), "base64");

  if (nonceBytes.length !== 12 || tagBytes.length !== 16 || cipherBytes.length === 0) {
    throw Object.assign(new Error("InvalidAesGcmParameters"), { statusCode: 400 });
  }

  return parsed;
}

async function storeSavePoint(fingerprint, envelope, secret, wasAlreadyBound) {
  const deviceDir = path.join(CONFIG.storageDir, fingerprint);
  await fsp.mkdir(deviceDir, { recursive: true });

  if (!wasAlreadyBound) {
    const bindingTmp = path.join(deviceDir, `binding.${process.pid}.tmp`);
    const bindingFinal = path.join(deviceDir, "binding.json");
    await fsp.writeFile(bindingTmp, JSON.stringify({ fingerprint, accountSecret: secret, boundAtUtc: new Date().toISOString() }, null, 2), "utf8");
    await fsp.rename(bindingTmp, bindingFinal);
  }

  const latestPath = path.join(deviceDir, "latest.json");
  let nextRevision = 1;
  try {
    const prevDoc = JSON.parse(await fsp.readFile(latestPath, "utf8"));
    nextRevision = Number(prevDoc.revision || 0) + 1;
  } catch {}

  const record = {
    fingerprint,
    revision: nextRevision,
    storedAtUtc: new Date().toISOString(),
    nonce: envelope.nonce,
    tag: envelope.tag,
    ciphertext: envelope.ciphertext,
    meta: envelope.meta || {}
  };

  const serialized = JSON.stringify(record, null, 2);
  const revPath = path.join(deviceDir, `rev_${nextRevision}.json`);
  const tmpLatest = path.join(deviceDir, `latest.${Date.now()}.tmp`);

  await fsp.writeFile(revPath, serialized, "utf8");
  await fsp.writeFile(tmpLatest, serialized, "utf8");
  await fsp.rename(tmpLatest, latestPath);

  const files = await fsp.readdir(deviceDir);
  const revNumbers = files.map((f) => { const m = f.match(/^rev_(\d+)\.json$/); return m ? Number(m[1]) : null; }).filter((n) => n !== null).sort((a, b) => b - a);
  for (const oldRev of revNumbers.slice(CONFIG.retainRevisions)) {
    await fsp.unlink(path.join(deviceDir, `rev_${oldRev}.json`)).catch(() => {});
  }

  return record;
}

const server = http.createServer(async (req, res) => {
  try {
    const reqUrl = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
    const pathname = reqUrl.pathname;

    if (req.method === "GET" && (pathname === "/health" || pathname === "/api/health")) {
      sendJson(res, 200, { ok: true, service: "DaniOs-Cloud-Origin", timestampUtc: new Date().toISOString() });
      return;
    }

    const match = pathname.match(ROUTE_REGEX);
    if (!match) { sendJson(res, 404, { ok: false, error: "EndpointNotFound" }); return; }

    const fingerprint = match[1];
    const method = (req.method || "").toUpperCase();
    if (method !== "PUT" && method !== "GET") { sendJson(res, 405, { ok: false, error: "MethodNotAllowed" }); return; }

    const rawBody = await readRawBody(req, CONFIG.maxPayloadBytes);
    const auth = await authenticateRequest(req, fingerprint, rawBody);

    if (method === "PUT") {
      const envelope = validateEncryptedEnvelope(rawBody, fingerprint);
      const saved = await storeSavePoint(fingerprint, envelope, auth.secret, auth.isBound);
      sendJson(res, 200, { ok: true, fingerprint, revision: saved.revision, storedAtUtc: saved.storedAtUtc });
      return;
    }

    if (method === "GET") {
      const latestPath = path.join(CONFIG.storageDir, fingerprint, "latest.json");
      let rawStored;
      try { rawStored = await fsp.readFile(latestPath, "utf8"); }
      catch { sendJson(res, 404, { ok: false, error: "SavePointNotFound" }); return; }
      sendJson(res, 200, JSON.parse(rawStored));
    }
  } catch (err) {
    sendJson(res, Number(err.statusCode || 500), { ok: false, error: err.message || "InternalVaultError" });
  }
});

server.listen(CONFIG.port, CONFIG.host, () => {
  process.stdout.write(`[DaniOs::CloudOrigin] Listening on http://${CONFIG.host}:${CONFIG.port} | Storage: ${CONFIG.storageDir}\n`);
});
