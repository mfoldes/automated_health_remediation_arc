#Requires -Version 5.1
<#
    .SYNOPSIS
        Uninstall the ArcRemediator scheduled task and module from a host.

    .DESCRIPTION
        Run this from an elevated PowerShell session on a host where
        Install.ps1 was previously used. It does two things by default
        and one extra thing on request:

          1. Unregisters the scheduled task named 'ArcRemediator' if
             it exists.
          2. Removes the install path (%ProgramFiles%\ArcRemediator by
             default), including the module files and the bootstrap
             entry script.
          3. With -RemoveData, also removes the data path
             (%ProgramData%\ArcRemediator), which contains the
             encrypted config, the local state, and the log files.

        The data path is preserved by default because the local state
        file holds the 7-day Expired-rejoin cooldown marker and the
        circuit-breaker counters. Removing that mid-incident would
        silently re-arm destructive remediation, so -RemoveData is an
        explicit opt-in for clean-slate teardowns where you've
        verified the host is not in an in-flight remediation cycle.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()] [string]$InstallPath = (Join-Path $env:ProgramFiles 'ArcRemediator'),
    [Parameter()] [string]$DataPath = (Join-Path $env:ProgramData 'ArcRemediator'),
    [Parameter()] [string]$TaskName = 'ArcRemediator',
    [Parameter()] [switch]$RemoveData,
    [Parameter()] [switch]$SkipTaskRemoval,
    [Parameter()] [switch]$SkipElevationCheck
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $SkipElevationCheck) {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Uninstall.ps1: must be run from an elevated session (administrator).'
    }
}

$taskRemoved = $false
$installRemoved = $false
$dataRemoved = $false

# ---- 1. Scheduled task --------------------------------------------------

if (-not $SkipTaskRemoval) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            $taskRemoved = $true
        }
    }
}

# ---- 2. InstallPath -----------------------------------------------------

if (Test-Path -LiteralPath $InstallPath) {
    if ($PSCmdlet.ShouldProcess($InstallPath, 'Remove install path')) {
        Remove-Item -LiteralPath $InstallPath -Recurse -Force
        $installRemoved = $true
    }
}

# ---- 3. DataPath (opt-in) ----------------------------------------------

if ($RemoveData -and (Test-Path -LiteralPath $DataPath)) {
    if ($PSCmdlet.ShouldProcess($DataPath, 'Remove data path INCLUDING cooldown marker + state + logs')) {
        Remove-Item -LiteralPath $DataPath -Recurse -Force
        $dataRemoved = $true
    }
}

return [PSCustomObject]@{
    InstallPath = $InstallPath
    DataPath = $DataPath
    TaskName = $TaskName
    TaskRemoved = $taskRemoved
    InstallRemoved = $installRemoved
    DataRemoved = $dataRemoved
}
