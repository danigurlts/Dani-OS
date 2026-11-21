#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$RunFaultSim,
    [switch]$LaunchCodex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
Set-Location -Path $RepoRoot

# 1. Session defaults (PowerShell 7 session defaults)
if (-not $env:NODE_ENV) { $env:NODE_ENV = "development" }
if (-not $env:DANIOS_ALLOW_INSECURE_HTTP) { $env:DANIOS_ALLOW_INSECURE_HTTP = "true" }

if (-not $env:DANIOS_VAULT_MASTER_KEY) {
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    $rng.Dispose()
    $env:DANIOS_VAULT_MASTER_KEY = ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    Write-Host "[DaniOs Init] Generated ephemeral session DANIOS_VAULT_MASTER_KEY." -ForegroundColor Yellow
}

# 2. Import core PowerShell modules cleanly
Import-Module (Join-Path $RepoRoot "kernel\Policy.psm1") -Force
Import-Module (Join-Path $RepoRoot "kernel\Core.psm1")   -Force
Import-Module (Join-Path $RepoRoot "kernel\Bridge.psm1") -Force

# 3. Quick repository & syntax sanity check
$gitBranch = (git rev-parse --abbrev-ref HEAD 2>$null)
$gitHead   = (git rev-parse --short HEAD 2>$null)
Write-Host "[DaniOs Init] Repo: $RepoRoot ($gitBranch @ $gitHead) on PS $($PSVersionTable.PSVersion)" -ForegroundColor Cyan

if (Get-Command php -ErrorAction SilentlyContinue) {
    & php -l (Join-Path $RepoRoot "polyglot\php\web_client.php") | Out-Null
    & php -l (Join-Path $RepoRoot "polyglot\php\bridge_worker.php") | Out-Null
}
if (Get-Command python -ErrorAction SilentlyContinue) {
    & python -m py_compile (Join-Path $RepoRoot "polyglot\python\bridge_server.py")
}
if (Get-Command node -ErrorAction SilentlyContinue) {
    & node --check (Join-Path $RepoRoot "cloud-origin\vault_server.js")
}

# 4. Optional fault simulation check
if ($RunFaultSim) {
    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "tests\Simulate-KernelFault.ps1")
}

# 5. Optional Codex CLI handoff
if ($LaunchCodex) {
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        throw "Codex CLI ('codex') was not found in PATH."
    }

    $codexPrompt = @"
You are working in DaniOs (danigurlts/Dani-OS) on PowerShell 7.
Key rules & invariants to preserve:
1. Target PowerShell 7 and its supported .NET runtime.
2. Never replace full module files with partial stubs; preserve all exported functions, routes, and error paths.
3. Enforce fail-closed security: scoped Windows ACLs, reparse-point/link checks without unsafe path-based deletes on fault, AES-256-GCM vault encryption with 32-byte DANIOS_VAULT_MASTER_KEY and atomic temp+rename writes, no redirects + all-A/AAAA validation + CURLOPT_RESOLVE pinning + CURLOPT_SSL_VERIFYHOST=2 in PHP outbound calls/probes, and 64KB IPC frame limits + `$parsed.Ok validation.
4. Run syntax checks and tests\Simulate-KernelFault.ps1 after edits before summarizing changes.

Inspect git status and the relevant module files for the requested task.
"@

    & codex $codexPrompt
}