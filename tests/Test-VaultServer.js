"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs/promises");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const vaultServerPath = path.resolve(__dirname, "../cloud-origin/vault_server.js");

async function reservePort() {
  const socket = net.createServer();
  await new Promise((resolve, reject) => socket.listen(0, "127.0.0.1", resolve).once("error", reject));
  const { port } = socket.address();
  await new Promise(resolve => socket.close(resolve));
  return port;
}

async function waitForHealth(baseUrl, child, getStderr) {
  for (let attempt = 0; attempt < 50; attempt++) {
    if (child.exitCode !== null) throw new Error(`Vault exited before becoming ready: ${getStderr()}`);
    try {
      const response = await fetch(`${baseUrl}/health`);
      if (response.ok) return;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`Vault health endpoint did not become ready: ${getStderr()}`);
}

async function signedRequest(baseUrl, fingerprint, secret, method, body, invalidSignature = false) {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const bodyHash = crypto.createHash("sha256").update(body).digest("hex");
  const canonical = `${method}|${fingerprint}|${timestamp}|${bodyHash}`;
  const signature = crypto.createHmac("sha256", secret).update(canonical).digest("hex");
  const options = {
    method,
    headers: {
      "x-danios-fingerprint": fingerprint,
      "x-danios-timestamp": timestamp,
      "x-danios-body-sha256": bodyHash,
      "x-danios-signature": invalidSignature ? "0".repeat(64) : signature
    }
  };
  if (method === "PUT") {
    options.headers["content-type"] = "application/json";
    options.body = body;
  }
  return fetch(`${baseUrl}/api/v1/savepoints/${fingerprint}`, options);
}

async function main() {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "danios-vault-test-"));
  let child;
  try {
    const storageDir = path.join(tempRoot, "storage");
    const configPath = path.join(tempRoot, "vault.config.json");
    const accountSecret = "vault-test-account-secret";
    const port = await reservePort();
    await fs.writeFile(configPath, JSON.stringify({
      host: "127.0.0.1",
      port,
      storageDir,
      defaultAccountSecret: accountSecret,
      allowHttp: true,
      retainRevisions: 1
    }));

    const childEnv = {
      ...process.env,
      DANIOS_VAULT_MASTER_KEY: crypto.randomBytes(32).toString("hex"),
      DANIOS_VAULT_SECRET: accountSecret,
      DANIOS_VAULT_CONFIG: configPath
    };
    child = spawn(process.execPath, [vaultServerPath], { env: childEnv, stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.setEncoding("utf8").on("data", chunk => { stderr += chunk; });
    const baseUrl = `http://127.0.0.1:${port}`;
    await waitForHealth(baseUrl, child, () => stderr);

    const httpDisabled = spawnSync(process.execPath, [vaultServerPath], {
      env: { ...childEnv, DANIOS_VAULT_ALLOW_HTTP: "false" },
      encoding: "utf8",
      timeout: 5000
    });
    assert.notEqual(httpDisabled.status, 0);
    assert.match(httpDisabled.stderr, /TLS is required/);
    const nonLoopbackHttp = spawnSync(process.execPath, [vaultServerPath], {
      env: { ...childEnv, DANIOS_VAULT_ALLOW_HTTP: "true", DANIOS_VAULT_HOST: "0.0.0.0" },
      encoding: "utf8",
      timeout: 5000
    });
    assert.notEqual(nonLoopbackHttp.status, 0);
    assert.match(nonLoopbackHttp.stderr, /Development HTTP may only bind to loopback/);

    const fingerprint = crypto.createHash("sha256").update("vault-test-device").digest("hex");
    const envelope = {
      fingerprint,
      nonce: Buffer.alloc(12, 1).toString("base64"),
      tag: Buffer.alloc(16, 2).toString("base64"),
      ciphertext: Buffer.from("opaque-encrypted-state").toString("base64"),
      meta: { schema: "vault-test" }
    };
    const body = JSON.stringify(envelope);

    let response = await signedRequest(baseUrl, fingerprint, accountSecret, "PUT", body);
    assert.equal(response.status, 200, await response.clone().text());
    assert.equal((await response.json()).revision, 1);

    response = await signedRequest(baseUrl, fingerprint, accountSecret, "GET", "");
    assert.equal(response.status, 200, await response.clone().text());
    const restored = await response.json();
    assert.equal(restored.fingerprint, fingerprint);
    assert.equal(restored.ciphertext, envelope.ciphertext);

    response = await signedRequest(baseUrl, fingerprint, accountSecret, "PUT", body, true);
    assert.equal(response.status, 401);

    const concurrentResponses = await Promise.all([
      signedRequest(baseUrl, fingerprint, accountSecret, "PUT", body),
      signedRequest(baseUrl, fingerprint, accountSecret, "PUT", body)
    ]);
    const concurrentRevisions = await Promise.all(concurrentResponses.map(async item => {
      assert.equal(item.status, 200, await item.clone().text());
      return (await item.json()).revision;
    }));
    assert.deepEqual(concurrentRevisions.sort((a, b) => a - b), [2, 3]);

    const binding = JSON.parse(await fs.readFile(path.join(storageDir, fingerprint, "binding.json"), "utf8"));
    assert.equal(binding.accountSecret, undefined);
    assert.equal(binding.version, 1);
    const revisions = (await fs.readdir(path.join(storageDir, fingerprint)))
      .filter(name => /^rev_\d+\.json$/.test(name));
    assert.deepEqual(revisions, ["rev_3.json"]);

    const legacyFingerprint = crypto.createHash("sha256").update("legacy-vault-test-device").digest("hex");
    const legacyDirectory = path.join(storageDir, legacyFingerprint);
    await fs.mkdir(legacyDirectory, { recursive: true });
    await fs.writeFile(path.join(legacyDirectory, "binding.json"), JSON.stringify({ fingerprint: legacyFingerprint, accountSecret, boundAtUtc: new Date().toISOString() }));
    response = await signedRequest(baseUrl, legacyFingerprint, accountSecret, "GET", "");
    assert.equal(response.status, 404);
    const migratedBinding = JSON.parse(await fs.readFile(path.join(legacyDirectory, "binding.json"), "utf8"));
    assert.equal(migratedBinding.accountSecret, undefined);
    assert.equal(migratedBinding.fingerprint, legacyFingerprint);
    assert.equal(migratedBinding.version, 1);

    process.stdout.write("Vault route integration passed.\n");
  } finally {
    if (child && child.exitCode === null) {
      child.kill();
      await new Promise(resolve => child.once("exit", resolve));
    }
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
