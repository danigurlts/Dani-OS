#Requires -Version 7.0
using namespace System.IO.Pipes
using namespace System.Text
using namespace System.Security.Cryptography

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Compat.ps1')

$script:KernelSeedDir = Join-Path $PSScriptRoot "seeds"
$script:SessionNonce  = ConvertTo-DaniHex (New-DaniRandomBytes 24)
$script:PipeRegistry  = @{
    Node   = "DaniOs.Pipe.Node"
    PHP    = "DaniOs.Pipe.PHP"
    Python = "DaniOs.Pipe.Python"
}

function Initialize-DaniGoldenMatrix {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ParallelPartitionRoot)

    $defaultFiles = @("default.md", "default.yml", "default.json")
    $tiers        = @("tier_1_active", "tier_2_rolling", "tier_3_baseline")

    foreach ($file in $defaultFiles) {
        $seedPath = Join-Path $script:KernelSeedDir $file
        if (-not (Test-Path $seedPath) -or (Get-Item $seedPath).Length -eq 0) {
            throw "FATAL KERNEL PANIC: Missing or empty golden seed '$file'."
        }
    }

    foreach ($tier in $tiers) {
        $tierPath = Join-Path $ParallelPartitionRoot $tier
        if (-not (Test-Path $tierPath)) {
            New-Item -ItemType Directory -Path $tierPath -Force | Out-Null
        }

        $map = @{
            "journal.md"    = Join-Path $script:KernelSeedDir "default.md"
            "solutions.yml" = Join-Path $script:KernelSeedDir "default.yml"
            "state.json"    = Join-Path $script:KernelSeedDir "default.json"
        }

        foreach ($targetName in $map.Keys) {
            $targetFile = Join-Path $tierPath $targetName
            if (-not (Test-Path $targetFile) -or (Get-Item $targetFile).Length -eq 0) {
                Copy-Item -Path $map[$targetName] -Destination $targetFile -Force
            }
        }
    }

    return [PSCustomObject]@{
        Status         = "MatrixReady"
        PartitionRoot  = $ParallelPartitionRoot
        ActiveNodes    = 9
        BrowserSession = $script:SessionNonce
        TimestampUtc   = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Test-DaniZonePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("NativeToUnsecure", "UnsecureToNative")][string]$Direction,
        [Parameter(Mandatory)][ValidateSet("Node", "PHP", "Python")][string]$Domain,
        [Parameter(Mandatory)][hashtable]$Envelope
    )

    if ($Direction -eq "UnsecureToNative") {
        if ($Envelope.Nonce -ne $script:SessionNonce) {
            throw "ZoneBoundaryViolation: Invalid or missing session nonce from '$Domain'."
        }

        $serialized = ($Envelope | ConvertTo-Json -Depth 6 -Compress)
        if ($serialized -match "(?i)([/\\](tier_1_active|tier_2_rolling|tier_3_baseline)|[/\\]kernel[/\\]seeds)") {
            throw "ZoneBoundaryViolation: Unsecure domain '$Domain' attempted restricted path traversal."
        }
    }

    if ($Direction -eq "NativeToUnsecure") {
        if ($Envelope.Payload -is [hashtable] -and $Envelope.Payload.ContainsKey("KernelMasterKey")) {
            $Envelope.Payload.Remove("KernelMasterKey")
        }
    }

    return $true
}

function Invoke-DaniPolyglotBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Read", "Write", "Receive", "Send")][string]$Operation,
        [Parameter(Mandatory)][ValidateSet("Node", "PHP", "Python")][string]$Domain,
        [Parameter(Mandatory)][string]$Action,
        [hashtable]$Payload = @{},
        [int]$TimeoutMs = 4000
    )

    $direction = switch ($Operation) {
        { $_ -in @("Send", "Write") }   { "NativeToUnsecure" }
        { $_ -in @("Receive", "Read") } { "UnsecureToNative" }
    }

    $envelope = @{
        Id        = [guid]::NewGuid().ToString()
        Nonce     = $script:SessionNonce
        Operation = $Operation
        Domain    = $Domain
        Action    = $Action
        Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        Payload   = $Payload
    }

    Test-DaniZonePayload -Direction $direction -Domain $Domain -Envelope $envelope | Out-Null

    $pipeName = $script:PipeRegistry[$Domain]
    $client   = [NamedPipeClientStream]::new(".", $pipeName, [PipeDirection]::InOut)

    try {
        $client.Connect($TimeoutMs)
        $writer = [System.IO.StreamWriter]::new($client, [UTF8Encoding]::new($false))
        $reader = [System.IO.StreamReader]::new($client, [UTF8Encoding]::new($false))
        $writer.AutoFlush = $true

        $jsonRequest = ($envelope | ConvertTo-Json -Depth 8 -Compress)
        $writer.WriteLine($jsonRequest)

        $rawResponse = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($rawResponse)) {
            throw "NamedPipeEmptyResponse from domain '$Domain'."
        }

        $parsed = $rawResponse | ConvertFrom-DaniJson
        Test-DaniZonePayload -Direction "UnsecureToNative" -Domain $Domain -Envelope $parsed | Out-Null

        return [PSCustomObject]@{
            Ok        = $true
            Domain    = $Domain
            Operation = $Operation
            Action    = $Action
            Data      = $parsed.Payload
        }
    }
    catch {
        $faultRecord = [PSCustomObject]@{
            Ok        = $false
            Domain    = $Domain
            Operation = $Operation
            Action    = $Action
            Error     = $_.Exception.Message
            Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        }

        if ([System.Management.Automation.PSTypeName]'DaniOs.Kernel.AI'.Type) {
            $faultRecord | Add-Member -NotePropertyName "AiDiagnosis" -NotePropertyValue ([DaniOs.Kernel.AI]::DiagnoseFault($faultRecord))
        }

        return $faultRecord
    }
    finally {
        $client.Dispose()
    }
}

function Send-DaniBrowserEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][hashtable]$Data
    )

    return Invoke-DaniPolyglotBridge -Operation "Send" -Domain "Node" -Action "BroadcastBrowserWS" -Payload @{
        channel = $Channel
        data    = $Data
    }
}

function Invoke-DaniWebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [ValidateSet("GET", "POST", "PUT", "DELETE")][string]$Method = "GET",
        [hashtable]$Headers = @{},
        [object]$Body = $null
    )

    return Invoke-DaniPolyglotBridge -Operation "Send" -Domain "PHP" -Action "ExecuteHttpCall" -Payload @{
        url     = $Url
        method  = $Method
        headers = $Headers
        body    = $Body
    }
}

Export-ModuleMember -Function @(
    "Initialize-DaniGoldenMatrix",
    "Test-DaniZonePayload",
    "Invoke-DaniPolyglotBridge",
    "Send-DaniBrowserEvent",
    "Invoke-DaniWebRequest"
)
