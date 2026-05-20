#Requires -Version 5.1

function New-DefaultRemediatorState {
    <#
        .SYNOPSIS
            Build a fresh remediator state object with every field at its
            documented default.

        .DESCRIPTION
            The shape returned here is the canonical state schema referenced (safety controls) and section 8.4 (Expired
            remediation). Get-RemediatorState returns one of these when
            state.json is absent, and callers that need a starting state
            can use this helper directly. The function is a pure factory
            with no I/O or side effects despite the "New-" verb; the
            ShouldProcess analyzer warning is suppressed accordingly.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory; constructs an in-memory PSObject with no I/O. The "New-" verb is misclassified as state-changing here.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    return [PSCustomObject]@{
        SchemaVersion = 1
        LastSuccessfulRunUtc = $null
        ConsecutiveFailures = 0
        BreakerTripped = $false
        BreakerLastResetUtc = $null
        LastExpiredAttemptId = $null
        LastExpiredAttemptResourceId = $null
        LastExpiredAttemptStartedUtc = $null
        LastExpiredAttemptCompletedUtc = $null
        LastExpiredAttemptOutcome = $null
        LastServiceRepairUtc = $null
        BreakerTrippedUtc = $null
        ResetByUser = $null
    }
}
