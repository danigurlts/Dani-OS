<div align="center">

# ⚡ DaniOs
### Self-Healing Operating System Built on a PowerShell 7 Polyglot Kernel

[![PowerShell](https://img.shields.io/badge/Kernel-PowerShell%207-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Node.js](https://img.shields.io/badge/Parsing%20%26%20Desktop%20UI-Node.js%2022%2B-339933?style=for-the-badge&logo=nodedotjs&logoColor=white)](https://nodejs.org/)
[![PHP](https://img.shields.io/badge/Web%20Edge%20%26%20Probes-PHP%208.3%2B-777BB4?style=for-the-badge&logo=php&logoColor=white)](https://www.php.net/)
[![Python](https://img.shields.io/badge/Syscalls%20%26%20Hardware-Python%203.11%2B-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://www.python.org/)
[![License: GPL v3](https://img.shields.io/badge/License-GNU%20GPLv3-BD0000?style=for-the-badge&logo=gnu&logoColor=white)](LICENSE)

*PowerShell 7 runs the DaniOs kernel, maintains a protected 3x3 state partition, and coordinates isolated Node.js, PHP, and Python workers with Cloud Origin save points.*

</div>

---

## 📖 Overview

**DaniOs** runs kernel scripts in **PowerShell 7 on .NET**. The optional .NET 8 host and AI project files are not loaded by this runtime. Its ACL-locked 3x3 partition holds state files across three tiers.

## 🚀 Quick Start

```powershell
# Runtime prerequisites, onboarding and fault simulation
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ./setup/Install-DaniOs.ps1

# Boot kernel
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ./boot/init.ps1
```

## Cloud Origin Vault

The vault requires `DANIOS_VAULT_MASTER_KEY` to be 64 hexadecimal characters. Configure `DANIOS_VAULT_SECRET` to the same account secret used by the kernel. The example config enables HTTP only on `127.0.0.1` for local development. For remote access, set `allowHttp` to `false`, configure both `tls.keyFile` and `tls.certFile` (or `DANIOS_VAULT_TLS_KEY` and `DANIOS_VAULT_TLS_CERT`), and bind the vault to the intended interface. The server rejects non-loopback HTTP binds.

```powershell
$env:DANIOS_VAULT_MASTER_KEY = '<64-character hex key>'
$env:DANIOS_VAULT_SECRET = '<provisioned account secret>'
$env:DANIOS_VAULT_ALLOW_HTTP = 'true'
node ./cloud-origin/vault_server.js
```

For local HTTP development, keep the vault host at `127.0.0.1` and set `DANIOS_VAULT_ALLOW_HTTP=true` (or use `allowHttp: true` in the config file). Do not expose that mode on a network interface.

## License

Distributed under the GNU General Public License v3.0 (GPL-3.0). See [LICENSE](LICENSE) for full terms.
