#!/usr/bin/env bash
set -euo pipefail

# PowerShell 7 is the supported DaniOs runtime.
if ! command -v pwsh.exe >/dev/null 2>&1; then
  echo "DaniOs requires PowerShell 7; run this launcher from Git Bash on Windows." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "${repo_root}/setup/Install-DaniOs.ps1" "$@"
