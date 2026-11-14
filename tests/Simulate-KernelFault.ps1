#Requires -Version 7.4
using namespace System.Net

[CmdletBinding()]
param([switch]$SkipLiveWorkers, [switch]$KeepSandbox)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DaniRoot  = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$KernelDir = Join-Path $DaniRoot "kernel"

Import-Module (Join-Path $KernelDir "Bridge.psm1")      -Force
Import-Module (Join-Path $KernelDir "CloudOrigin.psm1") -Force
Import-Module (Join-Path $KernelDir "Policy.psm1")      -Force
Import-Module (Join-Path $KernelDir "Snapshot.psm1")    -Force
Import-Module (Join-Path $KernelDir "Core.psm1")        -Force

$script:PassedCount = 0
$script:FailedCount = 0

function Invoke-ChaosTest {
    param([string]$Name, [scriptblock]$TestBlock)
    Write-Host "`n[TEST] $Name" -ForegroundColor Cyan
    try {
        & $TestBlock
        $script:PassedCount++
        Write-Host "  -> PASS" -ForegroundColor Green
    } catch {
        $script:FailedCount++
        Write-Host "  -> FAIL: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True { param([bool]$Condition, [string]$Message = "Assertion failed") if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Actual, $Expected, [string]$Message = "") if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', got '$Actual'" } }

$SandboxId        = [guid]::NewGuid().ToString("N").Substring(0, 10)
$SandboxRoot      = Join-Path ([System.IO.Path]::GetTempPath()) "DaniOs_Chaos_$SandboxId"
$ParallelPartRoot = Join-Path $SandboxRoot ".parallel_3x3_firewall"
$NativeFsRoot     = Join-Path $SandboxRoot "encapsulated_native_fs"
New-Item -ItemType Directory -Path $ParallelPartRoot, $NativeFsRoot -Force | Out-Null

$TestHttpPort  = Get-Random -Minimum 24100 -Maximum 24900
$TestWsPort    = $TestHttpPort + 1
$TestVaultPort = $TestHttpPort + 2

$TestConfig = @{
    osName = "DaniOs-ChaosTest"
    kernel = @{ heartbeatIntervalMs = 500; autoHealEnabled = $true; requireSandboxValidation = $true; maxAutonomousRetries = 3 }
    memoryMatrix = @{ parallelPartitionPath = $ParallelPartRoot; maxJournalEntriesPerTier = 12; autoPruneOnShutdown = $true }
    desktopBrowserIntegration = @{ bindAddress = "127.0.0.1"; httpPort = $TestHttpPort; wsPort = $TestWsPort }
    cloudOrigin = @{ enabled = $true; originUrl = "http://127.0.0.1:$TestVaultPort/api"; accountSecret = "chaos-secret-9f8e7d"; kernelSalt = "DaniOs-Chaos-v1"; autoBackupOnCleanBoot = $true; autoBackupOnHealCommit = $true; autoRestoreOnZeroGeneration = $true }
}

$SessionNonce = $null
try {
    Invoke-ChaosTest -Name "1. Golden Seed Hydration & 3x3 Partition Self-Repair" -TestBlock {
        $init = Initialize-DaniGoldenMatrix -ParallelPartitionRoot $ParallelPartRoot
        Assert-Equal $init.ActiveNodes 9
        $script:SessionNonce = $init.BrowserSession
        Remove-Item (Join-Path $ParallelPartRoot "tier_2_rolling\solutions.yml") -Force
        Initialize-DaniGoldenMatrix -ParallelPartitionRoot $ParallelPartRoot | Out-Null
        Assert-True (Test-Path (Join-Path $ParallelPartRoot "tier_2_rolling\solutions.yml"))
    }

    Invoke-ChaosTest -Name "2. AST Policy Firewall" -TestBlock {
        Assert-True (-not (Test-DaniScriptAst -ScriptText 'Invoke-Expression "Get-Process"').Approved)
        Assert-True (-not (Test-DaniScriptAst -ScriptText 'Remove-Item "C:\ProgramData\DaniOs\.parallel_3x3_firewall\tier_1_active\state.json"').Approved)
        Assert-True (Test-DaniScriptAst -ScriptText '$x = 1 + 1').Approved
    }

    Invoke-ChaosTest -Name "3. Zone Boundary & Path Traversal Firewall" -TestBlock {
        Assert-True (-not (Test-DaniWebToNativeRequest -SourceDomain "Node" -Intent "Write" -TargetPath "..\..\.parallel_3x3_firewall\tier_3_baseline\solutions.yml" -NativeRoot $NativeFsRoot).Allowed)
        Assert-True (-not (Test-DaniWebToNativeRequest -SourceDomain "PHP" -Intent "Write" -TargetPath "notes.txt" -NativeRoot $NativeFsRoot).Allowed)
        $mediated = Invoke-DaniMediatedNativeWrite -SourceDomain "BrowserUI" -TargetPath "workspace\prefs.json" -Content '{"ok":true}' -NativeRoot $NativeFsRoot -ParallelPartitionRoot $ParallelPartRoot
        Assert-True $mediated.Ok
    }

    Invoke-ChaosTest -Name "4. Deterministic Rollback & Outside-In Drift Healing" -TestBlock {
        $targetFile = Join-Path $NativeFsRoot "apps\service.json"
        New-Item -ItemType Directory -Path (Split-Path $targetFile -Parent) -Force | Out-Null
        Set-Content -Path $targetFile -Value '{"port":8080}' -Encoding UTF8 -Force
        Invoke-DaniTransactionalAction -ParallelPartitionRoot $ParallelPartRoot -TargetPaths @($targetFile) -Action { } | Out-Null
        $bad = Invoke-DaniTransactionalAction -ParallelPartitionRoot $ParallelPartRoot -TargetPaths @($targetFile) -Action { Set-Content -Path $targetFile -Value "BROKEN" } -VerifyCheck { $false }
        Assert-True $bad.RolledBack
        Assert-Equal ((Get-Content $targetFile -Raw).Trim()) '{"port":8080}'
        Set-Content -Path $targetFile -Value '{"port":6666}' -Encoding UTF8 -Force
        $healed = Test-DaniNativePerimeterIntegrity -ParallelPartitionRoot $ParallelPartRoot -AutoHealDrift
        Assert-True $healed.Drifted[0].AutoHealed
        Assert-Equal ((Get-Content $targetFile -Raw).Trim()) '{"port":8080}'
    }

    Invoke-ChaosTest -Name "5. 3x3 Expansion & Pruning" -TestBlock {
        for ($i = 1; $i -le 20; $i++) { Write-DaniJournalEntry -ParallelPartitionRoot $ParallelPartRoot -Category "TICK" -Message "Event $i" }
        Invoke-DaniMatrixExpansionAndPrune -ParallelPartitionRoot $ParallelPartRoot -Config $TestConfig
        $lines = @(Get-Content (Join-Path $ParallelPartRoot "tier_1_active\journal.md") | Where-Object { $_ -match "^- \*\*\[" })
        Assert-True ($lines.Count -le 12)
    }
}
finally {
    if (-not $KeepSandbox -and (Test-Path $SandboxRoot)) { Remove-Item -Path $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`nSummary: $($script:PassedCount) Passed | $($script:FailedCount) Failed"
if ($script:FailedCount -gt 0) { exit 1 }
