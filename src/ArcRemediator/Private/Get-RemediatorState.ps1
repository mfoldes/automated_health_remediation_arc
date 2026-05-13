#Requires -Version 5.1

function Get-RemediatorState {
    <#
        .SYNOPSIS
            Read the persisted remediator state from disk.

        .DESCRIPTION
            Returns the deserialized state object from state.json. If the file
            does not exist, returns the canonical default state via
            New-DefaultRemediatorState - this is the only "missing means
            defaults" path. Empty or corrupt JSON THROWS and does NOT
            silently substitute defaults, because the destructive Expired
            attempt marker lives in this file and silently forgetting it
            would let a stuck/repeating attempt slip past cooldown.

        .PARAMETER Path
            State file path. Defaults to %ProgramData%\ArcRemediator\state.json.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string]$Path = (Join-Path $env:ProgramData 'ArcRemediator\state.json')
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return New-DefaultRemediatorState
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        throw "Failed to read remediator state at '$Path': $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Remediator state file at '$Path' is empty; refusing to silently substitute defaults."
    }

    try {
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Remediator state file at '$Path' contains invalid JSON: $($_.Exception.Message)"
    }
}
