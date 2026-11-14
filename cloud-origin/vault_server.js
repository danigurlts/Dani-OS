const crypto = require("node:crypto");
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");

const MASTER_KEY_HEX = process.env.DANIOS_VAULT_MASTER_KEY || "";
if (!MASTER_KEY_HEX || MASTER_KEY_HEX.length !== 64 || !/^[a-f0-9]{64}$/i.test(MASTER_KEY_HEX)) {
  console.error("FATAL: DANIOS_VAULT_MASTER_KEY must be a valid 64-character hex string (32 bytes).");
  process.exit(1);
}
const MASTER_KEY = Buffer.from(MASTER_KEY_HEX, "hex");

function encryptSecretAtRest(plaintextSecret) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", MASTER_KEY, iv);
  const encrypted = Buffer.concat([cipher.update(plaintextSecret, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return {
    version: 1,
    iv: iv.toString("base64"),
    tag: tag.toString("base64"),
    ciphertext: encrypted.toString("base64")
  };
}

function decryptSecretAtRest(encryptedObj) {
  try {
    const iv = Buffer.from(encryptedObj.iv, "base64");
    const tag = Buffer.from(encryptedObj.tag, "base64");
    const ciphertext = Buffer.from(encryptedObj.ciphertext, "base64");
    const decipher = crypto.createDecipheriv("aes-256-gcm", MASTER_KEY, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
  } catch (err) {
    throw new Error(`SecurityFault [VaultDecryptionFailed]: Unable to decrypt record. Master key mismatch or corruption: ${err.message}`);
  }
}

async function atomicWriteJson(filePath, dataObj) {
  const dir = path.dirname(filePath);
  await fsp.mkdir(dir, { recursive: true });
  const tempPath = path.join(dir, `binding.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`);
  await fsp.writeFile(tempPath, JSON.stringify(dataObj, null, 2), { encoding: "utf8", flag: "w" });
  await fsp.rename(tempPath, filePath);
}

async function resolveSecretForFingerprint(fingerprint, CONFIG) {
  const bindingFile = path.join(CONFIG.storageDir, fingerprint, "binding.json");
  try {
    if (!fs.existsSync(bindingFile)) {
      if (CONFIG.allowAutoBindNewFingerprints && CONFIG.defaultAccountSecret) {
        return { secret: CONFIG.defaultAccountSecret, isBound: false };
      }
      return { secret: null, isBound: false };
    }

    const raw = await fsp.readFile(bindingFile, "utf8");
    const parsed = JSON.parse(raw);
    
    if (parsed && typeof parsed.accountSecret === "string" && !parsed.ciphertext) {
      console.warn(`[Vault] Migrating legacy plaintext binding for fingerprint: ${fingerprint}`);
      const encryptedPayload = encryptSecretAtRest(parsed.accountSecret);
      const migratedRecord = { fingerprint, ...encryptedPayload, migratedAtUtc: new Date().toISOString() };
      await atomicWriteJson(bindingFile, migratedRecord);
      return { secret: parsed.accountSecret, isBound: true };
    }

    if (parsed && parsed.ciphertext && parsed.iv && parsed.tag) {
      const secret = decryptSecretAtRest(parsed);
      return { secret, isBound: true };
    }

    throw new Error("Malformed binding record structure.");
  } catch (err) {
    console.error(`[Vault] FATAL: Failed to resolve secret for ${fingerprint}: ${err.message}`);
    throw err;
  }
}
module.exports = { encryptSecretAtRest, decryptSecretAtRest, resolveSecretForFingerprint, atomicWriteJson };
