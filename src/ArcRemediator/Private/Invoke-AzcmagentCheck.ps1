#Requires -Version 5.1

function Invoke-AzcmagentCheck {
    <#
        .SYNOPSIS
            Run 'azcmagent check' as the Arc network probe and parse its
            output into a structured shape for telemetry.

        .DESCRIPTION
             the remediator uses the official azcmagent
            check command as its network-readiness probe; it does NOT
            perform manual HEAD probes against Arc endpoints, because:
              (a) the Microsoft-supported reachability rules change with
                  agent versions and clouds, and
              (b) manual probes can produce false positives/negatives that
                  diverge from what the agent itself sees.

            The parser is intentionally tolerant. azcmagent's table output
            is not a documented stable contract - column widths, the
            exact reachability markers (OK / Reachable / check-mark glyph),
            and the wording for proxy/private-link/gateway lines have all
            varied across releases. So:

              * rawOutput is ALWAYS preserved verbatim;
              * url + reachable/unreachable status is parsed with a permissive
                regex over the entire stdout, not by column position;
              * usesProxy, usesPrivateLink, usesGateway, sawAny429 are
                inferred from substring patterns and are nullable when no
                evidence is present in either direction;
              * a parse failure leaves the structured fields null but the
                function never throws. The run does not fail on parse
                failure (the requirement).

            The 429 signal is advisory only. It cannot override the ARM
            state classifier; the orchestrator may surface it in
            OutcomeDetail (per Task 11.5, which is deferred for MVP).

        .PARAMETER CloudProfile
            From Get-CloudProfile. Used to pass --cloud to azcmagent check.

        .PARAMETER Location
            Optional Azure region. When supplied, --location is forwarded.

        .PARAMETER Extensions
            Optional extension selector. 'sql' or 'all' on supported agent
            versions; if the agent is too old to accept --extensions, the
            failure surfaces via ExitCode / Stderr and the structured
            fields are left null.

        .PARAMETER TimeoutSec
            Process timeout. Default 90 seconds.

        .PARAMETER AzcmagentPath
            Override path to azcmagent.exe. Defaults to standard install
            location via Invoke-Azcmagent.

        .OUTPUTS
            PSCustomObject with:
              rawOutput (string)
              exitCode (int)
              connectionType (string|null)
              reachableUrls (string[])
              unreachableUrls (string[])
              usesProxy (bool|null)
              usesPrivateLink (bool|null)
              usesGateway (bool|null)
              sawAny429 (bool|null)
              parseFailed (bool)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSObject]$CloudProfile,
        [Parameter()] [string]$Location,
        [Parameter()] [ValidateSet('sql', 'all')] [string]$Extensions,
        [Parameter()] [int]$TimeoutSec = 90,
        [Parameter()] [string]$AzcmagentPath
    )

    $argv = [System.Collections.Generic.List[string]]::new()
    $argv.Add('check')
    if ($CloudProfile.PSObject.Properties.Name -contains 'AzcmagentCloud' -and $CloudProfile.AzcmagentCloud) {
        $argv.Add('--cloud'); $argv.Add([string]$CloudProfile.AzcmagentCloud)
    }
    if ($Location) {
        $argv.Add('--location'); $argv.Add($Location)
    }
    if ($Extensions) {
        $argv.Add('--extensions'); $argv.Add($Extensions)
    }

    $invokeArgs = @{
        Arguments = $argv.ToArray()
        TimeoutSec = $TimeoutSec
    }
    if ($AzcmagentPath) { $invokeArgs.AzcmagentPath = $AzcmagentPath }

    $proc = Invoke-Azcmagent @invokeArgs

    $stdoutText = if ($proc.Stdout) { [string]$proc.Stdout } else { '' }
    $stderrText = if ($proc.Stderr) { [string]$proc.Stderr } else { '' }
    if ($stdoutText -and $stderrText) {
        $combined = $stdoutText + "`n" + $stderrText
    } else {
        $combined = $stdoutText + $stderrText
    }

    $reachable = New-Object System.Collections.Generic.List[string]
    $unreachable = New-Object System.Collections.Generic.List[string]
    $connectionType = $null
    $usesProxy = $null
    $usesPrivateLink = $null
    $usesGateway = $null
    $sawAny429 = $null
    $parseFailed = $false

    if ([string]::IsNullOrWhiteSpace($combined)) {
        $parseFailed = $true
    } else {
        try {
            # Reachability: walk each line, find a URL and a positive/negative marker.
            # Tolerant of OK / Reachable / Pass and FAIL / Unreachable / Fail / Error / 4xx / 5xx markers,
            # case-insensitive. Lines without a recognizable marker are skipped (counted as parse-only).
            foreach ($line in ($combined -split "`r?`n")) {
                $u = [regex]::Match($line, 'https?://[^\s"''<>]+')
                if (-not $u.Success) { continue }
                $url = $u.Value.TrimEnd('.,;:)]')
                if ($line -imatch '\bunreach|\bfail|\berror|\bdenied|\btimeout|\b4\d\d\b|\b5\d\d\b|\bblocked\b') {
                    if (-not $unreachable.Contains($url)) { $unreachable.Add($url) }
                } elseif ($line -imatch '\breachable\b|\bpass\b|\bok\b|\bsuccess\b') {
                    if (-not $reachable.Contains($url)) { $reachable.Add($url) }
                }
            }

            # Capability signals
            if ($combined -imatch '\bproxy\b\s*[:=]\s*(https?://\S+)') {
                $usesProxy = $true
            } elseif ($combined -imatch '\bproxy\b.*\b(none|not configured|disabled)\b') {
                $usesProxy = $false
            }

            if ($combined -imatch 'private[\s-]?link\s+scope|privatelinkscope') {
                $usesPrivateLink = $true
            } elseif ($combined -imatch 'private[\s-]?link.*\b(not configured|none|disabled)\b') {
                $usesPrivateLink = $false
            }

            if ($combined -imatch '\barc[\s-]?gateway\b') {
                $usesGateway = $true
            }

            if ($combined -imatch '\b429\b') {
                $sawAny429 = $true
            }

            if ($usesPrivateLink) {
                $connectionType = 'private-link'
            } elseif ($usesGateway) {
                $connectionType = 'gateway'
            } elseif ($usesProxy) {
                $connectionType = 'proxy'
            } elseif ($reachable.Count -gt 0 -or $unreachable.Count -gt 0) {
                $connectionType = 'public'
            }
        } catch {
            $parseFailed = $true
            $null = $_
        }
    }

    return [PSCustomObject]@{
        rawOutput = $combined
        exitCode = $proc.ExitCode
        connectionType = $connectionType
        reachableUrls = @($reachable.ToArray())
        unreachableUrls = @($unreachable.ToArray())
        usesProxy = $usesProxy
        usesPrivateLink = $usesPrivateLink
        usesGateway = $usesGateway
        sawAny429 = $sawAny429
        parseFailed = $parseFailed
    }
}
