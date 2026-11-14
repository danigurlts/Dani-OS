#Requires -Version 7.4
using namespace System.IO
using namespace System.Security.Cryptography
using namespace System.Collections.Generic

Set-StrictMode -Version Latest

function Get-DaniFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)

    $sha256 = [SHA256]::Create()
    $stream = [File]::OpenRead($FilePath)
    try {
        $hashBytes = $sha256.ComputeHash($stream)
        return [Convert]::ToHexString($hashBytes).ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $sha256.Dispose()
    }
}

function Start-DaniKernelTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [string]$Reason = "KernelMutation"
    )

    $txId        = "tx_" + [DateTimeOffset]::UtcNow.ToString("yyyyMMdd_HHmmss") + "_" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $snapshotDir = Join-Path $ParallelPartitionRoot ".snapshots\$txId"

    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null

    return [PSCustomObject]@{
        TransactionId = $txId
        SnapshotDir   = $snapshotDir
        Reason        = $Reason
        StartedUtc    = (Get-Date).ToUniversalTime().ToString("o")
        State         = "Open"
        Entries       = [List[hashtable]]::new()
    }
}

function Add-DaniTransactionTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Transaction,
        [Parameter(Mandatory)][string]$TargetPath
    )

    if ($Transaction.State -ne "Open") {
        throw "TransactionStateError: Cannot add targets to transaction '$($Transaction.TransactionId)' in state '$($Transaction.State)'."
    }

    $fullPath = [Path]::GetFullPath($TargetPath)

    foreach ($existing in $Transaction.Entries) {
        if ($existing.OriginalPath -eq $fullPath) { return }
    }

    $existedBefore = Test-Path -Path $fullPath -PathType Leaf
    $backupFile    = $null
    $preHash       = $null
    $attributes    = $null

    if ($existedBefore) {
        $slotIndex  = $Transaction.Entries.Count
        $backupFile = Join-Path $Transaction.SnapshotDir "slot_${slotIndex}.bak"
        [File]::Copy($fullPath, $backupFile, $true)
        $preHash    = Get-DaniFileSha256 -FilePath $fullPath
        $attributes = (Get-Item -Path $fullPath -Force).Attributes
    }

    $Transaction.Entries.Add(@{
        OriginalPath  = $fullPath
        ExistedBefore = $existedBefore
        BackupPath    = $backupFile
        PreSha256     = $preHash
        Attributes    = $attributes
    })
}

