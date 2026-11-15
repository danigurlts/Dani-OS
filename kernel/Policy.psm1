[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
    [Parameter()][ValidateNotNullOrEmpty()][string]$AllowedRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-PhysicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath)

    $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $trimmedPath = $fullPath.Substring($root.Length)
    $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $segments = if ([string]::IsNullOrEmpty($trimmedPath)) {
        @()
    } else {
        $trimmedPath.Split($separators, [System.StringSplitOptions]::RemoveEmptyEntries)
    }

    $currentResolved = $root
    foreach ($segment in $segments) {
        $candidate = [System.IO.Path]::Combine($currentResolved, $segment)
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            $currentResolved = $candidate
            continue
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $link = $item.ResolveLinkTarget($true)
            if ($null -eq $link) {
                throw [System.IO.IOException]::new('Unable to resolve reparse point.')
            }
            $currentResolved = $link.FullName
        } else {
            $currentResolved = $item.FullName
        }
    }
    return [System.IO.Path]::GetFullPath($currentResolved)
}

try {
    $resolvedPath = Resolve-PhysicalPath -LiteralPath $Path
    if ($PSBoundParameters.ContainsKey('AllowedRoot')) {
        $resolvedRoot = Resolve-PhysicalPath -LiteralPath $AllowedRoot
        $rootPrefix = $resolvedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        $isRoot = [string]::Equals($resolvedPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar), $resolvedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar), $comparison)
        if (-not $isRoot -and -not $resolvedPath.StartsWith($rootPrefix, $comparison)) {
            throw [System.UnauthorizedAccessException]::new('Resolved path is outside the allowed root.')
        }
    }
    $resolvedPath
} catch {
    throw "SecurityFault [PathResolutionFailed]: Unable to securely resolve path. Access denied."
}
