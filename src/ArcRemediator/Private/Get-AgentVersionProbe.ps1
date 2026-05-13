#Requires -Version 5.1

function Get-AgentVersionProbe {
    <#
        .SYNOPSIS
            Compare the local Connected Machine agent version against a
            configurable supported floor.

        .DESCRIPTION
             the agent version floor is chosen at
            implementation time from Microsoft guidance, not hard-coded
            to a stale value. The caller passes the floor; we compare
            using [version] (System.Version) so '1.45.0' < '1.45.10' is
            handled correctly. If the agent does not expose its version
            string (or the parse fails), MeetsFloor is $null rather than
            $false - the caller should treat that as Unknown.

        .PARAMETER ConnectivitySettings
            The result of Get-ArcConnectivitySettings. Its AgentVersion
            field is the authoritative source.

        .PARAMETER SupportedFloor
            Minimum supported agent version. Required so this never
            falls back to a stale baked-in value. Microsoft documents
            current supported versions; the caller picks it at run time.

        .OUTPUTS
            PSCustomObject with:
              Version (string|null)
              ParsedVersion ([version]|null)
              SupportedFloor (string)
              MeetsFloor (bool|null) $null means parse failed / unknown
              Status ('OK'|'Below'|'Unknown')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSObject]$ConnectivitySettings,
        [Parameter(Mandatory)] [string]$SupportedFloor
    )

    $verString = $null
    if ($ConnectivitySettings.PSObject.Properties.Name -contains 'AgentVersion') {
        $verString = [string]$ConnectivitySettings.AgentVersion
    }

    $parsed = $null
    $floorParsed = $null
    $meetsFloor = $null
    $status = 'Unknown'

    if (-not [string]::IsNullOrWhiteSpace($verString)) {
        [version]$tmp = $null
        if ([version]::TryParse($verString, [ref]$tmp)) { $parsed = $tmp }
    }
    [version]$floorTmp = $null
    if ([version]::TryParse($SupportedFloor, [ref]$floorTmp)) { $floorParsed = $floorTmp }

    if ($parsed -and $floorParsed) {
        $meetsFloor = ($parsed -ge $floorParsed)
        $status = if ($meetsFloor) { 'OK' } else { 'Below' }
    }

    return [PSCustomObject]@{
        Version = $verString
        ParsedVersion = $parsed
        SupportedFloor = $SupportedFloor
        MeetsFloor = $meetsFloor
        Status = $status
    }
}
