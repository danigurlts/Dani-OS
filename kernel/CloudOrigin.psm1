#Requires -Version 7.4
using namespace System.IO
using namespace System.IO.Compression
using namespace System.Text
using namespace System.Security.Cryptography

Set-StrictMode -Version Latest

function Get-DaniDeviceFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccountSecret,
        [string]$KernelSalt = "DaniOs-Kernel-v1"
    )

    $signals = [System.Collections.Generic.List[string]]::new()

    if ($IsWindows) {
        try {
            $csUuid   = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
            $cpuId    = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).ProcessorId
            $boardSer = (Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop).SerialNumber
            $machGuid = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction Stop).MachineGuid

            $signals.Add("UUID:$csUuid")
            $signals.Add("CPU:$cpuId")
            $signals.Add("BOARD:$boardSer")
            $signals.Add("MGUID:$machGuid")
        }
        catch {
            $signals.Add("HOST:$([Environment]::MachineName)")
        }
    }
    else {
        foreach ($probePath in @("/etc/machine-id", "/sys/class/dmi/id/product_uuid", "/sys/class/dmi/id/board_serial")) {
            if (Test-Path $probePath) {
                $val = (Get-Content -Path $probePath -Raw -ErrorAction SilentlyContinue).Trim()
                if (-not [string]::IsNullOrWhiteSpace($val)) {
                    $signals.Add("${probePath}:${val}")
                }
            }
        }
        if ($signals.Count -eq 0) {
            $signals.Add("HOST:$([Environment]::MachineName)")
        }
    }

    $rawComposite = ($signals -join "|") + "|SALT:$KernelSalt"
    $sha256       = [SHA256]::Create()

    try {
        $fpBytes     = $sha256.ComputeHash([Encoding]::UTF8.GetBytes($rawComposite))
        $fingerprint = [Convert]::ToHexString($fpBytes).ToLowerInvariant()
        $keyMaterial = $sha256.ComputeHash([Encoding]::UTF8.GetBytes("${fingerprint}:${AccountSecret}"))

        return [PSCustomObject]@{
            Fingerprint = $fingerprint
            DerivedKey  = $keyMaterial
            SignalCount = $signals.Count
        }
    }
    finally {
        $sha256.Dispose()
    }
}

function Protect-DaniSavePointPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonPayload,
        [Parameter(Mandatory)][byte[]]$KeyBytes
    )

    $rawBytes         = [Encoding]::UTF8.GetBytes($JsonPayload)
    $compressedStream = [MemoryStream]::new()
    $brotli           = [BrotliStream]::new($compressedStream, [CompressionLevel]::Optimal, $true)
    $brotli.Write($rawBytes, 0, $rawBytes.Length)
    $brotli.Dispose()
    $compressedBytes  = $compressedStream.ToArray()
    $compressedStream.Dispose()

    $nonce      = [RandomNumberGenerator]::GetBytes(12)
    $tag        = [byte[]]::new(16)
    $cipherText = [byte[]]::new($compressedBytes.Length)

    $aesGcm = [AesGcm]::new($KeyBytes, 16)
    try {
        $aesGcm.Encrypt($nonce, $compressedBytes, $cipherText, $tag)
    }
    finally {
        $aesGcm.Dispose()
    }

    return [PSCustomObject]@{
        NonceB64      = [Convert]::ToBase64String($nonce)
        TagB64        = [Convert]::ToBase64String($tag)
        CipherTextB64 = [Convert]::ToBase64String($cipherText)
        RawBytes      = $rawBytes.Length
        PackedBytes   = $cipherText.Length
    }
}

