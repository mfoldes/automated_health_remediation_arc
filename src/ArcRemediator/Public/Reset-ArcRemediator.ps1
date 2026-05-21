#Requires -Version 5.1

function Reset-ArcRemediator {
    <#
        .SYNOPSIS
            Clear the local circuit breaker so the next scheduled run
            can attempt remediation again.

        .DESCRIPTION
            The remediator's circuit breaker trips automatically after
            CircuitBreakerFailureThreshold consecutive failed runs
            (default 3). Once tripped, destructive actions are blocked
            until either the next verified-Healthy run clears it or an
            operator runs this command.

            Typical reasons to run Reset-ArcRemediator:

              * The fleet-wide breaker tripped during a brief ARM outage
                and you want a host to retry sooner than the next
                02:00 cycle.
              * A canary host's breaker tripped while you were
                investigating; you've fixed the root cause and want to
                lift the gate.

            By default the 7-day Expired-rejoin cooldown marker is
            preserved - it exists to keep a crashing destructive flow
            from repeating. Pass -AlsoClearExpiredAttempt to wipe the
            cooldown too. That re-arms destructive Expired remediation,
            so the function uses ConfirmImpact='High' and requires
            -Confirm:$false (or interactive confirmation) before doing it.

            Audit
                The local log records who ran the reset, the previous
                values, and the timestamp. The state file's ResetByUser
                field is set to "local:<identity>". The function
                deliberately does NOT POST a row to Log Analytics: the
                next successful scheduled run will emit a row with
                ResetByUser populated, and that's the authoritative
                cloud-side audit trail.

        .PARAMETER StatePath
            Path to the local state file.
            Defaults to %ProgramData%\ArcRemediator\state.json.

        .PARAMETER LogDirectory
            Where the local log line is written.
            Defaults to %ProgramData%\ArcRemediator\logs.

        .PARAMETER AlsoClearExpiredAttempt
            Also clear the 7-day Expired-rejoin cooldown marker. Only
            use this after confirming the previous failure was a true
            transient (an ARM throttle storm, an auth blip) and not a
            real Expired rejoin that crashed mid-flight.

        .OUTPUTS
            A PSCustomObject with:
              Reset           bool    True if anything changed.
              ResetByUser     string  The local: prefixed identity.
              StatePath       string  Where the state file lives.
              BeforeState     object  Snapshot of the relevant fields pre-reset.
              AfterState      object  Same fields after the reset.
              ExpiredCleared  bool    True if -AlsoClearExpiredAttempt fired.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()] [string]$StatePath = (Join-Path $env:ProgramData 'ArcRemediator\state.json'),
        [Parameter()] [string]$LogDirectory = (Join-Path $env:ProgramData 'ArcRemediator\logs'),
        [Parameter()] [switch]$AlsoClearExpiredAttempt
    )

    $caller = 'local:unknown'
    try {
        $name = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($name) { $caller = "local:$name" }
    } catch {
        $null = $_
    }

    $target = if ($AlsoClearExpiredAttempt) {
        'circuit breaker AND 7-day Expired cooldown marker'
    } else {
        'circuit breaker only (cooldown marker preserved)'
    }
    if (-not $PSCmdlet.ShouldProcess($target, "Reset by $caller")) {
        return [PSCustomObject]@{
            Reset = $false
            ResetByUser = $caller
            StatePath = $StatePath
            BeforeState = $null
            AfterState = $null
            ExpiredCleared = $false
        }
    }

    $state = Get-RemediatorState -Path $StatePath
    $before = [PSCustomObject]@{
        BreakerTripped = [bool]$state.BreakerTripped
        ConsecutiveFailures = [int]$state.ConsecutiveFailures
        BreakerLastResetUtc = $state.BreakerLastResetUtc
        LastExpiredAttemptId = $state.LastExpiredAttemptId
        LastExpiredAttemptStartedUtc = $state.LastExpiredAttemptStartedUtc
        LastExpiredAttemptOutcome = $state.LastExpiredAttemptOutcome
    }

    $nowUtc = (Get-Date).ToUniversalTime().ToString('o')
    $state.BreakerTripped = $false
    $state.ConsecutiveFailures = 0
    $state.BreakerLastResetUtc = $nowUtc
    $state.ResetByUser = $caller

    $expiredCleared = $false
    if ($AlsoClearExpiredAttempt) {
        $state.LastExpiredAttemptId = $null
        $state.LastExpiredAttemptResourceId = $null
        $state.LastExpiredAttemptStartedUtc = $null
        $state.LastExpiredAttemptCompletedUtc = $null
        $state.LastExpiredAttemptOutcome = $null
        $expiredCleared = $true
    }

    Set-RemediatorState -State $state -Path $StatePath -Confirm:$false

    try {
        $msg = "Reset-ArcRemediator: by $caller; before BreakerTripped=$($before.BreakerTripped) ConsecutiveFailures=$($before.ConsecutiveFailures) ExpiredOutcome=$($before.LastExpiredAttemptOutcome); ExpiredCleared=$expiredCleared"
        Write-LocalLog -Message $msg -Directory $LogDirectory -Level 'Info'
    } catch {
        $null = $_
    }

    Write-SecurityEventLog -EventId 1003 -Message "ArcRemediator: manual breaker reset by $caller on machine $env:COMPUTERNAME. PreviousBreakerTripped=$($before.BreakerTripped), ExpiredCleared=$expiredCleared." -EntryType 'Information'

    return [PSCustomObject]@{
        Reset = $true
        ResetByUser = $caller
        StatePath = $StatePath
        BeforeState = $before
        AfterState = $state
        ExpiredCleared = $expiredCleared
    }
}
