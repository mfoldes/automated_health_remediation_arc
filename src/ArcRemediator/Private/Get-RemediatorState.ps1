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
        $state = ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Remediator state file at '$Path' contains invalid JSON: $($_.Exception.Message)"
    }

    # Upcast state files written by older versions that pre-date SchemaVersion.
    # The only safe upcast is to stamp the version; no field deltas exist yet.
    if (-not $state.PSObject.Properties['SchemaVersion']) {
        $state | Add-Member -NotePropertyName 'SchemaVersion' -NotePropertyValue 0
    }
    if ($state.SchemaVersion -lt 1) {
        $state.SchemaVersion = 1
    }

    # ---- HMAC tamper detection -------------------------------------------
    # Three cases:
    #   A. Key absent + StateHmac absent → pre-upgrade machine; pass through.
    #   B. Key absent + StateHmac present → key was deleted AFTER state was
    #      signed; treat as tamper (attacker deleted key to bypass check).
    #   C. Key present + StateHmac present → verify; mismatch = tamper.
    #   D. Key present + StateHmac absent → pre-upgrade file; pass through.
    $hmacKey = $null
    try { $hmacKey = Get-StateHmacKey } catch { $hmacKey = $null }
    $storedHmac = if ($state.PSObject.Properties['StateHmac']) { [string]$state.StateHmac } else { $null }

    $tamperDetected = $false
    if ($null -eq $hmacKey -and $storedHmac) {
        # Case B: key gone but HMAC present.
        $tamperDetected = $true
    } elseif ($hmacKey -and $storedHmac) {
        # Case C: verify.
        $stateForHmac = $state | Select-Object -Property * -ExcludeProperty StateHmac
        $jsonForHmac = $stateForHmac | ConvertTo-Json -Depth 10
        try {
            $expectedHmac = Get-StateHmac -Json $jsonForHmac -Key $hmacKey
            if ($storedHmac -cne $expectedHmac) {
                $tamperDetected = $true
            }
        } catch {
            $tamperDetected = $true
        }
    }
    # Case A (no key, no HMAC) and Case D (key present, no HMAC) pass through.

    if ($tamperDetected) {
        Write-SecurityEventLog -EventId 1006 -Message "ArcRemediator: state.json HMAC mismatch on machine $env:COMPUTERNAME at '$Path'. Returning fail-closed defaults." -EntryType 'Error'
        $defaults = New-DefaultRemediatorState
        $defaults.BreakerTripped = $true
        $defaults.BreakerTrippedUtc = (Get-Date).ToUniversalTime().ToString('o')
        return $defaults
    }

    return $state
}
