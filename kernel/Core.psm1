#Requires -Version 7.4
using namespace System.IO
using namespace System.Security.AccessControl
using namespace System.Security.Principal

Set-StrictMode -Version Latest

$script:ActiveWorkers = @{}
$script:KernelRunning = $false

function Mount-DaniParallelFirewallPartition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $defaultPath = if ($IsWindows) {
        Join-Path $env:ProgramData "DaniOs\.parallel_3x3_firewall"
    }
    else {
        "/var/lib/danios/.parallel_3x3_firewall"
    }

    $partitionRoot = $Config.memoryMatrix.parallelPartitionPath ?? $defaultPath

    if (-not (Test-Path $partitionRoot)) {
        New-Item -ItemType Directory -Path $partitionRoot -Force | Out-Null
    }

    if ($IsWindows) {
        $acl = Get-Acl -Path $partitionRoot
        $acl.SetAccessRuleProtection($true, $false)

        $systemSid = [SecurityIdentifier]::new([WellKnownSidType]::LocalSystemSid, $null)
        $adminSid  = [SecurityIdentifier]::new([WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $usersSid  = [SecurityIdentifier]::new([WellKnownSidType]::BuiltinUsersSid, $null)

        $acl.AddAccessRule([FileSystemAccessRule]::new($systemSid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))
        $acl.AddAccessRule([FileSystemAccessRule]::new($adminSid,  "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))
        $acl.AddAccessRule([FileSystemAccessRule]::new($usersSid,  "FullControl", "ContainerInherit,ObjectInherit", "Deny"))
        Set-Acl -Path $partitionRoot -AclObject $acl

        $dirInfo = Get-Item -Path $partitionRoot -Force
        $dirInfo.Attributes = $dirInfo.Attributes -bor [FileAttributes]::Hidden -bor [FileAttributes]::System
    }
    else {
        & chmod 700 $partitionRoot
    }

    return $partitionRoot
}

function Update-DaniBootGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][int]$Generation,
        [Parameter(Mandatory)][string]$SessionNonce
    )

    foreach ($tier in @("tier_1_active", "tier_2_rolling", "tier_3_baseline")) {
        $statePath = Join-Path $ParallelPartitionRoot "$tier\state.json"
        $stateObj  = Get-Content -Path $statePath -Raw | ConvertFrom-Json -AsHashtable

        $stateObj.bootGeneration = $Generation
        $stateObj.lastBootUtc    = (Get-Date).ToUniversalTime().ToString("o")
        $stateObj.firewallState.parallelPartitionMounted = $true
        $stateObj.firewallState.nativeFsLocked           = $true
        $stateObj.firewallState.unsecureBridgeActive     = $true

        $stateObj | ConvertTo-Json -Depth 8 | Set-Content -Path $statePath -Encoding UTF8 -Force
    }
}

function Write-DaniJournalEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [ValidateSet("tier_1_active", "tier_2_rolling", "tier_3_baseline")][string]$Tier = "tier_1_active",
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message
    )

    $journalPath = Join-Path $ParallelPartitionRoot "$Tier\journal.md"
    $stamp       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
    $entry       = "- **[$stamp] [$Category]** $Message"

    Add-Content -Path $journalPath -Value $entry -Encoding UTF8
}

