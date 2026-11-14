"use strict";

const fs = require("fs");
const net = require("net");
const path = require("path");
const { compactAndPruneMatrix, parseStructuredStream } = require("./matrix_pruner");
const { DaniServerFactory } = require("./server_factory");

const PIPE_NAME = process.env.DANIOS_PIPE_NAME || "DaniOs.Pipe.Node";
const SESSION_NONCE = process.env.DANIOS_SESSION_NONCE || "";
const HTTP_PORT = Number(process.env.DANIOS_HTTP_PORT || 4110);
const WS_PORT = Number(process.env.DANIOS_WS_PORT || 4111);

if (!SESSION_NONCE) {
  process.stderr.write("[DaniOs::Node] FATAL: Missing DANIOS_SESSION_NONCE in environment.\n");
  process.exit(1);
}

function resolveDotNetPipePath(pipeName) {
  if (process.platform === "win32") return `\\\\.\\pipe\\${pipeName}`;
  const sockPath = path.join("/tmp", `CoreFxPipe_${pipeName}`);
  if (fs.existsSync(sockPath)) fs.unlinkSync(sockPath);
  return sockPath;
}

const pendingBrowserQueue = [];

const serverFactory = new DaniServerFactory({
  sessionNonce: SESSION_NONCE,
  httpPort: HTTP_PORT,
  wsPort: WS_PORT,
  onBrowserCommand: (msg) => {
    pendingBrowserQueue.push({ receivedUtc: new Date().toISOString(), command: msg });
    if (pendingBrowserQueue.length > 200) pendingBrowserQueue.shift();
  }
});

serverFactory.startPrimaryDesktopBridge();

function dispatchKernelAction(envelope) {
  if (envelope.Nonce !== SESSION_NONCE) {
    throw new Error("ZoneBoundaryViolation: Session nonce mismatch on Node IPC pipe.");
  }

  const action = envelope.Action;
  const payload = envelope.Payload || {};

  switch (action) {
    case "BroadcastBrowserWS":
      return { deliveredClients: serverFactory.broadcastEvent(payload.channel || "kernel:event", payload.data || {}) };
    case "PollBrowserCommands":
      return { commands: pendingBrowserQueue.splice(0, pendingBrowserQueue.length) };
    case "CompactAndPruneMatrix":
      return compactAndPruneMatrix(payload);
    case "ParseTelemetryStream":
      return parseStructuredStream(payload.rawText, payload.format || "auto");
    case "SpawnDynamicServer":
      return serverFactory.spawnDynamicServer(payload);
    case "StopDynamicServer":
      return { stopped: serverFactory.stopDynamicServer(payload.id) };
    default:
      throw new Error(`UnsupportedNodeAction: '${action}'`);
  }
}

const pipeEndpoint = resolveDotNetPipePath(PIPE_NAME);

const pipeServer = net.createServer((socket) => {
  let buffer = "";

  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let newlineIdx;

    while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, newlineIdx).trim();
      buffer = buffer.slice(newlineIdx + 1);
      if (!line) continue;

      let requestId = null;
      try {
        const envelope = JSON.parse(line);
        requestId = envelope.Id || null;
        const resultPayload = dispatchKernelAction(envelope);

        socket.write(JSON.stringify({
          Id: requestId, Nonce: SESSION_NONCE, Domain: "Node", Ok: true,
          Timestamp: new Date().toISOString(), Payload: resultPayload
        }) + "\n");
      } catch (err) {
        socket.write(JSON.stringify({
          Id: requestId, Nonce: SESSION_NONCE, Domain: "Node", Ok: false,
          Timestamp: new Date().toISOString(), Payload: { error: err.message }
        }) + "\n");
      }
    }
  });

  socket.on("error", () => {});
});

pipeServer.listen(pipeEndpoint, () => {
  process.stdout.write(`[DaniOs::Node] Listening on ${pipeEndpoint} | Desktop UI http://127.0.0.1:${HTTP_PORT}\n`);
});

function gracefulExit() {
  serverFactory.shutdownAll();
  pipeServer.close(() => {
    if (process.platform !== "win32" && fs.existsSync(pipeEndpoint)) fs.unlinkSync(pipeEndpoint);
    process.exit(0);
  });
}

process.on("SIGINT", gracefulExit);
process.on("SIGTERM", gracefulExit);
