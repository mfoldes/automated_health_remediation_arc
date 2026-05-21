#Requires -Version 5.1

function Write-SecurityEventLog {
    <#
        .SYNOPSIS
            Write a security-significant event to the Windows Application
            Event Log under the ArcRemediator source.

        .DESCRIPTION
            Wraps Write-EventLog so critical operational events (breaker trips,
            resets, Expired rejoin attempts, tamper detection, kill-switch
            activations) are surfaced in the Windows Event Log and can be
            forwarded via Windows Event Forwarding (WEF) to a central SIEM.

            Fails silently when the event source is not registered — this is
            the normal state in developer / CI environments where
            Install.ps1 has not been run with the registration step. Do NOT
            change this to a thrown error; the caller must never be blocked
            by event-log unavailability.

            Event IDs:
              1001  BreakerTripped        — circuit breaker entered tripped state
              1002  BreakerReset          — auto fleet-wide reset via breaker-reset blob
              1003  ManualBreakerReset    — operator ran Reset-ArcRemediator
              1004  ExpiredRejoinAttempt  — entering destructive Expired rejoin path
              1005  ExpiredRejoinOutcome  — outcome of Expired rejoin (success or failure)
              1006  TamperDetection       — state.json HMAC mismatch detected
              1007  KillSwitchTriggered   — kill-switch blob paused the run

        .PARAMETER EventId
            One of the documented event IDs (1001–1007).

        .PARAMETER Message
            Human-readable event detail. Never include secrets.

        .PARAMETER EntryType
            'Information', 'Warning', or 'Error'. Defaults to 'Information'.

        .PARAMETER LogName
            Event log to write to. Defaults to 'Application'.

        .PARAMETER Source
            Event source name. Defaults to 'ArcRemediator'.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'This function uses Write-EventLog, not Write-Host.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1001, 1007)]
        [int]$EventId,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType = 'Information',

        [Parameter()]
        [string]$LogName = 'Application',

        [Parameter()]
        [string]$Source = 'ArcRemediator'
    )

    try {
        Write-EventLog -LogName $LogName -Source $Source -EventId $EventId `
            -EntryType $EntryType -Message $Message -ErrorAction Stop
    } catch {
        # Source not registered or log unavailable (dev/CI environment).
        # Silently suppress — event log is a secondary channel; the primary
        # audit trail is the local log + LAW telemetry.
        $null = $_
    }
}
