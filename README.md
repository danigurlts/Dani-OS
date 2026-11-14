<div align="center">

# ⚡ DaniOs
### Self-Healing, AI-Powered Operating System Built on a Self-Contained Polyglot PowerShell Kernel

[![PowerShell](https://img.shields.io/badge/Kernel-PowerShell%207.4%2B%20(.NET%208%20DLL)-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Embedded AI](https://img.shields.io/badge/Kernel%20AI-In--Process%20SLM%20(llama.cpp)-8B5CF6?style=for-the-badge)](https://github.com/ggerganov/llama.cpp)
[![Node.js](https://img.shields.io/badge/Parsing%20%26%20Desktop%20UI-Node.js%2022%2B-339933?style=for-the-badge&logo=nodedotjs&logoColor=white)](https://nodejs.org/)
[![PHP](https://img.shields.io/badge/Web%20Edge%20%26%20Probes-PHP%208.3%2B-777BB4?style=for-the-badge&logo=php&logoColor=white)](https://www.php.net/)
[![Python](https://img.shields.io/badge/Syscalls%20%26%20Hardware-Python%203.11%2B-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://www.python.org/)
[![License: GPL v3](https://img.shields.io/badge/License-GNU%20GPLv3-BD0000?style=for-the-badge&logo=gnu&logoColor=white)](LICENSE)

*An autonomous, object-driven operating environment where a self-contained PowerShell + AI DLL kernel orchestrates system state, an ACL-locked parallel 3×3 firewall partition encompasses and protects the native filesystem, a hardware-fingerprinted Cloud Origin vault preserves encrypted save points, and restricted Node.js, PHP, and Python workers handle browser integration, web I/O, and low-level system probes.*

</div>

---

## 📖 Overview

**DaniOs** unifies **PowerShell (`System.Management.Automation.dll`)** and a **dedicated local Small Language Model (`DaniOs.Kernel.AI.dll` + `llama.dll`)** inside a single self-contained .NET 8 kernel process. Around the encapsulated native filesystem sits an ACL-locked **Parallel 3×3 Firewall Partition** (`.md`, `.yml`, `.json` × 3 tiers = 9 nodes) invisible and permission-denied to standard users and web-facing workers.

## 🚀 Quick Start

```powershell
# Automated prerequisite check, C# DLL compilation, onboarding & chaos verification
pwsh -NoProfile -ExecutionPolicy Bypass -File ./setup/Install-DaniOs.ps1

# Boot self-contained kernel
./boot/DaniOs.Boot.exe   # Windows
./boot/DaniOs.Boot       # Linux / macOS
 License
​Distributed under the GNU General Public License v3.0 (GPL-3.0). See LICENSE for full terms.
