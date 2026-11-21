# PowerShell 7 JSON and byte helpers shared by kernel modules.
function ConvertTo-DaniHashtable {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $result = @{}
            foreach ($key in $InputObject.Keys) { $result[$key] = ConvertTo-DaniHashtable $InputObject[$key] }
            return ,$result
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $result = @{}
            foreach ($property in $InputObject.PSObject.Properties) { $result[$property.Name] = ConvertTo-DaniHashtable $property.Value }
            return ,$result
        }
        if ($InputObject -is [array]) {
            $result = @(); foreach ($item in $InputObject) { $result += ,(ConvertTo-DaniHashtable $item) }; return ,$result
        }
        return $InputObject
    }
}
function ConvertFrom-DaniJson {
    param([Parameter(ValueFromPipeline = $true)][string]$Json)
    process { ConvertTo-DaniHashtable (ConvertFrom-Json -InputObject $Json -AsHashtable) }
}
function ConvertTo-DaniHex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}
function New-DaniRandomBytes {
    param([Parameter(Mandatory)][int]$Count)
    $bytes = New-Object byte[] $Count
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ,$bytes
}
