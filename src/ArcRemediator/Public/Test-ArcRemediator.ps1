#Requires -Version 5.1

function Test-ArcRemediator {
    <#
        .SYNOPSIS
            Run the remediator's full decision tree against the installed
            config without changing anything.

        .DESCRIPTION
            Use this from an interactive PowerShell session when you want
            to confirm a host is configured correctly before promoting it
            from Observe to Enforce. It calls Invoke-ArcRemediation with
            the mode pinned to 'Observe', which means:

              * No Arc Windows services are restarted.
              * No ARM tags are written.
              * No azcmagent disconnect / connect is run.
              * No ARM DELETE happens.

            The local state file may pick up an updated last-run timestamp
            on success, but nothing cloud-side is changed. The function
            returns the same result object the scheduled task would have
            returned - look at Outcome and OutcomeDetail to see what the
            real run would have done.

        .PARAMETER ConfigPath
            Path to the DPAPI-wrapped config file.
            Defaults to %ProgramData%\ArcRemediator\config.json.

        .PARAMETER StatePath
            Path to the local state file.
            Defaults to %ProgramData%\ArcRemediator\state.json.

        .PARAMETER LogDirectory
            Where the local log file is written.
            Defaults to %ProgramData%\ArcRemediator\logs.

        .PARAMETER AzcmagentPath
            Override path to azcmagent.exe. Used by tests; production
            picks the default install path automatically.

        .OUTPUTS
            The PSCustomObject returned by Invoke-ArcRemediation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()] [string]$ConfigPath = (Join-Path $env:ProgramData 'ArcRemediator\config.json'),
        [Parameter()] [string]$StatePath = (Join-Path $env:ProgramData 'ArcRemediator\state.json'),
        [Parameter()] [string]$LogDirectory = (Join-Path $env:ProgramData 'ArcRemediator\logs'),
        [Parameter()] [string]$AzcmagentPath
    )

    $forward = @{
        ConfigPath = $ConfigPath
        StatePath = $StatePath
        LogDirectory = $LogDirectory
        OverrideMode = 'Observe'
    }
    if ($AzcmagentPath) { $forward.AzcmagentPath = $AzcmagentPath }

    return Invoke-ArcRemediation @forward
}
