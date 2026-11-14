#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\kernel.config.json"),
    [switch]$ForceCloudRestore,
    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DaniRoot  = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$KernelDir = Join-Path $DaniRoot "kernel"
$BinDir    = Join-Path $KernelDir "bin"
$ModelDir  = Join-Path $KernelDir "models"

Write-Host "[DaniOs::Boot] Initializing self-contained PowerShell + AI Kernel..." -ForegroundColor Cyan

$hostDll = Join-Path $BinDir "DaniOs.Kernel.Host.dll"
$aiDll   = Join-Path $BinDir "DaniOs.Kernel.AI.dll"

foreach ($dll in @($hostDll, $aiDll)) {
    if (Test-Path $dll) {
        Add-Type -Path $dll
        Write-Host "[DaniOs::Boot] Loaded kernel assembly: $(Split-Path $dll -Leaf)" -ForegroundColor DarkCyan
    }
}

if (-not (Test-Path $ConfigPath)) {
    throw "FATAL KERNEL PANIC: Missing kernel configuration at '$ConfigPath'."
}
$Config   = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$Manifest = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot "manifest.psd1")

if ($Manifest.ParallelMemoryMatrix.ExpectedNodeCount -ne 9) {
    throw "FATAL KERNEL PANIC: Manifest 3x3 topology mismatch."
}

$modelFile = Join-Path $ModelDir ($Config.ai.modelFile ?? "danios-core-3b.Q4_K_M.gguf")
if ([System.Management.Automation.PSTypeName]'DaniOs.Kernel.AI'.Type -and (Test-Path $modelFile)) {
    $aiReady = [DaniOs.Kernel.AI]::Initialize($modelFile, [int]($Config.ai.contextTokens ?? 4096))
    if (-not $aiReady) {
        throw "FATAL KERNEL PANIC: Embedded AI DLL failed to mount model '$modelFile'."
    }
    Write-Host "[DaniOs::Boot] Embedded SLM active in-kernel ($(Split-Path $modelFile -Leaf))." -ForegroundColor Green
}

Import-Module (Join-Path $KernelDir "Bridge.psm1")      -Force
Import-Module (Join-Path $KernelDir "CloudOrigin.psm1") -Force
Import-Module (Join-Path $KernelDir "Policy.psm1")      -Force
Import-Module (Join-Path $KernelDir "Snapshot.psm1")    -Force
Import-Module (Join-Path $KernelDir "Core.psm1")        -Force

$partitionRoot = Mount-DaniParallelFirewallPartition -Config $Config
$matrixState   = Initialize-DaniGoldenMatrix -ParallelPartitionRoot $partitionRoot

Write-Host "[DaniOs::Boot] Parallel 3x3 Firewall Partition mounted ($($matrixState.ActiveNodes) nodes active)." -ForegroundColor Green

$t3StatePath = Join-Path $partitionRoot "tier_3_baseline\state.json"
$t3State     = Get-Content -Path $t3StatePath -Raw | ConvertFrom-Json -AsHashtable

$isZeroGen  = ([int]($t3State.bootGeneration ?? 0)) -eq 0
$shouldPull = $ForceCloudRestore -or ($isZeroGen -and $Config.cloudOrigin.enabled -and $Config.cloudOrigin.autoRestoreOnZeroGeneration)

if ($shouldPull) {
    Write-Host "[DaniOs::Boot] Zero-generation state detected. Querying Cloud Origin save point..." -ForegroundColor Yellow
    $restoreResult = Restore-DaniCloudSavePoint `
        -ParallelPartitionRoot $partitionRoot `
        -CloudConfig $Config.cloudOrigin

    if ($restoreResult.Ok) {
        Write-Host "[DaniOs::Boot] Cloud save point restored (SavedAt: $($restoreResult.SavedAtUtc))." -ForegroundColor Green
        $t3State = Get-Content -Path $t3StatePath -Raw | ConvertFrom-Json -AsHashtable
    }
    else {
        Write-Warning "[DaniOs::Boot] Cloud restore unavailable ($($restoreResult.Error)). Continuing on Golden Seeds."
    }
}

$nextGen = ([int]($t3State.bootGeneration ?? 0)) + 1
Update-DaniBootGeneration -ParallelPartitionRoot $partitionRoot -Generation $nextGen -SessionNonce $matrixState.BrowserSession
Write-DaniJournalEntry -ParallelPartitionRoot $partitionRoot -Tier "tier_1_active" -Category "BOOT" -Message "DaniOs booted cleanly into Generation #$nextGen (CloudRestore=$shouldPull)."

$workers = Start-DaniPolyglotWorkers `
    -DaniRoot $DaniRoot `
    -Config $Config `
    -SessionNonce $matrixState.BrowserSession

Write-Host "[DaniOs::Boot] Polyglot workers online: $($workers.Keys -join ', ')" -ForegroundColor Green

if (-not $Headless) {
    Send-DaniBrowserEvent -Channel "kernel:boot" -Data @{
        os             = "DaniOs"
        bootGeneration = $nextGen
        activeNodes    = $matrixState.ActiveNodes
        workers        = @($workers.Keys)
        timestampUtc   = (Get-Date).ToUniversalTime().ToString("o")
    } | Out-Null
}

if ($Config.cloudOrigin.enabled -and $Config.cloudOrigin.autoBackupOnCleanBoot) {
    $backupResult = Sync-DaniCloudSavePoint `
        -ParallelPartitionRoot $partitionRoot `
        -CloudConfig $Config.cloudOrigin

    if ($backupResult.Ok) {
        Write-Host "[DaniOs::Boot] Default Cloud Origin save point synced ($($backupResult.PackedBytes) bytes)." -ForegroundColor DarkGreen
    }
}

Start-DaniKernelSupervisor `
    -DaniRoot $DaniRoot `
    -ParallelPartitionRoot $partitionRoot `
    -Config $Config `
    -SessionNonce $matrixState.BrowserSession
