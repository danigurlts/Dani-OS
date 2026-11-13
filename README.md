<div align="center">

# ⚡ DaniOs
### Self-Healing, AI-Powered Operating System Built on a Polyglot PowerShell Kernel

[![PowerShell](https://img.shields.io/badge/Kernel-PowerShell%207.4%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Python](https://img.shields.io/badge/Low--Level%20%26%20AI-Python%203.11%2B-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://www.python.org/)
[![PHP](https://img.shields.io/badge/Web%20Calls%20%26%20Edge-PHP%208.3%2B-777BB4?style=for-the-badge&logo=php&logoColor=white)](https://www.php.net/)
[![Node.js](https://img.shields.io/badge/Parsing%20%26%20Servers-Node.js%2022%2B-339933?style=for-the-badge&logo=nodedotjs&logoColor=white)](https://nodejs.org/)
[![License: GPL v3](https://img.shields.io/badge/License-GNU%20GPLv3-BD0000?style=for-the-badge&logo=gnu&logoColor=white)](https://www.gnu.org/licenses/gpl-3.0)

*An autonomous, object-driven OS environment where a PowerShell kernel orchestrates system state, an integrated AI engine diagnoses and remediates faults in real time, and a native Python, PHP, and Node.js polyglot runtime handles low-level syscalls, web I/O, stream parsing, and dynamic server creation.*

</div>

---

## 📖 Overview

Traditional operating systems treat errors as static log entries waiting for human intervention. **DaniOs** reimagines the OS control plane as an active, self-correcting loop.

At its core sits a **PowerShell Kernel** that leverages structured object pipelines—rather than fragile raw text streams—to manage processes, services, file integrity, and security policies. Embedded directly into the kernel loop is an **AI Diagnostic & Synthesis Engine** capable of interpreting system telemetry, isolating root causes, and deploying verified hotfixes autonomously.

To maximize performance and ecosystem reach without bloating the kernel, **DaniOs** operates as a **four-way polyglot runtime**:
- **PowerShell (`pwsh`)** acts as the stateful kernel, object-pipeline router, and system supervisor.
- **Python** handles low-level OS hooks, memory/hardware telemetry, C-bindings, and local LLM inference.
- **PHP** manages outbound web calls, webhook ingestion, external REST/API integrations, and stateless HTTP tasks.
- **Node.js** powers high-throughput log/AST/stream parsing, dynamic HTTP/WebSocket server creation, event-driven daemons, and miscellaneous async utilities.

---

## 🏗️ System Architecture

```text
+---------------------------------------------------------------------------------+
|                          INTELLIGENCE & HEALING PLANE                           |
|    [ Anomaly Watcher ] ---> [ Root-Cause Analyzer ] ---> [ Patch Sandbox ]      |
+----------------------------------------+----------------------------------------+
                                         | (AST / Script Synthesis & Rollback)
                                         v
+---------------------------------------------------------------------------------+
|                        POWERSHELL KERNEL (Control Plane)                        |
|    Object Pipeline  |  Service Supervisor  |  State Snapshots  |  IPC Broker    |
+--------------------+-----------------------+-------------------+----------------+
                     |                       |                   |
        (Named Pipes / JSON-RPC)   (Named Pipes / JSON-RPC)   (Named Pipes / JSON-RPC)
                     |                       |                   |
                     v                       v                   v
+-----------------------------+ +-------------------------+ +---------------------+
|      PYTHON SUBSYSTEM       | |     NODE.JS SUBSYSTEM   | |    PHP SUBSYSTEM    |
| • Low-level syscalls/ctypes | | • Log/AST/JSON parsing  | | • Outbound web I/O  |
| • Hardware & memory metrics | | • Dynamic HTTP/WS hosts | | • cURL & REST calls |
| • Local AI/LLM inference    | | • Async misc workers    | | • Webhook endpoints |
+-----------------------------+ +-------------------------+ +---------------------+
```

---

## 🧩 The Polyglot Runtime Stack

Each runtime in **DaniOs** is dedicated to the workload where its execution model excels, communicating over low-latency Named Pipes / Unix Domain Sockets using structured JSON-RPC payloads.

| Layer | Runtime | Core Responsibilities |
| :--- | :--- | :--- |
| **Kernel & Orchestrator** | **PowerShell 7.4+** | Process/daemon lifecycle, WMI/CIM & OS state management, security enforcement, object-stream routing, and transactional rollback snapshots. |
| **Low-Level & Inference** | **Python 3.11+** | Direct syscall interfaces (`ctypes`/`cffi`), kernel-level telemetry polling, driver/hardware inspection, and local LLM execution. |
| **Parsing & Dynamic Servers** | **Node.js 22+** | High-speed log, config, and AST parsing; on-demand HTTP/WebSocket/IPC server creation; file-system watchers; and miscellaneous async tooling. |
| **Web Calls & Network Edge** | **PHP 8.3+** | Outbound HTTP/HTTPS requests, external REST/GraphQL client calls, webhook dispatchers, remote cluster sync, and diagnostics UI. |

### Polyglot Pipeline Example
PowerShell objects serialize natively across the IPC bridge, allowing seamless execution across all four runtimes in a single pipeline:

```powershell
# Hardware check (Python) -> Telemetry log parse (Node.js) -> Remote alert (PHP)
Get-DaniKernelHealth -Subsystem Storage |
    Invoke-DaniPython -Module "lowlevel.block_io" -Method "inspect_sectors" |
    Invoke-DaniNode -Worker "parser/telemetry_stream.js" -Action "ExtractAnomalies" |
    Where-Object { $_.Severity -ge 3 } |
    Invoke-DaniPHP -Endpoint "web/webhook_dispatch.php" -Action "NotifyCluster"
```

---

## 🔄 The Self-Healing Loop

When a service crashes, a dependency breaks, or anomalous resource drift is detected, **DaniOs** executes a five-stage autonomous recovery cycle:

1. **Detect (`Observe`)** — Kernel event hooks, Python hardware monitors, and Node.js stream parsers capture non-zero exit codes, `$Error` stream exceptions, hung sockets, or file-hash mismatches.
2. **Snapshot (`Preserve`)** — Before any mutation occurs, the kernel captures a lightweight state checkpoint (config files, service states, environment variables, and filesystem/registry diffs).
3. **Diagnose (`Reason`)** — Node.js compresses and normalizes raw logs into structured context, which the integrated AI engine analyzes alongside recent system diffs to isolate root cause.
4. **Synthesize & Verify (`Sandbox`)** — The AI generates a targeted remediation payload (PowerShell patch, Python repair routine, Node.js server rebind, or PHP endpoint failover) and validates syntax and side effects inside an isolated dry-run scope.
5. **Commit or Rollback (`Heal`)** — The patch is applied to the live system. If health metrics do not stabilize within the verification window, the kernel automatically reverts to the pre-fault snapshot and escalates.

---

## 📂 Repository Structure

```text
DaniOs/
├── boot/
│   ├── init.ps1                  # Primary kernel bootstrap & polyglot daemon spawner
│   └── manifest.psd1             # Declarative baseline OS state & service definitions
├── kernel/
│   ├── Core.psm1                 # Object pipeline router, IPC broker & supervisor
│   ├── Snapshot.psm1             # Transactional state checkpointing & rollback engine
│   └── Policy.psm1               # Execution guardrails & privilege boundaries
├── ai/
│   ├── healer.ps1                # Autonomous fault-response loop
│   ├── context_builder.py        # Vector context retrieval & diagnostic weighting
│   └── prompts/                  # System diagnostic & patch-synthesis prompt templates
├── polyglot/
│   ├── python/
│   │   ├── bridge_server.py      # Persistent IPC worker for low-level requests
│   │   ├── syscalls.py           # OS/hardware/memory inspection routines
│   │   └── inference.py          # Local & hybrid LLM inference adapter
│   ├── node/
│   │   ├── package.json          # Node.js runtime dependencies
│   │   ├── bridge_daemon.js      # Persistent IPC worker for parsing & server tasks
│   │   ├── parser.js             # Structured log, AST & config stream parser
│   │   ├── server_factory.js     # On-demand HTTP, WebSocket & microservice spawner
│   │   └── misc_utils.js         # File watchers, schedulers & async system helpers
│   └── php/
│       ├── bridge_worker.php     # IPC worker for outbound web calls & API tasks
│       ├── web_client.php        # Resilient HTTP/cURL/webhook dispatcher
│       └── public/index.php      # Lightweight live OS health & telemetry dashboard
├── config/
│   └── kernel.config.json        # AI provider, healing thresholds & IPC socket settings
└── tests/
    └── Simulate-KernelFault.ps1  # Chaos-testing suite for self-healing verification
```

---

## 🚀 Getting Started

### Prerequisites
- **PowerShell** `7.4` or higher (`pwsh`)
- **Python** `3.11` or higher (`python3`, `pip`)
- **Node.js** `22.0` or higher (`node`, `npm`)
- **PHP** `8.3` or higher (`php-cli`, `ext-curl`, `ext-sockets`, `ext-json`)
- An accessible **LLM backend** (local Ollama/llama.cpp endpoint or compatible API key)

### Installation & Boot

```bash
# 1. Clone the repository
git clone [https://github.com/your-org/DaniOs.git](https://github.com/your-org/DaniOs.git)
cd DaniOs

# 2. Install Python low-level & AI dependencies
pip install -r polyglot/python/requirements.txt

# 3. Install Node.js parsing & server runtime dependencies
npm install --prefix polyglot/node

# 4. Configure kernel & AI parameters
cp config/kernel.config.example.json config/kernel.config.json

# 5. Boot the DaniOs PowerShell Kernel and spawn polyglot workers
pwsh -NoProfile -ExecutionPolicy Bypass -File ./boot/init.ps1
```

### Configuration (`config/kernel.config.json`)

```json
{
  "osName": "DaniOs",
  "kernel": {
    "heartbeatIntervalMs": 1500,
    "autoHealEnabled": true,
    "requireSandboxValidation": true,
    "maxAutonomousRetries": 3
  },
  "ai": {
    "provider": "local",
    "endpoint": "[http://127.0.0.1:11434/v1/chat/completions](http://127.0.0.1:11434/v1/chat/completions)",
    "model": "qwen2.5-coder:14b"
  },
  "polyglot": {
    "pythonWorkerCount": 2,
    "nodeWorkerCount": 3,
    "phpWorkerCount": 4,
    "ipcTransport": "named_pipe"
  }
}
```

---

## 🛡️ Safety & Guardrails

Autonomous OS modification requires strict deterministic boundaries:
- **Immutable Core Paths:** The AI healing engine is blocked at the kernel policy layer from modifying `/boot`, `/kernel/Policy.psm1`, or cryptographic trust stores without explicit operator sign-off.
- **AST & Command Allowlisting:** Generated PowerShell, Python, Node.js, and PHP remediation scripts undergo Abstract Syntax Tree (AST) inspection prior to execution to prevent destructive wildcards or unauthorized network exfiltration.
- **Guaranteed Rollback:** Every autonomous action is wrapped in a `Start-DaniKernelTransaction` block; failed health checks trigger deterministic restoration within milliseconds.

---

## 🗺️ Roadmap

- [x] PowerShell object-pipeline kernel & Named Pipe IPC broker
- [x] Python low-level syscall & hardware telemetry bridge
- [x] Node.js stream parser & on-demand HTTP/WebSocket server factory
- [x] PHP outbound web-call & webhook worker pool
- [ ] eBPF / ETW real-time kernel event streaming into the AI context window
- [ ] Multi-node mesh healing (peer-to-peer state recovery across DaniOs instances)
- [ ] Minimalist bootable ISO / container substrate image

---

## 🤝 Contributing

Contributions are welcome across any layer of **DaniOs**—whether optimizing PowerShell IPC throughput, expanding Python hardware bindings, building Node.js parsers/servers, or hardening PHP web workers.

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/node-stream-parser`)
3. Run the fault-injection test suite (`pwsh ./tests/Simulate-KernelFault.ps1`)
4. Open a Pull Request

---

## 📄 License

**DaniOs** is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0 (GPL-3.0)** as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

See the [`LICENSE`](LICENSE) file or [gnu.org/licenses/gpl-3.0](https://www.gnu.org/licenses/gpl-3.0.html) for full terms.
