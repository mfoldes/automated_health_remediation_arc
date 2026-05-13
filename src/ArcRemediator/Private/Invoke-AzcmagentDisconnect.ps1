#Requires -Version 5.1

function Invoke-AzcmagentDisconnect {
    <#
        .SYNOPSIS
            Run 'azcmagent disconnect --force-local-only' to clear local
            agent state after the cloud resource has been removed.

        .DESCRIPTION
             the remediator
            MUST NOT run 'azcmagent disconnect' without
            '--force-local-only' in MVP. The plain disconnect call
            attempts to delete the ARM resource as well, which for the
            destructive flow is wrong on two counts:

              1. The ARM resource has already been deleted via the
                 supported REST path (Remove-ArcResource) and the
                 GET 404 verification has already passed.
              2. A disconnect-without-force-local-only that races the
                 already-completed ARM DELETE can produce
                 'resource not found' errors that look like agent
                 failures, masking the real state.

            This wrapper hard-codes '--force-local-only' so callers
            cannot bypass that rule by accident.

        .PARAMETER TimeoutSec
            Default 120 s. azcmagent disconnect can take ~30-60 s on
            healthy systems; we double that for safety.

        .PARAMETER AzcmagentPath
            Override path for tests.

        .OUTPUTS
            The PSCustomObject returned by Invoke-Azcmagent.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()] [int]$TimeoutSec = 120,
        [Parameter()] [string]$AzcmagentPath
    )

    $invokeArgs = @{
        Arguments = @('disconnect', '--force-local-only')
        TimeoutSec = $TimeoutSec
    }
    if ($AzcmagentPath) { $invokeArgs.AzcmagentPath = $AzcmagentPath }

    return Invoke-Azcmagent @invokeArgs
}
