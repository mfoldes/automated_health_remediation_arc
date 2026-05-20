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

    # Use System.Diagnostics.Process directly (not Start-Process cmdlet).
    # On Windows PowerShell 5.1 Desktop, Start-Process -PassThru combined with
    # -RedirectStandardOutput/-RedirectStandardError returns a process handle
    # where ExitCode is always $null, even after WaitForExit().  Using the .NET
    # class directly bypasses that PS 5.1 bug and works identically on PS 7.
    #
    # Async stream reads (ReadToEndAsync) avoid the stdout/stderr deadlock that
    # synchronous ReadToEnd() causes when both buffers fill simultaneously.
    $psi = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $AzcmagentPath
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    if (@($Arguments).Count -gt 0) {
        # Build the command-line string.  Quote tokens that contain whitespace;
        # azcmagent's standard argv (verbs, flags, GUIDs, resource names) never
        # requires quoting under normal use.
        $psi.Arguments = ($Arguments | ForEach-Object {
            if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' }
            else                 { $_ }
        }) -join ' '
    }

    $sw       = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = -1
    $stdout   = ''
    $stderr   = ''

    $proc = $null
    try {
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
        } catch {
            # Secret hygiene: never echo argv.
            throw "Invoke-Azcmagent: process start failed: $($_.Exception.Message)"
        }
        if ($null -eq $proc) {
            throw 'Invoke-Azcmagent: Process.Start() returned null (process reuse not supported).'
        }

        # Start async reads before WaitForExit so output buffers never fill and
        # block the child process.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $timeoutMs = [int]([Math]::Min([int]::MaxValue, $TimeoutSec * 1000))
        if (-not $proc.WaitForExit($timeoutMs)) {
            try { $proc.Kill() } catch { $null = $_ }
            $timedOut = $true
        }

        # No-arg WaitForExit flushes event-based async handlers and ensures the
        # redirected streams reach EOF before we read ExitCode.
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode

        # Give the async tasks up to 5 s to drain any remaining buffered data.
        # After WaitForExit() the streams are at EOF; tasks should complete
        # almost immediately.  Explicit Wait() before reading .Result avoids the
        # race where IsCompleted is still false at the moment we check.
        try { [void]$stdoutTask.Wait(5000) } catch { $null = $_ }
        try { [void]$stderrTask.Wait(5000) } catch { $null = $_ }

        $stdout = try { $stdoutTask.Result } catch { '' }
        $stderr = try { $stderrTask.Result } catch { '' }
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }
    } finally {
        $sw.Stop()
        if ($null -ne $proc) { try { $proc.Dispose() } catch { $null = $_ } }
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Stdout   = $stdout
        Stderr   = $stderr
        TimedOut = $timedOut
        Duration = $sw.Elapsed
    }
}
