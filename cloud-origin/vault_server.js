const crypto = require("node:crypto");
const fsp = require("node:fs/promises");
const path = require("node:path");

const MASTER_KEY_HEX = process.env.DANIOS_VAULT_MASTER_KEY || "";
if (!/^[a-f0-9]{64}$/i.test(MASTER_KEY_HEX)) {
  console.error("FATAL: DANIOS_VAULT_MASTER_KEY must be a valid 64-character hex string (32 bytes).");
  process.exit(1);
}
const MASTER_KEY = Buffer.from(MASTER_KEY_HEX, "hex");
const FINGERPRINT_PATTERN = /^[a-f0-9]{64}$/i;
const BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

function decodeBase64(value, expectedLength, fieldName) {
  if (typeof value !== "string" || !BASE64_PATTERN.test(value)) {
    throw new TypeError(`Invalid vault record field: ${fieldName}.`);
  }
  const decoded = Buffer.from(value, "base64");
  if (expectedLength !== null && decoded.length !== expectedLength) {
    throw new TypeError(`Invalid vault record field length: ${fieldName}.`);
  }
  return decoded;
}

function encryptSecretAtRest(plaintextSecret) {
  if (typeof plaintextSecret !== "string" || plaintextSecret.length === 0) {
    throw new TypeError("Vault secret must be a non-empty string.");
  }
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", MASTER_KEY, iv);
  const encrypted = Buffer.concat([cipher.update(plaintextSecret, "utf8"), cipher.final()]);
  return {
    version: 1,
    iv: iv.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
    ciphertext: encrypted.toString("base64")
  };
}

function decryptSecretAtRest(encryptedObj) {
  try {
    if (!encryptedObj || encryptedObj.version !== 1) {
      throw new TypeError("Unsupported or malformed vault record.");
    }
    const iv = decodeBase64(encryptedObj.iv, 12, "iv");
    const tag = decodeBase64(encryptedObj.tag, 16, "tag");
    const ciphertext = decodeBase64(encryptedObj.ciphertext, null, "ciphertext");
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
    if (stat.isSymbolicLink()) {
      throw new Error("VaultPathSymlinkBlocked");
    }
    return stat;
  } catch (error) {
    if (allowMissing && error.code === "ENOENT") return null;
    throw error;
  }
}

async function atomicWriteJson(filePath, dataObj) {
  const dir = path.dirname(path.resolve(filePath));
  await fsp.mkdir(dir, { recursive: true, mode: 0o700 });
  await assertNotSymlink(dir);
  await assertNotSymlink(filePath, { allowMissing: true });

  const tempPath = path.join(dir, `binding.${process.pid}.${crypto.randomBytes(16).toString("hex")}.tmp`);
  let handle;
  try {
    handle = await fsp.open(tempPath, "wx", 0o600);
    await handle.writeFile(JSON.stringify(dataObj, null, 2), { encoding: "utf8" });
    await handle.sync();
    await handle.close();
    handle = null;
    await assertNotSymlink(filePath, { allowMissing: true });
    await fsp.rename(tempPath, filePath);
    if (process.platform !== "win32") await fsp.chmod(filePath, 0o600);
  } finally {
    if (handle) await handle.close();
    await fsp.rm(tempPath, { force: true }).catch(() => {});
  }
}

async function resolveSecretForFingerprint(fingerprint, CONFIG) {
  if (typeof fingerprint !== "string" || !FINGERPRINT_PATTERN.test(fingerprint)) {
    throw new TypeError("Invalid vault fingerprint.");
  }
  if (!CONFIG || typeof CONFIG.storageDir !== "string" || CONFIG.storageDir.length === 0) {
    throw new TypeError("Vault storageDir must be configured.");
  }

  const configuredRoot = path.resolve(CONFIG.storageDir);
  await fsp.mkdir(configuredRoot, { recursive: true, mode: 0o700 });
  const rootStat = await assertNotSymlink(configuredRoot);
  if (!rootStat.isDirectory()) throw new Error("VaultStorageRootNotDirectory");
  const storageRoot = await fsp.realpath(configuredRoot);
  if (storageRoot !== configuredRoot) throw new Error("VaultStorageRootCanonicalizationFailed");

  const fingerprintDir = path.join(storageRoot, fingerprint);
  const bindingFile = path.join(fingerprintDir, "binding.json");
  try {
    const fingerprintStat = await assertNotSymlink(fingerprintDir, { allowMissing: true });
    if (fingerprintStat && !fingerprintStat.isDirectory()) throw new Error("VaultFingerprintPathNotDirectory");
    if (!fingerprintStat) {
      if (CONFIG.allowAutoBindNewFingerprints && CONFIG.defaultAccountSecret) {
        return { secret: CONFIG.defaultAccountSecret, isBound: false };
      }
      return { secret: null, isBound: false };
    }

    const bindingStat = await assertNotSymlink(bindingFile);
    if (!bindingStat.isFile()) throw new Error("VaultBindingPathNotFile");
    const raw = await fsp.readFile(bindingFile, "utf8");
    const parsed = JSON.parse(raw);

    if (parsed && typeof parsed.accountSecret === "string" && !parsed.ciphertext) {
      const encryptedPayload = encryptSecretAtRest(parsed.accountSecret);
      const migratedRecord = { fingerprint, ...encryptedPayload, migratedAtUtc: new Date().toISOString() };
      await atomicWriteJson(bindingFile, migratedRecord);
      return { secret: parsed.accountSecret, isBound: true };
    }

    if (parsed && parsed.fingerprint === fingerprint && parsed.version === 1) {
      return { secret: decryptSecretAtRest(parsed), isBound: true };
    }

    throw new Error("Malformed binding record structure.");
  } catch (error) {
    console.error(`[Vault] FATAL: Failed to resolve secret for fingerprint ${fingerprint}: ${error.message}`);
    throw error;
  }
}

module.exports = { encryptSecretAtRest, decryptSecretAtRest, resolveSecretForFingerprint, atomicWriteJson };
