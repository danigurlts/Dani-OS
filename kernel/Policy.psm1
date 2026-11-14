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
                $link = $fileInfo.ResolveLinkTarget($true)
                $currentResolved = if ($null -ne $link) { $link.FullName } else { $fileInfo.FullName }
            } elseif (Test-Path $candidate -PathType Container) {
                $dirInfo = [System.IO.DirectoryInfo]::new($candidate)
                $link = $dirInfo.ResolveLinkTarget($true)
                $currentResolved = if ($null -ne $link) { $link.FullName } else { $dirInfo.FullName }
            } else {
                $currentResolved = [System.IO.Path]::Combine($currentResolved, $seg)
            }
        }
        return [System.IO.Path]::GetFullPath($currentResolved)
    } catch {
        throw "SecurityFault [PathResolutionFailed]: Unable to securely resolve physical path '$Path'. Access denied."
    }
}
