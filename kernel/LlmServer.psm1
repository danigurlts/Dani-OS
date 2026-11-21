#Requires -Version 7.0
Set-StrictMode -Version Latest

$script:DaniRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:LlmPort = 9931
$script:LlmProcess = $null
$script:LlmManagedPort = $null

function Invoke-DaniLlmBridge {
    param([string]$Action, [hashtable]$Payload)
    if (-not (Get-Command Invoke-DaniPolyglotBridge -ErrorAction SilentlyContinue)) {
        throw 'Import kernel/Bridge.psm1 before using the LLM controls.'
    }
    $result = Invoke-DaniPolyglotBridge -Operation Send -Domain PHP -Action $Action -Payload $Payload
    if (-not $result.Ok) { throw $result.Error }
    return $result.Data
}

function Get-DaniLlmServerStatus {
    [CmdletBinding()]
    param([ValidateRange(1, 65535)][int]$Port = $script:LlmPort)

    $healthy = $false
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
        $healthy = $true
    } catch {}
    $managed = $null -ne $script:LlmProcess -and -not $script:LlmProcess.HasExited -and $script:LlmManagedPort -eq $Port
    return [PSCustomObject]@{ Running = ($managed -or $healthy); Ready = $healthy; Managed = $managed; ProcessId = $(if ($managed) { $script:LlmProcess.Id } else { $null }); Port = $Port }
}

function Start-DaniLlmServer {
    [CmdletBinding()]
    param(
        [string]$ModelPath = (Join-Path $script:DaniRoot 'kernel/models/qwen2.5-3b-instruct-q5_k_m.gguf'),
        [string]$ServerPath = (Join-Path $script:DaniRoot 'native/llama-server.exe'),
        [ValidateRange(1, 65535)][int]$Port = $script:LlmPort,
        [ValidateRange(512, 32768)][int]$ContextTokens = 4096,
        [ValidateRange(1, 256)][int]$Threads = 3,
        [ValidateRange(0, 999)][int]$GpuLayers = 0,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 180
    )

    $ModelPath = [IO.Path]::GetFullPath($ModelPath)
    $ServerPath = [IO.Path]::GetFullPath($ServerPath)
    if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) { throw "Model not found: $ModelPath" }
    if (-not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) { throw "llama-server not found: $ServerPath" }
    if ($script:LlmProcess -and $script:LlmProcess.HasExited) {
        $script:LlmProcess.Dispose()
        $script:LlmProcess = $null
        $script:LlmManagedPort = $null
    }
    if ($script:LlmProcess) {
        if ($script:LlmManagedPort -ne $Port) { throw "PowerShell already manages an LLM server on port $script:LlmManagedPort." }
    }
    $current = Get-DaniLlmServerStatus -Port $Port
    if ($current.Ready) { return $current }

    if (-not $script:LlmProcess) {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $ServerPath
        $psi.WorkingDirectory = Split-Path -Parent $ServerPath
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($arg in @('-m', $ModelPath, '--host', '127.0.0.1', '--port', "$Port", '-c', "$ContextTokens", '-t', "$Threads", '-ngl', "$GpuLayers", '--alias', 'qwen2.5-3b')) {
            $psi.ArgumentList.Add($arg)
        }
        $script:LlmProcess = [Diagnostics.Process]::Start($psi)
        if ($null -eq $script:LlmProcess) { throw 'PowerShell could not start llama-server.' }
        $script:LlmManagedPort = $Port
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 1
        $status = Get-DaniLlmServerStatus -Port $Port
        if ($status.Ready) { return $status }
        if ($script:LlmProcess.HasExited) { throw "llama-server exited during startup (code $($script:LlmProcess.ExitCode))." }
    }
    Stop-DaniLlmServer -Port $Port | Out-Null
    throw "llama-server did not become ready on port $Port within $TimeoutSeconds seconds."
}

function Stop-DaniLlmServer {
    [CmdletBinding()]
    param([ValidateRange(1, 65535)][int]$Port = $script:LlmPort)
    if ($null -eq $script:LlmProcess -or $script:LlmManagedPort -ne $Port) { return [PSCustomObject]@{ Stopped = $false; Managed = $false; Port = $Port } }
    if (-not $script:LlmProcess.HasExited) {
        $script:LlmProcess.Kill()
        $script:LlmProcess.WaitForExit(5000) | Out-Null
    }
    $id = $script:LlmProcess.Id
    $script:LlmProcess.Dispose()
    $script:LlmProcess = $null
    $script:LlmManagedPort = $null
    return [PSCustomObject]@{ Stopped = $true; ProcessId = $id; Port = $Port }
}

function Invoke-DaniLlmChat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Messages,
        [string]$Model = 'qwen2.5-3b',
        [ValidateRange(0.0, 2.0)][double]$Temperature = 0.0,
        [ValidateRange(1, 4096)][int]$MaxTokens = 96,
        [ValidateRange(1, 65535)][int]$Port = $script:LlmPort
    )
    return Invoke-DaniLlmBridge LlmChat @{ port = $Port; model = $Model; messages = $Messages; temperature = $Temperature; max_tokens = $MaxTokens }
}

Export-ModuleMember -Function Start-DaniLlmServer, Stop-DaniLlmServer, Get-DaniLlmServerStatus, Invoke-DaniLlmChat