function Unprotect-DaniSavePointPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NonceB64,
        [Parameter(Mandatory)][string]$TagB64,
        [Parameter(Mandatory)][string]$CipherTextB64,
        [Parameter(Mandatory)][byte[]]$KeyBytes
    )

    $nonce      = [Convert]::FromBase64String($NonceB64)
    $tag        = [Convert]::FromBase64String($TagB64)
    $cipherText = [Convert]::FromBase64String($CipherTextB64)
    $plainComp  = [byte[]]::new($cipherText.Length)

    $aesGcm = [AesGcm]::new($KeyBytes, 16)
    try {
        $aesGcm.Decrypt($nonce, $cipherText, $tag, $plainComp)
    }
    finally {
        $aesGcm.Dispose()
    }

    $inStream  = [MemoryStream]::new($plainComp)
    $outStream = [MemoryStream]::new()
    $brotli    = [BrotliStream]::new($inStream, [CompressionMode]::Decompress)

    try {
        $brotli.CopyTo($outStream)
        return [Encoding]::UTF8.GetString($outStream.ToArray())
    }
    finally {
        $brotli.Dispose()
        $inStream.Dispose()
        $outStream.Dispose()
    }
}

function New-DaniSignatureHeaders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Fingerprint,
        [Parameter(Mandatory)][string]$AccountSecret,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$BodyHashHex
    )

    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
    $canonical = "${Method}|${Fingerprint}|${timestamp}|${BodyHashHex}"

    $hmac = [HMACSHA256]::new([Encoding]::UTF8.GetBytes($AccountSecret))
    try {
        $sigBytes  = $hmac.ComputeHash([Encoding]::UTF8.GetBytes($canonical))
        $signature = [Convert]::ToHexString($sigBytes).ToLowerInvariant()

        return @{
            "X-DaniOs-Fingerprint" = $Fingerprint
            "X-DaniOs-Timestamp"   = $timestamp
            "X-DaniOs-Body-SHA256" = $BodyHashHex
            "X-DaniOs-Signature"   = $signature
            "User-Agent"           = "DaniOs-Kernel/1.0"
        }
    }
    finally {
        $hmac.Dispose()
    }
}

