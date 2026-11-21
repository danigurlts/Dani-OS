#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\kernel.config.json"),
    [switch]$ForceCloudRestore,
    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DaniRoot  = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $DaniRoot "kernel\Compat.ps1")
$KernelDir = Join-Path $DaniRoot "kernel"
$ModelDir  = Join-Path $KernelDir "models"

Write-Host "[DaniOs::Boot] Initializing self-contained PowerShell + AI Kernel..." -ForegroundColor Cyan

Write-Host "[DaniOs::Boot] PowerShell 7 mode." -ForegroundColor DarkCyan

if (-not (Test-Path $ConfigPath)) {
    throw "FATAL KERNEL PANIC: Missing kernel configuration at '$ConfigPath'."
}
$Config   = Get-Content -Path $ConfigPath -Raw | ConvertFrom-DaniJson
$Manifest = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot "manifest.psd1")

if ($Manifest.ParallelMemoryMatrix.ExpectedNodeCount -ne 9) {
    throw "FATAL KERNEL PANIC: Manifest 3x3 topology mismatch."
}

$modelName = if ($Config.ai.modelFile) { [string]$Config.ai.modelFile } else { "danios-core-3b.Q4_K_M.gguf" }
if ([System.IO.Path]::IsPathRooted($modelName)) {
    $modelFile = [System.IO.Path]::GetFullPath($modelName)
} elseif (Test-Path (Join-Path $DaniRoot $modelName) -PathType Leaf) {
    $modelFile = [System.IO.Path]::GetFullPath((Join-Path $DaniRoot $modelName))
} else {
    $modelFile = Join-Path $ModelDir $modelName
}

$aiAssemblyPath = Join-Path $KernelDir "bin\DaniOs.Kernel.AI.dll"
if (-not [System.Management.Automation.PSTypeName]'DaniOs.Kernel.AI'.Type -and (Test-Path $aiAssemblyPath -PathType Leaf)) {
    try {
        [System.Reflection.Assembly]::LoadFrom($aiAssemblyPath) | Out-Null
    }
    catch {
        Write-Warning "[DaniOs::Boot] Could not load AI assembly '$aiAssemblyPath': $($_.Exception.Message)"
    }
}
$aiType = [System.Management.Automation.PSTypeName]'DaniOs.Kernel.AI'.Type
function Get-DaniAiSetting {
    param([string]$Name, [object]$Default)
    $property = $Config.ai.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

if ($null -ne $aiType -and (Test-Path $modelFile)) {
    try {
        $aiOptions = [DaniOs.Kernel.AiRuntimeOptions]::new()
        $aiOptions.NativeLibraryDirectory = [string](Get-DaniAiSetting "nativeLibraryDirectory" "native")
        $aiOptions.ContextTokens = [int](Get-DaniAiSetting "contextTokens" 4096)
        $aiOptions.BatchSize = [int](Get-DaniAiSetting "batchSize" 128)
        $aiOptions.Threads = [int](Get-DaniAiSetting "threads" 0)
        $aiOptions.GpuLayers = [int](Get-DaniAiSetting "gpuLayers" 0)
        $aiOptions.Temperature = [single](Get-DaniAiSetting "temperature" 0.0)
        $aiOptions.TopP = [single](Get-DaniAiSetting "topP" 0.9)
        $aiOptions.RepeatPenalty = [single](Get-DaniAiSetting "repeatPenalty" 1.05)
        $aiOptions.MaxTokens = [int](Get-DaniAiSetting "maxTokens" 96)
        $aiOptions.MaxOutputCharacters = [int](Get-DaniAiSetting "maxOutputCharacters" 4096)
        $aiOptions.ModelLoadTimeoutMs = [int](Get-DaniAiSetting "modelLoadTimeoutMs" 120000)
        $aiOptions.InferenceTimeoutMs = [int](Get-DaniAiSetting "inferenceTimeoutMs" 30000)
        $aiOptions.FallbackToDeterministicRules = [bool](Get-DaniAiSetting "fallbackToDeterministicRules" $true)
        $aiReady = [DaniOs.Kernel.AI]::Initialize($modelFile, $aiOptions)
        if (-not $aiReady) {
            Write-Warning "[DaniOs::Boot] Embedded AI DLL could not mount model '$modelFile'. Continuing in deterministic fallback mode."
        }
        else {
            Write-Host "[DaniOs::Boot] Embedded SLM active in-kernel ($(Split-Path $modelFile -Leaf))." -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "[DaniOs::Boot] AI load failed: $($_.Exception.Message). Continuing in deterministic fallback mode."
    }
}
elseif (-not (Test-Path $modelFile)) {
    Write-Warning "[DaniOs::Boot] No AI model found at '$modelFile'. Continuing in deterministic fallback mode."
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
$t3State     = Get-Content -Path $t3StatePath -Raw | ConvertFrom-DaniJson

$bootGeneration = if ($t3State.bootGeneration) { [int]$t3State.bootGeneration } else { 0 }
$isZeroGen  = $bootGeneration -eq 0
$shouldPull = $ForceCloudRestore -or ($isZeroGen -and $Config.cloudOrigin.enabled -and $Config.cloudOrigin.autoRestoreOnZeroGeneration)

if ($shouldPull) {
    Write-Host "[DaniOs::Boot] Zero-generation state detected. Querying Cloud Origin save point..." -ForegroundColor Yellow
    $restoreResult = Restore-DaniCloudSavePoint `
        -ParallelPartitionRoot $partitionRoot `
        -CloudConfig $Config.cloudOrigin

    if ($restoreResult.Ok) {
        Write-Host "[DaniOs::Boot] Cloud save point restored (SavedAt: $($restoreResult.SavedAtUtc))." -ForegroundColor Green
        $t3State = Get-Content -Path $t3StatePath -Raw | ConvertFrom-DaniJson
    }
    else {
        Write-Warning "[DaniOs::Boot] Cloud restore unavailable ($($restoreResult.Error)). Continuing on Golden Seeds."
    }
}

$bootGeneration = if ($t3State.bootGeneration) { [int]$t3State.bootGeneration } else { 0 }
$nextGen = $bootGeneration + 1
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
