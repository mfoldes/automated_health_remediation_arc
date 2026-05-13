#Requires -Version 5.1

function Wait-ArmAsyncOperation {
    <#
        .SYNOPSIS
            Poll an Azure-AsyncOperation / Location URL until the
            long-running ARM operation reaches a terminal status, or
            until the overall timeout fires.

        .DESCRIPTION
             an ARM DELETE
            on Microsoft.HybridCompute/machines may return:

              * 204 No Content - terminal success, no polling needed.
              * 202 Accepted - async; the response carries either
                                   Azure-AsyncOperation or Location, and
                                   we MUST poll until Succeeded/Failed.

            Polling rules:
              * Honor the Retry-After header when present (seconds).
              * When absent, use bounded exponential backoff starting at
                5 seconds, doubling, capped at -MaxBackoffSec (default 60).
              * The overall budget is configurable (default 30 minutes /
                1800 s). On timeout: TimedOut=$true, Success=$false.

            Recognized terminal statuses on the operation body:
              * 'Succeeded' -> Success=$true
              * 'Failed' / 'Canceled' -> Success=$false with the body's
                error.message (if available) on ErrorMessage.

            Transient HTTP errors during polling (5xx, network) do not
            abort the wait; we keep polling on the same backoff schedule
            until either the operation reports terminal status or the
            timeout fires. 4xx errors on the operation URL itself are
            considered terminal failures (a missing or revoked AAO URL
            means we cannot make progress).

        .PARAMETER OperationUrl
            Azure-AsyncOperation or Location URL.

        .PARAMETER AccessToken
            ARM bearer token. Sent as Authorization header.

        .PARAMETER TimeoutSec
            Overall budget. Default 1800 (30 min). Configurable per
            the design.

        .PARAMETER MaxBackoffSec
            Cap for the backoff schedule when no Retry-After is present.
            Default 60 s.

        .PARAMETER InitialBackoffSec
            First wait when no Retry-After is present. Default 5 s.

        .OUTPUTS
            PSCustomObject with:
              Success (bool)
              FinalStatus (string|null)
              TimedOut (bool)
              ElapsedSeconds (int)
              PollCount (int)
              ErrorMessage (string|null)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$OperationUrl,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter()] [int]$TimeoutSec = 1800,
        [Parameter()] [int]$MaxBackoffSec = 60,
        [Parameter()] [int]$InitialBackoffSec = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $headers = @{ Authorization = "Bearer $AccessToken" }
    $backoff = $InitialBackoffSec
    $pollCount = 0
    $start = Get-Date

    while ($true) {
        if ((Get-Date) -ge $deadline) {
            return [PSCustomObject]@{
                Success = $false
                FinalStatus = $null
                TimedOut = $true
                ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
                PollCount = $pollCount
                ErrorMessage = "Async operation did not reach a terminal status within $TimeoutSec seconds."
            }
        }

        $pollCount++
        $resp = $null
        try {
            $resp = Invoke-WebRequestWithTls -Uri $OperationUrl -Method 'GET' -Headers $headers -TimeoutSec 30
        } catch {
            $statusCode = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $r = $_.Exception.Response
                if ($r.PSObject.Properties.Name -contains 'StatusCode' -and $r.StatusCode) {
                    $statusCode = [int]$r.StatusCode
                }
            }
            # Treat 4xx as terminal - a missing or revoked operation URL means
            # we cannot make progress. Treat network errors and 5xx as transient
            # and keep polling.
            if ($null -ne $statusCode -and $statusCode -ge 400 -and $statusCode -lt 500) {
                return [PSCustomObject]@{
                    Success = $false
                    FinalStatus = $null
                    TimedOut = $false
                    ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
                    PollCount = $pollCount
                    ErrorMessage = "Async operation poll returned HTTP $statusCode against $OperationUrl."
                }
            }
            # Transient: sleep and retry below.
            $resp = $null
        }

        if ($resp) {
            $retryAfter = Get-RetryAfterSeconds -Response $resp
            $obj = $null
            try { $obj = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch { $null = $_ }

            $statusVal = $null
            if ($obj -and ($obj.PSObject.Properties.Name -contains 'status')) {
                $statusVal = [string]$obj.status
            }

            if ($statusVal -ieq 'Succeeded') {
                return [PSCustomObject]@{
                    Success = $true
                    FinalStatus = 'Succeeded'
                    TimedOut = $false
                    ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
                    PollCount = $pollCount
                    ErrorMessage = $null
                }
            }
            if ($statusVal -ieq 'Failed' -or $statusVal -ieq 'Canceled') {
                $errMsg = "Async operation reported ${statusVal}."
                if ($obj -and ($obj.PSObject.Properties.Name -contains 'error') -and $obj.error) {
                    if ($obj.error.PSObject.Properties.Name -contains 'message') {
                        $errMsg = "Async operation ${statusVal}: $($obj.error.message)"
                    }
                }
                return [PSCustomObject]@{
                    Success = $false
                    FinalStatus = $statusVal
                    TimedOut = $false
                    ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
                    PollCount = $pollCount
                    ErrorMessage = $errMsg
                }
            }

            # Honor Retry-After when present, else exponential backoff capped.
            if ($retryAfter) {
                $sleep = [Math]::Min($retryAfter, $MaxBackoffSec)
                $backoff = $InitialBackoffSec
            } else {
                $sleep = $backoff
                $backoff = [Math]::Min($backoff * 2, $MaxBackoffSec)
            }
        } else {
            # Transient failure path: simple backoff.
            $sleep = $backoff
            $backoff = [Math]::Min($backoff * 2, $MaxBackoffSec)
        }

        $remaining = [int](($deadline - (Get-Date)).TotalSeconds)
        if ($remaining -le 0) { continue } # top of loop will return TimedOut
        $sleep = [Math]::Min($sleep, $remaining)
        Start-Sleep -Seconds $sleep
    }
}

function Get-RetryAfterSeconds {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Seconds is the unit of the Retry-After header per RFC 7231; "Get-RetryAfterSecond" would misrepresent the return value type as a single tick, not a count.')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [PSObject]$Response)

    if (-not ($Response.PSObject.Properties.Name -contains 'Headers')) { return 0 }
    $hdrs = $Response.Headers
    if (-not $hdrs) { return 0 }

    $value = $null
    if ($hdrs -is [System.Collections.IDictionary]) {
        if ($hdrs.Contains('Retry-After')) { $value = $hdrs['Retry-After'] }
    } else {
        $p = $hdrs.PSObject.Properties | Where-Object { $_.Name -ieq 'Retry-After' } | Select-Object -First 1
        if ($p) { $value = $p.Value }
    }
    if ($null -eq $value) { return 0 }
    $first = ($value | Select-Object -First 1)
    $seconds = 0
    if ([int]::TryParse([string]$first, [ref]$seconds)) { return $seconds }
    return 0
}
