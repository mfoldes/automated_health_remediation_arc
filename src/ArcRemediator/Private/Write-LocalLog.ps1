#Requires -Version 5.1

function Write-LocalLog {
    <#
        .SYNOPSIS
            Append a structured line to the daily ArcRemediator local log.

        .DESCRIPTION
            Writes one ISO-8601-timestamped line to
            <Directory>/arc-remediator-YYYYMMDD.log. Creates the directory if
            absent. Rotates the current day's file when it exceeds MaxFileBytes
            (default 10 MB) by renaming it with an HHmmss suffix. Removes log
            files older than RetentionDays (default 14) on a best-effort basis;
            retention failures never propagate.

            -Directory defaults to %ProgramData%\ArcRemediator\logs so the
            top-level failure handler in Invoke-ArcRemediation can call this
            with no arguments before config has been loaded.

        .PARAMETER Message
            Message body. Required.

        .PARAMETER Level
            One of Info, Warn, Error, Debug. Defaults to Info.

        .PARAMETER Directory
            Log directory. Defaults to %ProgramData%\ArcRemediator\logs.

        .PARAMETER RetentionDays
            Days to keep arc-remediator-*.log files. Defaults to 14.

        .PARAMETER MaxFileBytes
            Per-file byte cap before rotation. Defaults to 10 MB.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'This function writes to a log file, not the host.')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warn', 'Error', 'Debug')]
        [string]$Level = 'Info',

        [Parameter()]
        [string]$Directory = (Join-Path $env:ProgramData 'ArcRemediator\logs'),

        [Parameter()]
        [int]$RetentionDays = 14,

        [Parameter()]
        [long]$MaxFileBytes = 10MB
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    }

    $today = (Get-Date).ToString('yyyyMMdd')
    $file = Join-Path $Directory ('arc-remediator-{0}.log' -f $today)

    if ((Test-Path -LiteralPath $file) -and
        ((Get-Item -LiteralPath $file).Length -gt $MaxFileBytes)) {
        $stamp = (Get-Date).ToString('HHmmss')
        $rotated = Join-Path $Directory ('arc-remediator-{0}-{1}.log' -f $today, $stamp)
        Move-Item -LiteralPath $file -Destination $rotated -Force
    }

    $line = '{0} [{1}] {2}' -f (Get-Date).ToUniversalTime().ToString('o'), $Level, $Message
    Add-Content -LiteralPath $file -Value $line -Encoding UTF8

    # Retention sweep is best-effort. Both cmdlets use SilentlyContinue so an
    # I/O error on one stale file doesn't break the rest of the sweep, and a
    # failure here never propagates above the function.
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $Directory -Filter 'arc-remediator-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
}
