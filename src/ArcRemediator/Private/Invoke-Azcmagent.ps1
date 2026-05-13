#Requires -Version 5.1

function Invoke-Azcmagent {
    <#
        .SYNOPSIS
            Run azcmagent.exe with timeout, stdout/stderr capture, and
            secret-safe error handling.

        .DESCRIPTION
             the remediator must wrap azcmagent.exe so that:
              * stdout and stderr are captured in full;
              * a configurable timeout terminates only the child process it
                started, never the parent shell or unrelated siblings;
              * thrown exceptions do not include the argv list, because in
                lab/canary flows an operator may pass --service-principal-secret
                on the command line. Even when the production cert-thumbprint
                path is used, defense-in-depth keeps argv out of any error
                message that might reach a local log or a LAW row.

            The function never inspects argv content for secrets; it simply
            never echoes argv back. Callers are responsible for keeping the
            shape of their argv consistent with the secret-hygiene rules in
            the design and section 9.

            Implementation note: PowerShell 5.1 runs on .NET Framework, which
            does not expose Process.Kill(true) for tree termination. Per the
            acceptance criteria, the timeout MUST kill only the started child
            process and not other siblings - the single-process Kill() is
            the correct primitive here, not a tree kill.

        .PARAMETER Arguments
            azcmagent argv as a string array. Each element is passed to
            Start-Process -ArgumentList unchanged. Callers needing args with
            spaces must pre-quote them; azcmagent's standard argv (verbs,
            flags, GUIDs, resource names) does not require quoting.

        .PARAMETER TimeoutSec
            Wall-clock timeout. Default 60 s. On timeout the process is
            killed and TimedOut=$true is returned. ExitCode in the timeout
            case is whatever the kill produced (often -1) and should not
            be relied on.

        .PARAMETER AzcmagentPath
            Override path to azcmagent.exe. When omitted, looks at
            %ProgramFiles%\AzureConnectedMachineAgent\azcmagent.exe and
            falls back to Get-Command 'azcmagent.exe'. Also exposed for
            tests so the wrapper can be exercised against cmd.exe etc.

        .OUTPUTS
            PSCustomObject with:
              ExitCode (int)
              Stdout (string)
              Stderr (string)
              TimedOut (bool)
              Duration (timespan)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),

        [Parameter()]
        [int]$TimeoutSec = 60,

        [Parameter()]
        [string]$AzcmagentPath
    )

    if (-not $AzcmagentPath) {
        $candidate = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
        if (Test-Path -LiteralPath $candidate) {
            $AzcmagentPath = $candidate
        } else {
            $cmd = Get-Command -Name 'azcmagent.exe' -ErrorAction SilentlyContinue
            if ($cmd) { $AzcmagentPath = $cmd.Source }
        }
    }
    if (-not $AzcmagentPath -or -not (Test-Path -LiteralPath $AzcmagentPath)) {
        throw 'Invoke-Azcmagent: azcmagent.exe not found. Install the Azure Connected Machine Agent or pass -AzcmagentPath.'
    }

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = -1
    $proc = $null

    try {
        $startArgs = @{
            FilePath = $AzcmagentPath
            NoNewWindow = $true
            PassThru = $true
            RedirectStandardOutput = $stdoutFile
            RedirectStandardError = $stderrFile
        }
        if (@($Arguments).Count -gt 0) {
            $startArgs.ArgumentList = $Arguments
        }

        try {
            $proc = Start-Process @startArgs
        } catch {
            # Secret hygiene: never echo argv. Surface only the underlying
            # transport / start error message (e.g. file-not-found, access denied).
            throw "Invoke-Azcmagent: process start failed: $($_.Exception.Message)"
        }

        $timeoutMs = [int]([Math]::Min([int]::MaxValue, $TimeoutSec * 1000))
        if (-not $proc.WaitForExit($timeoutMs)) {
            try {
                $proc.Kill()
            } catch {
                # Process may have exited between the WaitForExit timeout and
                # the Kill() call. That race is harmless; TimedOut is still
                # correct because the wall-clock budget was exceeded.
                $null = $_
            }
            $proc.WaitForExit()
            $timedOut = $true
        }
        $exitCode = $proc.ExitCode
    } finally {
        $sw.Stop()
        if ($proc) {
            try {
                $proc.Dispose()
            } catch {
                # Dispose can throw if the handle is already released; never
                # let cleanup mask the wrapper's real return value.
                $null = $_
            }
        }
    }

    $stdout = ''
    $stderr = ''
    if (Test-Path -LiteralPath $stdoutFile) {
        $raw = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        if ($null -ne $raw) { $stdout = $raw }
    }
    if (Test-Path -LiteralPath $stderrFile) {
        $raw = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        if ($null -ne $raw) { $stderr = $raw }
    }
    Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
        TimedOut = $timedOut
        Duration = $sw.Elapsed
    }
}