function Start-DaniPolyglotWorkers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DaniRoot,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$SessionNonce
    )

    $workerSpecs = @{
        Node = @{
            Executable = "node"
            EntryPoint = Join-Path $DaniRoot "polyglot\node\bridge_daemon.js"
            PipeName   = "DaniOs.Pipe.Node"
            HttpPort   = [string]($Config.desktopBrowserIntegration.httpPort ?? 4110)
            WsPort     = [string]($Config.desktopBrowserIntegration.wsPort ?? 4111)
        }
        PHP = @{
            Executable = "php"
            EntryPoint = Join-Path $DaniRoot "polyglot\php\bridge_worker.php"
            PipeName   = "DaniOs.Pipe.PHP"
            HttpPort   = ""
            WsPort     = ""
        }
        Python = @{
            Executable = if ($IsWindows) { "python" } else { "python3" }
            EntryPoint = Join-Path $DaniRoot "polyglot\python\bridge_server.py"
            PipeName   = "DaniOs.Pipe.Python"
            HttpPort   = ""
            WsPort     = ""
        }
    }

    foreach ($domain in @("Node", "PHP", "Python")) {
        $spec = $workerSpecs[$domain]
        if (-not (Test-Path $spec.EntryPoint)) { continue }

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = $spec.Executable
        $psi.Arguments              = "`"$($spec.EntryPoint)`""
        $psi.WorkingDirectory       = Split-Path $spec.EntryPoint -Parent
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true

        $psi.Environment["DANIOS_TRUST_ZONE"]    = "UNSECURE_EDGE"
        $psi.Environment["DANIOS_DOMAIN"]        = $domain.ToUpperInvariant()
        $psi.Environment["DANIOS_PIPE_NAME"]     = $spec.PipeName
        $psi.Environment["DANIOS_SESSION_NONCE"] = $SessionNonce
        if ($spec.HttpPort) { $psi.Environment["DANIOS_HTTP_PORT"] = $spec.HttpPort }
        if ($spec.WsPort)   { $psi.Environment["DANIOS_WS_PORT"]   = $spec.WsPort }

        $psi.Environment.Remove("DANIOS_CLOUD_SECRET") | Out-Null

        $proc = [System.Diagnostics.Process]::Start($psi)
        $script:ActiveWorkers[$domain] = @{
            Process    = $proc
            Spec       = $spec
            StartedUtc = (Get-Date).ToUniversalTime()
            Restarts   = 0
        }
    }

    Start-Sleep -Milliseconds 350
    return $script:ActiveWorkers
}

function Stop-DaniPolyglotWorkers {
    [CmdletBinding()]
    param()

    foreach ($domain in @($script:ActiveWorkers.Keys)) {
        $entry = $script:ActiveWorkers[$domain]
        $proc  = $entry.Process
        if ($null -ne $proc -and -not $proc.HasExited) {
            try {
                $proc.Kill($true)
                $proc.WaitForExit(1500) | Out-Null
            }
            catch {
                Write-Warning "[DaniOs::Core] Force-closed worker '$domain': $($_.Exception.Message)"
            }
        }
        $script:ActiveWorkers.Remove($domain)
    }
}

function Invoke-DaniMatrixExpansionAndPrune {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $maxEntries = [int]($Config.memoryMatrix.maxJournalEntriesPerTier ?? 50)
    $payload    = @{ maxEntriesPerTier = $maxEntries; tiers = @{} }

    foreach ($tier in @("tier_1_active", "tier_2_rolling", "tier_3_baseline")) {
        $payload.tiers[$tier] = @{
            journal   = Get-Content (Join-Path $ParallelPartitionRoot "$tier\journal.md")    -Raw
            solutions = Get-Content (Join-Path $ParallelPartitionRoot "$tier\solutions.yml") -Raw
            state     = Get-Content (Join-Path $ParallelPartitionRoot "$tier\state.json")    -Raw
        }
    }

    $nodeResult = Invoke-DaniPolyglotBridge -Operation "Send" -Domain "Node" -Action "CompactAndPruneMatrix" -Payload $payload

    if ($nodeResult.Ok -and $null -ne $nodeResult.Data.tiers) {
        foreach ($tier in @("tier_1_active", "tier_2_rolling", "tier_3_baseline")) {
            $compacted = $nodeResult.Data.tiers[$tier]
            if ($compacted.journal)   { Set-Content (Join-Path $ParallelPartitionRoot "$tier\journal.md")    -Value $compacted.journal   -Encoding UTF8 -Force }
            if ($compacted.solutions) { Set-Content (Join-Path $ParallelPartitionRoot "$tier\solutions.yml") -Value $compacted.solutions -Encoding UTF8 -Force }
            if ($compacted.state)     { Set-Content (Join-Path $ParallelPartitionRoot "$tier\state.json")    -Value $compacted.state     -Encoding UTF8 -Force }
        }
    }
    else {
        foreach ($tier in @("tier_1_active", "tier_2_rolling", "tier_3_baseline")) {
            $jPath = Join-Path $ParallelPartitionRoot "$tier\journal.md"
            $lines = Get-Content -Path $jPath
            if ($lines.Count -gt ($maxEntries + 10)) {
                $header = $lines | Select-Object -First 8
                $tail   = $lines | Select-Object -Last $maxEntries
                @($header + "" + $tail) | Set-Content -Path $jPath -Encoding UTF8 -Force
            }
        }
    }
}

function Invoke-DaniSelfHeal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DaniRoot,
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$SessionNonce,
        [Parameter(Mandatory)][hashtable]$FaultContext
    )

    $domain    = $FaultContext.Domain
    $signature = $FaultContext.Signature

    Write-Warning "[DaniOs::Healer] Fault detected in '$domain' ($signature). Initiating self-healing loop..."
    Write-DaniJournalEntry -ParallelPartitionRoot $ParallelPartitionRoot -Tier "tier_1_active" -Category "FAULT" -Message "Detected '$signature' in domain '$domain'."

    $knownFix = $null
    foreach ($tier in @("tier_3_baseline", "tier_2_rolling", "tier_1_active")) {
        $ymlText = Get-Content (Join-Path $ParallelPartitionRoot "$tier\solutions.yml") -Raw
        if ($ymlText -match [regex]::Escape($signature)) {
            $knownFix = "Matched verified playbook in $tier for '$signature'."
            break
        }
    }

    $aiAdvice = $null
    if (-not $knownFix -and [System.Management.Automation.PSTypeName]'DaniOs.Kernel.AI'.Type) {
        $contextSnapshot = Get-Content (Join-Path $ParallelPartitionRoot "tier_1_active\journal.md") -Tail 20 | Out-String
        $aiAdvice = [DaniOs.Kernel.AI]::DiagnoseAndSynthesize(($FaultContext | ConvertTo-Json -Compress), $contextSnapshot)
    }

    if ($domain -in @("Node", "PHP", "Python") -and $script:ActiveWorkers.ContainsKey($domain)) {
        $entry    = $script:ActiveWorkers[$domain]
        $maxRetry = [int]($Config.kernel.maxAutonomousRetries ?? 3)

        if ($entry.Restarts -lt $maxRetry) {
            if (-not $entry.Process.HasExited) { $entry.Process.Kill($true) }
            $newProc = [System.Diagnostics.Process]::Start($entry.Process.StartInfo)
            $entry.Process    = $newProc
            $entry.Restarts  += 1
            $entry.StartedUtc = (Get-Date).ToUniversalTime()

            $resolutionNote = $knownFix ?? $aiAdvice ?? "Respawned '$domain' worker (attempt $($entry.Restarts)/$maxRetry)."
            Write-DaniJournalEntry -ParallelPartitionRoot $ParallelPartitionRoot -Tier "tier_1_active" -Category "HEALED" -Message $resolutionNote

            $t1Solutions = Join-Path $ParallelPartitionRoot "tier_1_active\solutions.yml"
            $yamlAppend  = @"

  - id: "AUTO_$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    signature: "$signature"
    domain: "$domain"
    remediation: "$($resolutionNote -replace '"', '\"')"
    verified_at: "$((Get-Date).ToUniversalTime().ToString('o'))"
"@
            Add-Content -Path $t1Solutions -Value $yamlAppend -Encoding UTF8

            Send-DaniBrowserEvent -Channel "kernel:healed" -Data @{
                domain     = $domain
                signature  = $signature
                resolution = $resolutionNote
            } | Out-Null

            if ($Config.cloudOrigin.enabled -and $Config.cloudOrigin.autoBackupOnHealCommit) {
                Sync-DaniCloudSavePoint -ParallelPartitionRoot $ParallelPartitionRoot -CloudConfig $Config.cloudOrigin | Out-Null
            }
        }
        else {
            Write-DaniJournalEntry -ParallelPartitionRoot $ParallelPartitionRoot -Tier "tier_1_active" -Category "ESCALATE" -Message "Worker '$domain' exceeded maxAutonomousRetries ($maxRetry)."
        }
    }
}

function Start-DaniKernelSupervisor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DaniRoot,
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$SessionNonce
    )

    $intervalMs           = [int]($Config.kernel.heartbeatIntervalMs ?? 1500)
    $script:KernelRunning = $true
    $tickCounter          = 0

    Write-Host "[DaniOs::Supervisor] Kernel heartbeat active (${intervalMs}ms). Press Ctrl+C for clean shutdown." -ForegroundColor Cyan

    try {
        while ($script:KernelRunning) {
            Start-Sleep -Milliseconds $intervalMs
            $tickCounter++

            foreach ($domain in @($script:ActiveWorkers.Keys)) {
                $proc = $script:ActiveWorkers[$domain].Process
                if ($proc.HasExited) {
                    Invoke-DaniSelfHeal `
                        -DaniRoot $DaniRoot `
                        -ParallelPartitionRoot $ParallelPartitionRoot `
                        -Config $Config `
                        -SessionNonce $SessionNonce `
                        -FaultContext @{
                            Domain    = $domain
                            Signature = "WorkerUnexpectedExit_Code_$($proc.ExitCode)"
                            Timestamp = (Get-Date).ToUniversalTime().ToString("o")
                        }
                }
            }

            if (($tickCounter % 20) -eq 0) {
                Initialize-DaniGoldenMatrix -ParallelPartitionRoot $ParallelPartitionRoot | Out-Null
                if (Get-Command -Name "Test-DaniNativePerimeterIntegrity" -ErrorAction SilentlyContinue) {
                    Test-DaniNativePerimeterIntegrity -ParallelPartitionRoot $ParallelPartitionRoot -AutoHealDrift | Out-Null
                }
                Send-DaniBrowserEvent -Channel "kernel:heartbeat" -Data @{
                    tick         = $tickCounter
                    workersAlive = @($script:ActiveWorkers.Keys | Where-Object { -not $script:ActiveWorkers[$_].Process.HasExited })
                    timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
                } | Out-Null
            }
        }
    }
    finally {
        Write-Host "`n[DaniOs::Supervisor] Shutdown signal received. Pruning 3x3 matrix & committing Cloud Origin backup..." -ForegroundColor Yellow

        if ($Config.memoryMatrix.autoPruneOnShutdown) {
            Invoke-DaniMatrixExpansionAndPrune -ParallelPartitionRoot $ParallelPartitionRoot -Config $Config
        }

        Write-DaniJournalEntry -ParallelPartitionRoot $ParallelPartitionRoot -Tier "tier_1_active" -Category "SHUTDOWN" -Message "Clean kernel shutdown completed."

        if ($Config.cloudOrigin.enabled) {
            Sync-DaniCloudSavePoint -ParallelPartitionRoot $ParallelPartitionRoot -CloudConfig $Config.cloudOrigin | Out-Null
        }

        Stop-DaniPolyglotWorkers
        Write-Host "[DaniOs::Supervisor] DaniOs halted cleanly." -ForegroundColor Cyan
    }
}

Export-ModuleMember -Function @(
    "Mount-DaniParallelFirewallPartition",
    "Update-DaniBootGeneration",
    "Write-DaniJournalEntry",
    "Start-DaniPolyglotWorkers",
    "Stop-DaniPolyglotWorkers",
    "Invoke-DaniMatrixExpansionAndPrune",
    "Invoke-DaniSelfHeal",
    "Start-DaniKernelSupervisor"
)
