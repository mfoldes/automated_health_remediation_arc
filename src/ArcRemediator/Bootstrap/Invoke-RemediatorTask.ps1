#Requires -Version 5.1
<#
    .SYNOPSIS
        Scheduled-task entry wrapper. Imports the ArcRemediator module
        and translates the orchestrator's Outcome into a process exit
        code.

    .DESCRIPTION
        The scheduled task action invokes this script via powershell.exe
        -File. It is INTENTIONALLY thin: orchestration lives in the
        module so the install/uninstall path can ship a new module
        version without changing this file.

        The script:
          1. Imports the installed ArcRemediator module.
          2. Calls Invoke-ArcRemediation with the standard ProgramData
             paths.
          3. Sets $LASTEXITCODE to the result's ExitCode and exits.

        Any unhandled exception bubbles up; Invoke-ArcRemediation
        itself never throws (it catches and maps to Outcome='Error',
        exit 4), so reaching the outer catch here means the module
        could not be imported at all - which is also exit 4.
#>
[CmdletBinding()]
param(
    [Parameter()] [string]$ModulePath = (Join-Path $env:ProgramFiles 'ArcRemediator\ArcRemediator.psd1')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

try {
    Import-Module $ModulePath -Force -ErrorAction Stop
    $result = Invoke-ArcRemediation
    $exit = if ($result -and $result.PSObject.Properties.Name -contains 'ExitCode') { [int]$result.ExitCode } else { 4 }
    exit $exit
} catch {
    # Fail closed: module load or top-level invocation failure -> exit 4.
    [Console]::Error.WriteLine("Invoke-RemediatorTask: $($_.Exception.Message)")
    exit 4
}