function Undo-DaniKernelTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Transaction)

    if ($Transaction.State -eq "RolledBack") {
        return [PSCustomObject]@{ Ok = $true; TransactionId = $Transaction.TransactionId; RestoredCount = 0 }
    }

    $restoredCount = 0

    for ($i = $Transaction.Entries.Count - 1; $i -ge 0; $i--) {
        $entry = $Transaction.Entries[$i]
        $orig  = $entry.OriginalPath

        if ($entry.ExistedBefore) {
            $parentDir = Split-Path -Path $orig -Parent
            if (-not (Test-Path $parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
            }

            if (Test-Path $orig) {
                $item = Get-Item -Path $orig -Force
                if ($item.Attributes -band [FileAttributes]::ReadOnly) {
                    $item.Attributes = $item.Attributes -bxor [FileAttributes]::ReadOnly
                }
            }

            [File]::Copy($entry.BackupPath, $orig, $true)

            if ($null -ne $entry.Attributes) {
                (Get-Item -Path $orig -Force).Attributes = $entry.Attributes
            }

            $restoredCount++
        }
        else {
            if (Test-Path $orig) {
                Remove-Item -Path $orig -Force
                $restoredCount++
            }
        }
    }

    $Transaction.State = "RolledBack"

    if (Test-Path $Transaction.SnapshotDir) {
        Remove-Item -Path $Transaction.SnapshotDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{
        Ok            = $true
        TransactionId = $Transaction.TransactionId
        RestoredCount = $restoredCount
        RolledBackUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Commit-DaniKernelTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Transaction,
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [int]$RetainMaxSnapshots = 15
    )

    if ($Transaction.State -ne "Open") {
        throw "TransactionStateError: Cannot commit transaction '$($Transaction.TransactionId)' in state '$($Transaction.State)'."
    }

    $updatedHashes = @{}
    $vaultBaseline = Join-Path $ParallelPartitionRoot ".snapshots\verified_baselines"
    if (-not (Test-Path $vaultBaseline)) {
        New-Item -ItemType Directory -Path $vaultBaseline -Force | Out-Null
    }

    foreach ($entry in $Transaction.Entries) {
        $orig = $entry.OriginalPath
        if (Test-Path -Path $orig -PathType Leaf) {
            $postHash = Get-DaniFileSha256 -FilePath $orig
            $updatedHashes[$orig] = $postHash

            $goldenCopy = Join-Path $vaultBaseline "$postHash.obj"
            if (-not (Test-Path $goldenCopy)) {
                [File]::Copy($orig, $goldenCopy, $true)
            }
        }
        else {
            $updatedHashes[$orig] = $null
        }
    }

    foreach ($tier in @("tier_1_active", "tier_3_baseline")) {
        $statePath = Join-Path $ParallelPartitionRoot "$tier\state.json"
        if (Test-Path $statePath) {
            $stateObj = Get-Content -Path $statePath -Raw | ConvertFrom-Json -AsHashtable
            if (-not $stateObj.ContainsKey("integrityBaselines") -or $null -eq $stateObj.integrityBaselines) {
                $stateObj["integrityBaselines"] = @{}
            }

            foreach ($pathKey in $updatedHashes.Keys) {
                if ($null -eq $updatedHashes[$pathKey]) {
                    $stateObj["integrityBaselines"].Remove($pathKey) | Out-Null
                }
                else {
                    $stateObj["integrityBaselines"][$pathKey] = @{
                        sha256     = $updatedHashes[$pathKey]
                        verifiedAt = (Get-Date).ToUniversalTime().ToString("o")
                        txId       = $Transaction.TransactionId
                    }
                }
            }

            $stateObj | ConvertTo-Json -Depth 8 | Set-Content -Path $statePath -Encoding UTF8 -Force
        }
    }

    $Transaction.State = "Committed"

    $snapRoot = Join-Path $ParallelPartitionRoot ".snapshots"
    $txDirs   = Get-ChildItem -Path $snapRoot -Directory -Filter "tx_*" | Sort-Object CreationTimeUtc -Descending
    if ($txDirs.Count -gt $RetainMaxSnapshots) {
        $txDirs | Select-Object -Skip $RetainMaxSnapshots | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{
        Ok            = $true
        TransactionId = $Transaction.TransactionId
        UpdatedHashes = $updatedHashes
        CommittedUtc  = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Invoke-DaniTransactionalAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][string[]]$TargetPaths,
        [Parameter(Mandatory)][scriptblock]$Action,
        [scriptblock]$VerifyCheck = { $true },
        [string]$Reason = "AutonomousRemediation"
    )

    if (Get-Command -Name "Test-DaniScriptAst" -ErrorAction SilentlyContinue) {
        $audit = Test-DaniScriptAst -ScriptText $Action.ToString()
        if (-not $audit.Approved) {
            throw "AstPolicyRejected: $($audit.Violations -join '; ')"
        }
    }

    $tx = Start-DaniKernelTransaction -ParallelPartitionRoot $ParallelPartitionRoot -Reason $Reason

    try {
        foreach ($path in $TargetPaths) {
            Add-DaniTransactionTarget -Transaction $tx -TargetPath $path
        }

        $actionOutput = & $Action

        $verified = & $VerifyCheck
        if (-not $verified) {
            throw "PostMutationVerificationFailed: Health check returned false after remediation."
        }

        $commitResult = Commit-DaniKernelTransaction -Transaction $tx -ParallelPartitionRoot $ParallelPartitionRoot

        return [PSCustomObject]@{
            Ok            = $true
            TransactionId = $tx.TransactionId
            Output        = $actionOutput
            Hashes        = $commitResult.UpdatedHashes
        }
    }
    catch {
        $rollback = Undo-DaniKernelTransaction -Transaction $tx
        return [PSCustomObject]@{
            Ok            = $false
            TransactionId = $tx.TransactionId
            Error         = $_.Exception.Message
            RolledBack    = $rollback.Ok
            RestoredFiles = $rollback.RestoredCount
        }
    }
}

function Test-DaniNativePerimeterIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [switch]$AutoHealDrift
    )

    $t3StatePath = Join-Path $ParallelPartitionRoot "tier_3_baseline\state.json"
    if (-not (Test-Path $t3StatePath)) {
        return [PSCustomObject]@{ Clean = $true; Checked = 0; Drifted = @() }
    }

    $stateObj  = Get-Content -Path $t3StatePath -Raw | ConvertFrom-Json -AsHashtable
    $baselines = $stateObj["integrityBaselines"]
    if ($null -eq $baselines -or $baselines.Count -eq 0) {
        return [PSCustomObject]@{ Clean = $true; Checked = 0; Drifted = @() }
    }

    $vaultBaseline = Join-Path $ParallelPartitionRoot ".snapshots\verified_baselines"
    $drifted       = [List[PSCustomObject]]::new()

    foreach ($filePath in $baselines.Keys) {
        $expectedSha = $baselines[$filePath].sha256
        $status      = "Match"
        $actualSha   = $null
        $healed      = $false

        if (-not (Test-Path -Path $filePath -PathType Leaf)) {
            $status = "Missing"
        }
        else {
            $actualSha = Get-DaniFileSha256 -FilePath $filePath
            if ($actualSha -ne $expectedSha) {
                $status = "HashMismatch"
            }
        }

        if ($status -ne "Match") {
            if ($AutoHealDrift) {
                $goldenObj = Join-Path $vaultBaseline "$expectedSha.obj"
                if (Test-Path $goldenObj) {
                    $parentDir = Split-Path -Path $filePath -Parent
                    if (-not (Test-Path $parentDir)) {
                        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                    }
                    [File]::Copy($goldenObj, $filePath, $true)
                    $healed = $true
                }
            }

            $drifted.Add([PSCustomObject]@{
                Path        = $filePath
                Status      = $status
                ExpectedSha = $expectedSha
                ActualSha   = $actualSha
                AutoHealed  = $healed
            })
        }
    }

    return [PSCustomObject]@{
        Clean   = ($drifted.Count -eq 0)
        Checked = $baselines.Count
        Drifted = @($drifted)
    }
}

Export-ModuleMember -Function @(
    "Get-DaniFileSha256",
    "Start-DaniKernelTransaction",
    "Add-DaniTransactionTarget",
    "Undo-DaniKernelTransaction",
    "Commit-DaniKernelTransaction",
    "Invoke-DaniTransactionalAction",
    "Test-DaniNativePerimeterIntegrity"
)
