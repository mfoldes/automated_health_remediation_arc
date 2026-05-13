#Requires -Version 5.1

function Get-TimeSyncProbe {
    <#
        .SYNOPSIS
            Read the Windows w32tm status to surface clock drift relative
            to the configured time source.

        .DESCRIPTION
            Arc relies on the local clock being approximately accurate
            for token validation and TLS handshakes. 
            the time sync probe must report Unknown rather than swallow
            parse failures - a quietly-broken probe would let the
            orchestrator declare a clock-drifted machine 'healthy'.

            The probe shells out to 'w32tm /query /status' (the
            Microsoft-supported diagnostic), parses 'Phase Offset:'
            (which w32tm formats as a duration like '0.0012345s' or
            '-0.5s'), and reports the absolute offset in seconds.

            Failure modes:
              * w32tm not present, service stopped, or returns non-zero
                -> Status='Unknown', OffsetSeconds=$null.
              * Phase Offset line missing from output -> Status='Unknown'.
              * Phase Offset present but unparseable -> Status='Unknown',
                RawOutput preserved verbatim. The function never throws.

        .PARAMETER MaxOffsetSeconds
            Tolerance for clean. Default 60 s.

        .PARAMETER W32tmPath
            Override path. Default: w32tm.exe in System32.

        .OUTPUTS
            PSCustomObject with:
              OffsetSeconds (double|null)
              MaxOffsetSeconds (int)
              IsWithinTolerance (bool|null)
              Status ('OK'|'Drift'|'Unknown')
              RawOutput (string)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()] [int]$MaxOffsetSeconds = 60,
        [Parameter()] [string]$W32tmPath = "$env:WINDIR\System32\w32tm.exe"
    )

    $raw = ''
    $offset = $null
    $status = 'Unknown'
    $withinTolerance = $null

    if (-not (Test-Path -LiteralPath $W32tmPath)) {
        return [PSCustomObject]@{
            OffsetSeconds = $null
            MaxOffsetSeconds = $MaxOffsetSeconds
            IsWithinTolerance = $null
            Status = 'Unknown'
            RawOutput = ''
        }
    }

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        try {
            $proc = Start-Process -FilePath $W32tmPath `
                -ArgumentList @('/query', '/status') `
                -NoNewWindow -PassThru `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError $stderrFile

            if (-not $proc.WaitForExit(10000)) {
                try {
                    $proc.Kill()
                } catch {
                    $null = $_
                }
                $proc.WaitForExit()
            }
        } catch {
            # w32tm could not be invoked; treat as Unknown
            $null = $_
            return [PSCustomObject]@{
                OffsetSeconds = $null
                MaxOffsetSeconds = $MaxOffsetSeconds
                IsWithinTolerance = $null
                Status = 'Unknown'
                RawOutput = ''
            }
        }

        if (Test-Path -LiteralPath $stdoutFile) {
            $val = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
            if ($val) { $raw = $val }
        }
    } finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }

    # Parse 'Phase Offset: 0.1234567s' or 'Phase Offset: -1.5s' (en-US).
    $m = [regex]::Match($raw, 'Phase Offset:\s*(-?\d+(?:\.\d+)?)s', 'IgnoreCase')
    if ($m.Success) {
        $val = 0.0
        if ([double]::TryParse($m.Groups[1].Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
            $offset = [Math]::Abs($val)
            $withinTolerance = ($offset -le $MaxOffsetSeconds)
            $status = if ($withinTolerance) { 'OK' } else { 'Drift' }
        }
    }

    return [PSCustomObject]@{
        OffsetSeconds = $offset
        MaxOffsetSeconds = $MaxOffsetSeconds
        IsWithinTolerance = $withinTolerance
        Status = $status
        RawOutput = $raw
    }
}
