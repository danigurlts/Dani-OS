#Requires -Version 7.0
using namespace System.IO
using namespace System.Security.AccessControl
using namespace System.Security.Principal
using namespace System.Security.Cryptography

[CmdletBinding()]
param(
    [string]$CloudOriginUrl,
    [string]$AccountSecret,
    [string]$ParallelPartitionPath,
    [switch]$SkipDotNetBuild,
    [switch]$SkipNpmInstall,
    [switch]$SkipVerification,
    [switch]$NonInteractive,
    [switch]$BootAfterInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DaniRoot       = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $DaniRoot "kernel\Compat.ps1")
$BootDir        = Join-Path $DaniRoot "boot"
$KernelDir      = Join-Path $DaniRoot "kernel"
$KernelBinDir   = Join-Path $KernelDir "bin"
$KernelModelDir = Join-Path $KernelDir "models"
$ConfigDir      = Join-Path $DaniRoot "config"
$NodePolyDir    = Join-Path $DaniRoot "polyglot\node"
$NativeZoneDir  = Join-Path $DaniRoot "native"

function Test-RuntimeRequirement {
    param([string]$Name, [string]$Command, [string[]]$VersionArgs, [version]$MinVersion, [string]$InstallHint)
    $cmdInfo = Get-Command -Name $Command -ErrorAction SilentlyContinue
    if ($null -eq $cmdInfo) { return [PSCustomObject]@{ Name = $Name; Found = $false; Version = "Not Installed"; MeetsMin = $false; InstallTip = $InstallHint } }
    try {
        $rawOut = (& $Command @VersionArgs 2>&1 | Out-String).Trim()
        if ($rawOut -match "(\d+\.\d+(?:\.\d+)?)") {
            $parsedVer = [version]$Matches[1]
            return [PSCustomObject]@{ Name = $Name; Found = $true; Version = $parsedVer.ToString(); MeetsMin = ($parsedVer -ge $MinVersion); InstallTip = $InstallHint }
        }
    } catch {}
    return [PSCustomObject]@{ Name = $Name; Found = $true; Version = "Unknown"; MeetsMin = $false; InstallTip = $InstallHint }
}

function Get-TargetRuntimeIdentifier {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return "win-x64" }
    throw "This installer targets PowerShell 7 and Windows only."
}

function Set-KernelOnlyFileAcl {
    param([string]$FilePath)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            $acl = Get-Acl -Path $FilePath
            $acl.SetAccessRuleProtection($true, $false)
            $systemSid = [SecurityIdentifier]::new([WellKnownSidType]::LocalSystemSid, $null)
            $adminSid  = [SecurityIdentifier]::new([WellKnownSidType]::BuiltinAdministratorsSid, $null)
            $usersSid  = [SecurityIdentifier]::new([WellKnownSidType]::BuiltinUsersSid, $null)
            $acl.AddAccessRule([FileSystemAccessRule]::new($systemSid, "FullControl", "Allow"))
            $acl.AddAccessRule([FileSystemAccessRule]::new($adminSid,  "FullControl", "Allow"))
            $acl.AddAccessRule([FileSystemAccessRule]::new($usersSid,  "FullControl", "Deny"))
            Set-Acl -Path $FilePath -AclObject $acl
        } catch {}
    } else { & chmod 600 $FilePath }
}

$pythonCmd = if (Get-Command "python3" -ErrorAction SilentlyContinue) { "python3" } else { "python" }
$checks = @(
    (Test-RuntimeRequirement -Name "Node.js"  -Command "node"     -VersionArgs @("--version")               -MinVersion ([version]"22.0.0") -InstallHint "Install Node.js 22+"),
    (Test-RuntimeRequirement -Name "PHP CLI"  -Command "php"      -VersionArgs @("-r", "echo PHP_VERSION;") -MinVersion ([version]"8.3.0")  -InstallHint "Install PHP 8.3+ CLI"),
    (Test-RuntimeRequirement -Name "Python"   -Command $pythonCmd -VersionArgs @("--version")               -MinVersion ([version]"3.11.0") -InstallHint "Install Python 3.11+")
)

$missingOrOld = @($checks | Where-Object { -not $_.MeetsMin })
if ($missingOrOld.Count -gt 0) {
    $missingOrOld | Format-Table Name, Version, InstallTip -AutoSize
    throw "Prerequisite check failed."
}

New-Item -ItemType Directory -Path $KernelBinDir, (Join-Path $KernelBinDir "native"), $KernelModelDir, $NativeZoneDir -Force | Out-Null


if (-not $SkipNpmInstall -and (Test-Path (Join-Path $NodePolyDir "package.json"))) {
    & npm install --prefix $NodePolyDir --no-audit --no-fund --loglevel=error
}

$exampleConfigPath = Join-Path $ConfigDir "kernel.config.example.json"
$liveConfigPath    = Join-Path $ConfigDir "kernel.config.json"
if (-not (Test-Path $liveConfigPath)) { Copy-Item -Path $exampleConfigPath -Destination $liveConfigPath -Force }

$Config = Get-Content -Path $liveConfigPath -Raw | ConvertFrom-DaniJson
if ($ParallelPartitionPath) { $Config.memoryMatrix.parallelPartitionPath = $ParallelPartitionPath }
if ($CloudOriginUrl)        { $Config.cloudOrigin.originUrl = $CloudOriginUrl }

if ($AccountSecret) {
    $Config.cloudOrigin.accountSecret = $AccountSecret
} elseif ($Config.cloudOrigin.accountSecret -eq "REPLACE_WITH_PROVISIONED_ACCOUNT_SECRET") {
    $Config.cloudOrigin.accountSecret = ConvertTo-DaniHex (New-DaniRandomBytes 32)
}

$Config | ConvertTo-Json -Depth 10 | Set-Content -Path $liveConfigPath -Encoding UTF8 -Force
Set-KernelOnlyFileAcl -FilePath $liveConfigPath

Import-Module (Join-Path $KernelDir "Bridge.psm1")      -Force
Import-Module (Join-Path $KernelDir "CloudOrigin.psm1") -Force
Import-Module (Join-Path $KernelDir "Core.psm1")        -Force

$partitionRoot = Mount-DaniParallelFirewallPartition -Config $Config
Initialize-DaniGoldenMatrix -ParallelPartitionRoot $partitionRoot | Out-Null

if (-not $SkipVerification) {
    & (Join-Path $DaniRoot "tests\Simulate-KernelFault.ps1")
}

if ($BootAfterInstall) { & (Join-Path $BootDir "init.ps1") -ConfigPath $liveConfigPath -Headless }
