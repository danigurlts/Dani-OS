#Requires -Version 7.4
using namespace System.IO
using namespace System.Management.Automation.Language
using namespace System.Collections.Generic

Set-StrictMode -Version Latest

$script:ImmutableKernelPatterns = @(
    "[/\\]kernel[/\\]bin([/\\]|$)",
    "[/\\]kernel[/\\]models([/\\]|$)",
    "[/\\]kernel[/\\]seeds([/\\]|$)",
    "[/\\]kernel[/\\]Policy\.psm1$",
    "[/\\]boot[/\\]DaniOs\.Boot",
    "[/\\]\.parallel_3x3_firewall([/\\]|$)",
    "[/\\](tier_1_active|tier_2_rolling|tier_3_baseline)([/\\]|$)"
)

$script:BlockedAstCommands = [HashSet[string]]::new([string[]]@(
    "Invoke-Expression", "iex",
    "Invoke-WebRequest", "iwr", "curl", "wget",
    "Invoke-RestMethod", "irm",
    "Start-BitsTransfer",
    "Format-Volume", "Format-Disk", "Clear-Disk", "Remove-Partition",
    "Stop-Computer", "Restart-Computer",
    "Set-ExecutionPolicy",
    "Add-MpPreference", "Set-MpPreference", "Disable-WindowsDefender",
    "New-LocalUser", "Add-LocalGroupMember",
    "reg", "bcdedit", "diskpart", "cipher", "vssadmin"
), [System.StringComparer]::OrdinalIgnoreCase)

$script:BlockedAstTypePatterns = @(
    "System\.Reflection\.Assembly",
    "System\.Runtime\.InteropServices\.Marshal",
    "System\.Net\.Sockets",
    "System\.Net\.Http\.HttpClient",
    "System\.Net\.WebClient",
    "Microsoft\.Win32\.Registry"
)

function Test-DaniImmutablePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $normalized = $Path.Replace("\", "/")
    foreach ($pattern in $script:ImmutableKernelPatterns) {
        if ($normalized -match $pattern) {
            return $true
        }
    }
    return $false
}

function Test-DaniScriptAst {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptText,
        [string[]]$AllowedCommands = @()
    )

    $violations = [List[string]]::new()
    $tokens     = $null
    $parseErrs  = $null

    $ast = [Parser]::ParseInput($ScriptText, [ref]$tokens, [ref]$parseErrs)

    if ($null -ne $parseErrs -and $@(parseErrs).Count -gt 0) {
        foreach ($err in $parseErrs) {
            $violations.Add("SyntaxError (Line $($err.Extent.StartLineNumber)): $($err.Message)")
        }
        return [PSCustomObject]@{
            Approved   = $false
            Violations = @($violations)
            AstSummary = $null
        }
    }

    $allowSet     = [HashSet[string]]::new([string[]]$AllowedCommands, [System.StringComparer]::OrdinalIgnoreCase)
    $commandNodes = $ast.FindAll({ param($node) $node -is [CommandAst] }, $true)
    $detectedCmds = [HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($cmdNode in $commandNodes) {
        $cmdName = $cmdNode.GetCommandName()

        if ([string]::IsNullOrWhiteSpace($cmdName)) {
            $violations.Add("DynamicInvocationBlocked (Line $($cmdNode.Extent.StartLineNumber)): '$($cmdNode.Extent.Text)'")
            continue
        }

        [void]$detectedCmds.Add($cmdName)

        if ($script:BlockedAstCommands.Contains($cmdName) -and -not $allowSet.Contains($cmdName)) {
            $violations.Add("BlockedCommand (Line $($cmdNode.Extent.StartLineNumber)): '$cmdName' is forbidden by Kernel Policy.")
        }

        if ($cmdName -in @("Remove-Item", "rm", "del", "ri", "Clear-Content", "Set-Content", "Out-File", "Move-Item", "Rename-Item")) {
            $rawExtent = $cmdNode.Extent.Text
            if ($rawExtent -match "(?i)(^|\s)(/|\\|[A-Za-z]:\\?\s*\*|\.\.[\\/])") {
                $violations.Add("UnsafeFileTarget (Line $($cmdNode.Extent.StartLineNumber)): Root or parent traversal in '$rawExtent'.")
            }
        }
    }

    $stringNodes = $ast.FindAll({ param($node) $node -is [StringConstantExpressionAst] }, $true)
    foreach ($strNode in $stringNodes) {
        if (Test-DaniImmutablePath -Path $strNode.Value) {
            $violations.Add("ImmutablePathReference (Line $($strNode.Extent.StartLineNumber)): Script references protected path '$($strNode.Value)'.")
        }
    }

    $typeNodes = $ast.FindAll({ param($node) $node -is [TypeExpressionAst] -or $node -is [TypeConstraintAst] }, $true)
    foreach ($tNode in $typeNodes) {
        $typeName = $tNode.TypeName.FullName
        foreach ($blockedType in $script:BlockedAstTypePatterns) {
            if ($typeName -match $blockedType) {
                $violations.Add("BlockedDotNetType (Line $($tNode.Extent.StartLineNumber)): Type '[$typeName]' is restricted.")
            }
        }
    }

    $paramNodes = $ast.FindAll({ param($node) $node -is [CommandParameterAst] }, $true)
    foreach ($pNode in $paramNodes) {
        if ($pNode.ParameterName -match "^(e|ec|enc|enco|encod|encode|encoded|encodedcommand)$") {
            $violations.Add("ObfuscatedParameterBlocked (Line $($pNode.Extent.StartLineNumber)): '-$($pNode.ParameterName)' is forbidden.")
        }
    }

    return [PSCustomObject]@{
        Approved   = ($@(violations).Count -eq 0)
        Violations = @($violations)
        AstSummary = [PSCustomObject]@{
            CommandCount = $@(commandNodes).Count
            Commands     = @($detectedCmds)
        }
    }
}

