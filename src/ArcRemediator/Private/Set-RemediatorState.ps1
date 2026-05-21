#Requires -Version 5.1

function Set-RemediatorState {
    <#
        .SYNOPSIS
            Persist the remediator state to disk atomically.

        .DESCRIPTION
            Writes -State as JSON to <Path>.tmp, then renames to <Path>. The
            atomic temp-then-rename keeps state.json from being half-written
            if the host crashes mid-call - important because the Expired
            attempt marker lives here and a torn write could let a destructive
            attempt slip past cooldown on retry.

            Creates the parent directory if absent.

        .PARAMETER State
            State object to persist. Typically returned from
            Get-RemediatorState or New-DefaultRemediatorState.

        .PARAMETER Path
            State file path. Defaults to %ProgramData%\ArcRemediator\state.json.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [PSObject]$State,

        [Parameter()]
        [string]$Path = (Join-Path $env:ProgramData 'ArcRemediator\state.json')
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 10

    # Remove any existing StateHmac field from the JSON before computing a
    # fresh HMAC so the hash covers stable content only (not itself).
    $stateForHmac = $State | Select-Object -Property * -ExcludeProperty StateHmac
    $jsonForHmac = $stateForHmac | ConvertTo-Json -Depth 10

    $hmacKey = $null
    try {
        $hmacKey = Get-StateHmacKey -Create
    } catch {
        $hmacKey = $null
    }
    if ($hmacKey) {
        try {
            $hmacValue = Get-StateHmac -Json $jsonForHmac -Key $hmacKey
            # Rebuild the final JSON with the HMAC appended.
            $stateForHmac | Add-Member -NotePropertyName 'StateHmac' -NotePropertyValue $hmacValue -Force
            $json = $stateForHmac | ConvertTo-Json -Depth 10
        } catch {
            # HMAC computation failed; write without signature rather than blocking the run.
            $json = $State | ConvertTo-Json -Depth 10
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write remediator state')) {
        return
    }

    $temp = "$Path.tmp"
    Set-Content -LiteralPath $temp -Value $json -Encoding UTF8 -NoNewline -ErrorAction Stop
    Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop
}
