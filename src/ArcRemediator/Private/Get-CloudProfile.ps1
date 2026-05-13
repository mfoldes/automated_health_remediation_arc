#Requires -Version 5.1

function Get-CloudProfile {
    <#
        .SYNOPSIS
            Load the endpoint/audience/capability profile for an MVP cloud.

        .DESCRIPTION
            Reads Data/cloud-profiles.psd1 and returns the matching profile
            as a PSCustomObject. The ValidateSet on -Name pins this to the
            two MVP clouds; adding a new profile to the psd1 also requires
            extending the ValidateSet, which is intentional, the implementation must not infer endpoints or
            capability flags for unsupported clouds.

        .PARAMETER Name
            Cloud profile name. One of: Commercial, AzureGovernmentDoD.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('Commercial', 'AzureGovernmentDoD')]
        [string]$Name
    )

    $profilePath = Join-Path $script:ModuleRoot 'Data/cloud-profiles.psd1'
    $profiles = Import-PowerShellDataFile -LiteralPath $profilePath -ErrorAction Stop

    if (-not $profiles.ContainsKey($Name)) {
        throw "Cloud profile '$Name' is declared in code but missing from cloud-profiles.psd1."
    }

    return [PSCustomObject]$profiles[$Name]
}