function Test-DaniWebToNativeRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Node", "PHP", "Python", "BrowserUI")][string]$SourceDomain,
        [Parameter(Mandatory)][ValidateSet("Read", "Write", "Delete", "Execute")][string]$Intent,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$NativeRoot,
        [string]$ContentPreview = ""
    )

    if ($SourceDomain -in @("PHP", "Python") -and $Intent -in @("Write", "Delete", "Execute")) {
        return [PSCustomObject]@{
            Allowed = $false
            Reason  = "ZoneFirewallDeny: Domain '$SourceDomain' lacks Zone 2 mutation privileges ($Intent)."
        }
    }

    if (Test-DaniImmutablePath -Path $TargetPath) {
        return [PSCustomObject]@{
            Allowed = $false
            Reason  = "ZoneFirewallDeny: Target '$TargetPath' lies inside protected Zone 0/1 perimeter."
        }
    }

    $resolvedNativeRoot = [Path]::GetFullPath($NativeRoot).TrimEnd([Path]::DirectorySeparatorChar, [Path]::AltDirectorySeparatorChar) + [Path]::DirectorySeparatorChar
    $candidateFullPath  = if ([Path]::IsPathRooted($TargetPath)) {
        [Path]::GetFullPath($TargetPath)
    }
    else {
        [Path]::GetFullPath((Join-Path $resolvedNativeRoot $TargetPath))
    }

    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $candidateFullPath.StartsWith($resolvedNativeRoot, $comparison)) {
        return [PSCustomObject]@{
            Allowed = $false
            Reason  = "PathTraversalBlocked: Resolved path '$candidateFullPath' escapes encapsulated NativeRoot."
        }
    }

    $ext = [Path]::GetExtension($candidateFullPath).ToLowerInvariant()
    $blockedExtensions = @(".exe", ".dll", ".sys", ".drv", ".bat", ".cmd", ".vbs", ".scr", ".msi", ".so", ".dylib")
    if ($Intent -eq "Write" -and $ext -in $blockedExtensions) {
        return [PSCustomObject]@{
            Allowed = $false
            Reason  = "ExecutableDropBlocked: Writing binary/script extension '$ext' from '$SourceDomain' is denied."
        }
    }

    if ($Intent -eq "Write" -and $ext -in @(".ps1", ".psm1") -and -not [string]::IsNullOrWhiteSpace($ContentPreview)) {
        $astAudit = Test-DaniScriptAst -ScriptText $ContentPreview
        if (-not $astAudit.Approved) {
            return [PSCustomObject]@{
                Allowed = $false
                Reason  = "AstPolicyRejected: $($astAudit.Violations -join '; ')"
            }
        }
    }

    return [PSCustomObject]@{
        Allowed      = $true
        ResolvedPath = $candidateFullPath
        Reason       = "ApprovedByKernelPolicy"
    }
}

function Invoke-DaniMediatedNativeWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Node", "BrowserUI")][string]$SourceDomain,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$NativeRoot,
        [Parameter(Mandatory)][string]$ParallelPartitionRoot
    )

    $verdict = Test-DaniWebToNativeRequest `
        -SourceDomain $SourceDomain `
        -Intent "Write" `
        -TargetPath $TargetPath `
        -NativeRoot $NativeRoot `
        -ContentPreview $Content

    if (-not $verdict.Allowed) {
        throw "PolicyViolation: $($verdict.Reason)"
    }

    $tx = Start-DaniKernelTransaction `
        -ParallelPartitionRoot $ParallelPartitionRoot `
        -Reason "MediatedWrite from $SourceDomain to $($verdict.ResolvedPath)"

    try {
        Add-DaniTransactionTarget -Transaction $tx -TargetPath $verdict.ResolvedPath

        $parentDir = Split-Path -Path $verdict.ResolvedPath -Parent
        if (-not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }

        Set-Content -Path $verdict.ResolvedPath -Value $Content -Encoding UTF8 -Force
        $commitInfo = Commit-DaniKernelTransaction -Transaction $tx -ParallelPartitionRoot $ParallelPartitionRoot

        return [PSCustomObject]@{
            Ok            = $true
            Path          = $verdict.ResolvedPath
            TransactionId = $tx.TransactionId
            Sha256        = $commitInfo.UpdatedHashes[$verdict.ResolvedPath]
        }
    }
    catch {
        Undo-DaniKernelTransaction -Transaction $tx | Out-Null
        throw
    }
}

Export-ModuleMember -Function @(
    "Test-DaniImmutablePath",
    "Test-DaniScriptAst",
    "Test-DaniWebToNativeRequest",
    "Invoke-DaniMediatedNativeWrite"
)



