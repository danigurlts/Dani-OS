function Get-RealCanonicalPath {
    param([string]$Path)
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($fullPath)
        $trimmedPath = $fullPath.Substring($root.Length)
        
        $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $segments = if ([string]::IsNullOrEmpty($trimmedPath)) { @() } else { $trimmedPath.Split($separators, [System.StringSplitOptions]::RemoveEmptyEntries) }

        $currentResolved = $root
        foreach ($seg in $segments) {
            $candidate = [System.IO.Path]::Combine($currentResolved, $seg)
            if (Test-Path $candidate -PathType Leaf) {
                $fileInfo = [System.IO.FileInfo]::new($candidate)
                if (($fileInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse points are not allowed in protected paths." }
                $currentResolved = $fileInfo.FullName
            } elseif (Test-Path $candidate -PathType Container) {
                $dirInfo = [System.IO.DirectoryInfo]::new($candidate)
                if (($dirInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse points are not allowed in protected paths." }
                $currentResolved = $dirInfo.FullName
            } else {
                $currentResolved = [System.IO.Path]::Combine($currentResolved, $seg)
            }
        }
        return [System.IO.Path]::GetFullPath($currentResolved)
    } catch {
        throw "SecurityFault [PathResolutionFailed]: Unable to securely resolve physical path '$Path'. Access denied."
    }
}

Export-ModuleMember -Function Get-RealCanonicalPath
