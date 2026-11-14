"use strict";

const http = require("http");
const { WebSocketServer, WebSocket } = require("ws");

class DaniServerFactory {
  constructor({ sessionNonce, httpPort = 4110, wsPort = 4111, onBrowserCommand }) {
    this.sessionNonce = sessionNonce;
    this.httpPort = Number(httpPort);
    this.wsPort = Number(wsPort);
    this.onBrowserCommand = onBrowserCommand || (() => {});
    this.primaryHttp = null;
    this.primaryWs = null;
    this.recentEvents = [];
    this.dynamicServers = new Map();
  }

  startPrimaryDesktopBridge() {
    this.primaryHttp = http.createServer((req, res) => {
      const url = new URL(req.url, `http://127.0.0.1:${this.httpPort}`);

      if (url.pathname === "/health") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({
          ok: true,
          os: "DaniOs",
          zone: "UNSECURE_EDGE",
          wsClients: this.primaryWs ? this.primaryWs.clients.size : 0,
          dynamicServers: Array.from(this.dynamicServers.keys())
        }));
        return;
      }

      if (url.pathname === "/") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
        res.end(this.renderDesktopShellHtml());
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "NotFound" }));
    });

    this.primaryHttp.listen(this.httpPort, "127.0.0.1");

    this.primaryWs = new WebSocketServer({ host: "127.0.0.1", port: this.wsPort });

    this.primaryWs.on("connection", (socket, req) => {
      const reqUrl = new URL(req.url, `ws://127.0.0.1:${this.wsPort}`);
      const clientNonce = reqUrl.searchParams.get("nonce");

      if (clientNonce !== this.sessionNonce) {
        socket.close(4001, "InvalidSessionNonce");
        return;
      }

      socket.send(JSON.stringify({
        channel: "bridge:connected",
        data: { history: this.recentEvents.slice(-25), timestampUtc: new Date().toISOString() }
      }));

      socket.on("message", (raw) => {
        try {
          const msg = JSON.parse(raw.toString("utf8"));
          this.onBrowserCommand(msg, socket);
        } catch {
          socket.send(JSON.stringify({ channel: "bridge:error", data: { error: "MalformedJSON" } }));
        }
      });
    });
  }

  broadcastEvent(channel, data) {
    const packet = { channel, data, timestampUtc: new Date().toISOString() };
    this.recentEvents.push(packet);
    if (this.recentEvents.length > 100) this.recentEvents.shift();

    if (!this.primaryWs) return 0;

    const serialized = JSON.stringify(packet);
    let delivered = 0;

    for (const client of this.primaryWs.clients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(serialized);
        delivered++;
      }
    }
    return delivered;
  }

  spawnDynamicServer({ id, port, routes = {} }) {
    if (!id || !port) throw new Error("spawnDynamicServer requires 'id' and 'port'.");
    if (this.dynamicServers.has(id)) this.stopDynamicServer(id);

    const server = http.createServer((req, res) => {
      const url = new URL(req.url, `http://127.0.0.1:${port}`);
      const handlerSpec = routes[url.pathname];

      if (!handlerSpec) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "RouteNotDefined", path: url.pathname }));
        return;
      }

      res.writeHead(Number(handlerSpec.status || 200), {
        "Content-Type": handlerSpec.contentType || "application/json"
      });
      const body = typeof handlerSpec.body === "string"
        ? handlerSpec.body
        : JSON.stringify(handlerSpec.body ?? { ok: true });
      res.end(body);
    });

    server.listen(Number(port), "127.0.0.1");
    this.dynamicServers.set(id, { id, port: Number(port), server, createdUtc: new Date().toISOString() });

    return { id, bind: `http://127.0.0.1:${port}`, routeCount: Object.keys(routes).length };
  }

  stopDynamicServer(id) {
    const entry = this.dynamicServers.get(id);
    if (!entry) return false;
    entry.server.close();
    this.dynamicServers.delete(id);
    return true;
  }

  shutdownAll() {
    for (const id of this.dynamicServers.keys()) this.stopDynamicServer(id);
    if (this.primaryWs) this.primaryWs.close();
    if (this.primaryHttp) this.primaryHttp.close();
  }

  renderDesktopShellHtml() {
    return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>DaniOs Kernel Console</title>
  <style>
    :root { color-scheme: dark; --bg: #0b0f17; --card: #121826; --border: #1f2937; --accent: #38bdf8; --ok: #10b981; --warn: #f59e0b; }
    body { margin: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--bg); color: #e5e7eb; padding: 20px; }
    header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 12px; margin-bottom: 20px; }
    .badge { padding: 4px 10px; border-radius: 999px; font-size: 12px; background: #064e3b; color: var(--ok); border: 1px solid var(--ok); }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; margin-bottom: 20px; }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 14px; }
    .label { font-size: 11px; color: #9ca3af; text-transform: uppercase; }
    .val { font-size: 20px; font-weight: 700; margin-top: 6px; color: var(--accent); }
    #log { background: #070a10; border: 1px solid var(--border); border-radius: 8px; padding: 14px; height: 340px; overflow-y: auto; font-size: 12px; line-height: 1.5; }
    .evt-heal { color: var(--warn); }
    .evt-boot { color: var(--ok); }
  </style>
</head>
<body>
  <header>
    <div><strong>⚡ DaniOs</strong> // Desktop-Browser Kernel Telemetry</div>
    <span id="status" class="badge">CONNECTING</span>
  </header>
  <div class="grid">
    <div class="card"><div class="label">Boot Generation</div><div id="gen" class="val">—</div></div>
    <div class="card"><div class="label">3×3 Matrix Nodes</div><div id="nodes" class="val">9 / 9</div></div>
    <div class="card"><div class="label">Heartbeat Tick</div><div id="tick" class="val">0</div></div>
    <div class="card"><div class="label">Active Workers</div><div id="workers" class="val">—</div></div>
  </div>
  <div id="log"></div>
  <script>
    const logEl = document.getElementById("log");
    const statusEl = document.getElementById("status");
    const ws = new WebSocket("ws://127.0.0.1:${this.wsPort}/?nonce=${this.sessionNonce}");
    function appendLine(pkt) {
      const div = document.createElement("div");
      if (pkt.channel === "kernel:healed") div.className = "evt-heal";
      if (pkt.channel === "kernel:boot") div.className = "evt-boot";
      div.textContent = "[" + (pkt.timestampUtc || new Date().toISOString()) + "] " + pkt.channel + " -> " + JSON.stringify(pkt.data);
      logEl.appendChild(div);
      logEl.scrollTop = logEl.scrollHeight;
    }
    function applyEvent(pkt) {
      appendLine(pkt);
      if (pkt.channel === "kernel:boot" && pkt.data) {
        document.getElementById("gen").textContent = "#" + pkt.data.bootGeneration;
        document.getElementById("nodes").textContent = (pkt.data.activeNodes || 9) + " / 9";
        document.getElementById("workers").textContent = (pkt.data.workers || []).join(", ");
      }
      if (pkt.channel === "kernel:heartbeat" && pkt.data) {
        document.getElementById("tick").textContent = pkt.data.tick;
        document.getElementById("workers").textContent = (pkt.data.workersAlive || []).join(", ");
      }
    }
    ws.onopen = () => { statusEl.textContent = "LIVE // NONCE VERIFIED"; };
    ws.onclose = () => { statusEl.textContent = "DISCONNECTED"; statusEl.style.color = "#f87171"; };
    ws.onmessage = (ev) => {
      const pkt = JSON.parse(ev.data);
      if (pkt.channel === "bridge:connected" && Array.isArray(pkt.data.history)) {
        pkt.data.history.forEach(applyEvent);
      } else {
        applyEvent(pkt);
      }
    };
  </script>
</body>
</html>`;
  }
}

module.exports = { DaniServerFactory };
