#Requires -Version 5.1

function Get-BreakerResetState {
    <#
        .SYNOPSIS
            Read the breaker-reset SAS blob and determine whether the
            circuit breaker should be auto-reset for this run.

        .DESCRIPTION
            The breaker-reset blob holds an ISO-8601 UTC timestamp written
            by the operator. If the timestamp is more recent than the
            machine's BreakerTrippedUtc, the breaker should auto-reset.

            The blob is fetched via Invoke-RestMethodWithTls so the same
            TLS 1.2+ floor applies as for all other calls. The SAS URL
            credential in the query string is scrubbed from all errors.

            Fail-closed: missing blob, network error, unparseable content,
            or any exception returns ShouldReset=$false.

        .PARAMETER BreakerResetUrl
            The Service SAS URL of the breaker-reset blob. Must be a
            full https:// URL.

        .PARAMETER BreakerTrippedUtc
            ISO-8601 UTC string of when the breaker tripped on this
            machine. The blob timestamp must be strictly after this value
            for a reset to occur.

        .PARAMETER TimeoutSec
            HTTP request timeout. Default 15 seconds.

        .OUTPUTS
            PSCustomObject with:
              ShouldReset (bool)
              ResetTimestamp (string|null) - ISO-8601 from blob
              Reason (string)
              LastError (string|null) - error detail with SAS redacted
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$BreakerResetUrl,

        [Parameter()]
        [AllowEmptyString()]
        [string]$BreakerTrippedUtc,

        [Parameter()]
        [int]$TimeoutSec = 15
    )

    if ([string]::IsNullOrWhiteSpace($BreakerResetUrl) -or
        ($BreakerResetUrl -notmatch '^https?://')) {
        return [PSCustomObject]@{
            ShouldReset = $false
            ResetTimestamp = $null
            Reason = 'NoUrl'
            LastError = $null
        }
    }

    try {
        $raw = Invoke-RestMethodWithTls `
            -Uri $BreakerResetUrl `
            -Method 'GET' `
            -TimeoutSec $TimeoutSec
    } catch {
        $msg = Get-RedactedSasError -Message $_.Exception.Message
        return [PSCustomObject]@{
            ShouldReset = $false
            ResetTimestamp = $null
            Reason = 'Unreachable'
            LastError = $msg
        }
    }

    $text = if ($null -ne $raw) { [string]$raw } else { '' }
    $trimmed = $text.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return [PSCustomObject]@{
            ShouldReset = $false
            ResetTimestamp = $null
            Reason = 'EmptyBlob'
            LastError = $null
        }
    }

    $resetTime = [datetime]::MinValue
    if (-not [datetime]::TryParse($trimmed, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$resetTime)) {
        return [PSCustomObject]@{
            ShouldReset = $false
            ResetTimestamp = $trimmed
            Reason = 'UnparseableTimestamp'
            LastError = "Blob content '$trimmed' is not a valid ISO-8601 timestamp."
        }
    }

    # Compare blob timestamp to BreakerTrippedUtc.
    if ([string]::IsNullOrWhiteSpace($BreakerTrippedUtc)) {
        # No trip timestamp recorded; reset is safe (blob exists + valid).
        return [PSCustomObject]@{
            ShouldReset = $true
            ResetTimestamp = $trimmed
            Reason = 'ResetNewerThanTrip'
            LastError = $null
        }
    }

    $trippedTime = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$BreakerTrippedUtc, [ref]$trippedTime)) {
        return [PSCustomObject]@{
            ShouldReset = $false
            ResetTimestamp = $trimmed
            Reason = 'UnparseableTripTime'
            LastError = "BreakerTrippedUtc '$BreakerTrippedUtc' is not a valid timestamp."
        }
    }

    if ($resetTime.ToUniversalTime() -gt $trippedTime.ToUniversalTime()) {
        return [PSCustomObject]@{
            ShouldReset = $true
            ResetTimestamp = $trimmed
            Reason = 'ResetNewerThanTrip'
            LastError = $null
        }
    }

    return [PSCustomObject]@{
        ShouldReset = $false
        ResetTimestamp = $trimmed
        Reason = 'ResetOlderThanTrip'
        LastError = "Blob timestamp $trimmed is not after BreakerTrippedUtc $BreakerTrippedUtc."
    }
}
