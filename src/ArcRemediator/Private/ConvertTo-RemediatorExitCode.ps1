#Requires -Version 5.1

function ConvertTo-RemediatorExitCode {
    <#
        .SYNOPSIS
            Map a remediator Outcome string to the scheduled-task exit
            code documented below.

        .DESCRIPTION
            The scheduled-task action's exit code is what Task Scheduler
            surfaces to operators for local triage. The mapping in the design is intentionally narrow:

              0 Healthy, FleetPaused, MachinePaused, ObserveOnly,
                 CooldownSkipped, ServicesRepaired, ConnectivityBlocked,
                 NeedsHuman, BreakerTripped, ResourceNotFound,
                 LogIngestionFailure (when telemetry is the only failed
                 operation)
              1 ExpiredRejoinFailure
              2 AuthFailure, ArmForbidden, ConfigMismatch,
                 AzureMachineError
              3 ArmThrottled, ArmTransientFailure
              4 Error (unhandled)

            Unknown outcome strings map to 4 so an unexpected branch in
            the orchestrator never reports 'all clear'.

            -LogIngestionOnlyFailed is the secondary-status
            exception: if the primary remediation outcome succeeded but
            the LAW POST failed, the exit code follows the primary
            outcome (not the LogIngestionFailure surface).

        .PARAMETER Outcome
            One of the documented outcome strings.

        .PARAMETER LogIngestionOnlyFailed
            When $true, indicates LAW ingestion was the only failed
            operation; the function returns the exit code mapped to the
            primary Outcome rather than ever returning 1-4 for
            LogIngestionFailure.

        .OUTPUTS
            [int] in {0, 1, 2, 3, 4}.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string]$Outcome,
        [Parameter()] [switch]$LogIngestionOnlyFailed
    )

    # When LAW ingestion failure is the only secondary status, force the
    # exit code to the success bucket (the design final paragraph).
    if ($LogIngestionOnlyFailed -and $Outcome -ieq 'LogIngestionFailure') {
        return 0
    }

    switch -CaseSensitive ($Outcome) {
        'Healthy' { return 0 }
        'FleetPaused' { return 0 }
        'MachinePaused' { return 0 }
        'ObserveOnly' { return 0 }
        'CooldownSkipped' { return 0 }
        'ServicesRepaired' { return 0 }
        'ConnectivityBlocked' { return 0 }
        'NeedsHuman' { return 0 }
        'BreakerTripped' { return 0 }
        'ResourceNotFound' { return 0 }
        'LogIngestionFailure' { return 0 } # secondary-only path covered above; primary cases also map to 0
        'ExpiredRejoinSuccess'{ return 0 }
        'ExpiredRejoinFailure'{ return 1 }
        'AuthFailure' { return 2 }
        'ArmForbidden' { return 2 }
        'ConfigMismatch' { return 2 }
        'AzureMachineError' { return 2 }
        'ArmThrottled' { return 3 }
        'ArmTransientFailure' { return 3 }
        'Error' { return 4 }
        default { return 4 }
    }
}
