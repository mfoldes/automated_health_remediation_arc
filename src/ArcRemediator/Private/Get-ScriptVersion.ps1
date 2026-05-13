#Requires -Version 5.1

function Get-ScriptVersion {
    <#
        .SYNOPSIS
            Return the remediator's installed version string for the
            ScriptVersion column in the LAW row.

        .DESCRIPTION
            Reads <ModuleRoot>/Data/version.txt. Falls back to the
            ArcRemediator.psd1 ModuleVersion when version.txt is missing
            so the function never throws and the orchestrator can always
            populate the LAW row.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidate = Join-Path $script:ModuleRoot 'Data/version.txt'
    if (Test-Path -LiteralPath $candidate) {
        try {
            $raw = (Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop).Trim()
            if ($raw) { return $raw }
        } catch {
            $null = $_
        }
    }

    try {
        $psd1 = Join-Path $script:ModuleRoot 'ArcRemediator.psd1'
        $data = Import-PowerShellDataFile -LiteralPath $psd1 -ErrorAction Stop
        if ($data.ModuleVersion) { return [string]$data.ModuleVersion }
    } catch {
        $null = $_
    }

    return '0.0.0'
}