function Sync-DaniCloudSavePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][hashtable]$CloudConfig
    )

    if (-not $CloudConfig.enabled) {
        return [PSCustomObject]@{ Ok = $false; Reason = "CloudOriginDisabled" }
    }

    $identity    = Get-DaniDeviceFingerprint -AccountSecret $CloudConfig.accountSecret -KernelSalt $CloudConfig.kernelSalt
    $t3Solutions = Get-Content (Join-Path $ParallelPartitionRoot "tier_3_baseline/solutions.yml") -Raw
    $t3State     = Get-Content (Join-Path $ParallelPartitionRoot "tier_3_baseline/state.json") -Raw
    $t1Journal   = Get-Content (Join-Path $ParallelPartitionRoot "tier_1_active/journal.md") -Tail 40 | Out-String

    $saveBundle = @{
        os          = "DaniOs"
        createdUtc  = (Get-Date).ToUniversalTime().ToString("o")
        fingerprint = $identity.Fingerprint
        matrix      = @{
            baseline_solutions_yml = $t3Solutions
            baseline_state_json    = $t3State
            recent_journal_md      = $t1Journal
        }
    } | ConvertTo-Json -Depth 5 -Compress

    $sealed   = Protect-DaniSavePointPayload -JsonPayload $saveBundle -KeyBytes $identity.DerivedKey
    $wireBody = @{
        fingerprint = $identity.Fingerprint
        nonce       = $sealed.NonceB64
        tag         = $sealed.TagB64
        ciphertext  = $sealed.CipherTextB64
        meta        = @{
            rawBytes    = $sealed.RawBytes
            packedBytes = $sealed.PackedBytes
            schema      = "3x3-compact-v1"
        }
    } | ConvertTo-Json -Depth 4 -Compress

    $sha256      = [SHA256]::Create()
    $bodyHashHex = [Convert]::ToHexString($sha256.ComputeHash([Encoding]::UTF8.GetBytes($wireBody))).ToLowerInvariant()
    $sha256.Dispose()

    $headers = New-DaniSignatureHeaders `
        -Fingerprint $identity.Fingerprint `
        -AccountSecret $CloudConfig.accountSecret `
        -Method "PUT" `
        -BodyHashHex $bodyHashHex

    $endpoint = "$($CloudConfig.originUrl.TrimEnd('/'))/v1/savepoints/$($identity.Fingerprint)"

    try {
        $response = Invoke-RestMethod `
            -Uri $endpoint `
            -Method Put `
            -Headers $headers `
            -Body $wireBody `
            -ContentType "application/json" `
            -TimeoutSec 8 `
            -ErrorAction Stop

        return [PSCustomObject]@{
            Ok          = $true
            Action      = "CloudBackupCommitted"
            Fingerprint = $identity.Fingerprint
            PackedBytes = $sealed.PackedBytes
            Revision    = $response.revision
            Timestamp   = (Get-Date).ToUniversalTime().ToString("o")
        }
    }
    catch {
        $fault = [PSCustomObject]@{
            Ok        = $false
            Action    = "CloudBackupFailed"
            Error     = $_.Exception.Message
            Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        }

        if ([System.Management.Automation.PSTypeName]'DaniOs.Kernel.AI'.Type) {
            $fault | Add-Member -NotePropertyName "AiDiagnosis" -NotePropertyValue ([DaniOs.Kernel.AI]::DiagnoseFault($fault))
        }

        return $fault
    }
}

function Restore-DaniCloudSavePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][hashtable]$CloudConfig
    )

    $identity  = Get-DaniDeviceFingerprint -AccountSecret $CloudConfig.accountSecret -KernelSalt $CloudConfig.kernelSalt
    $sha256    = [SHA256]::Create()
    $emptyHash = [Convert]::ToHexString($sha256.ComputeHash([byte[]]@())).ToLowerInvariant()
    $sha256.Dispose()

    $headers = New-DaniSignatureHeaders `
        -Fingerprint $identity.Fingerprint `
        -AccountSecret $CloudConfig.accountSecret `
        -Method "GET" `
        -BodyHashHex $emptyHash

    $endpoint = "$($CloudConfig.originUrl.TrimEnd('/'))/v1/savepoints/$($identity.Fingerprint)"

    try {
        $envelope = Invoke-RestMethod `
            -Uri $endpoint `
            -Method Get `
            -Headers $headers `
            -TimeoutSec 8 `
            -ErrorAction Stop

        $decryptedJson = Unprotect-DaniSavePointPayload `
            -NonceB64 $envelope.nonce `
            -TagB64 $envelope.tag `
            -CipherTextB64 $envelope.ciphertext `
            -KeyBytes $identity.DerivedKey

        $bundle = $decryptedJson | ConvertFrom-Json -AsHashtable

        if ($bundle.fingerprint -ne $identity.Fingerprint) {
            throw "FingerprintMismatch: Cloud save point does not match local hardware identity."
        }

        foreach ($tier in @("tier_1_active", "tier_2_rolling", "tier_3_baseline")) {
            $tierDir = Join-Path $ParallelPartitionRoot $tier
            Set-Content -Path (Join-Path $tierDir "solutions.yml") -Value $bundle.matrix.baseline_solutions_yml -Encoding UTF8 -Force
            Set-Content -Path (Join-Path $tierDir "state.json")    -Value $bundle.matrix.baseline_state_json    -Encoding UTF8 -Force
            Set-Content -Path (Join-Path $tierDir "journal.md")    -Value $bundle.matrix.recent_journal_md      -Encoding UTF8 -Force
        }

        return [PSCustomObject]@{
            Ok          = $true
            Action      = "CloudSavePointRestored"
            Fingerprint = $identity.Fingerprint
            SavedAtUtc  = $bundle.createdUtc
        }
    }
    catch {
        return [PSCustomObject]@{
            Ok     = $false
            Action = "CloudRestoreFailedFallbackToGoldenSeeds"
            Error  = $_.Exception.Message
        }
    }
}

Export-ModuleMember -Function @(
    "Get-DaniDeviceFingerprint",
    "Protect-DaniSavePointPayload",
    "Unprotect-DaniSavePointPayload",
    "Sync-DaniCloudSavePoint",
    "Restore-DaniCloudSavePoint"
)
