#Requires -Version 5.1

function Invoke-WebRequestWithTls {
    <#
        .SYNOPSIS
            Invoke-WebRequest wrapper that ensures TLS 1.2+ for this single call.

        .DESCRIPTION
            Mirrors Invoke-RestMethodWithTls but uses Invoke-WebRequest so the
            caller can inspect response headers (ETag, retry-after, etc.) and
            status codes. Ensures [Net.ServicePointManager]::SecurityProtocol
            includes Tls12 (and Tls13 when present) before forwarding the call.
            Idempotent. Never downgrades higher protocols.

        .PARAMETER Uri
            Target URI.

        .PARAMETER Method
            HTTP method. Defaults to GET.

        .PARAMETER Headers
            Optional request headers.

        .PARAMETER Body
            Optional request body.

        .PARAMETER ContentType
            Optional Content-Type header.

        .PARAMETER TimeoutSec
            Optional request timeout in seconds.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Tls is an acronym, not a plural noun.')]
    [CmdletBinding()]
    [OutputType([Microsoft.PowerShell.Commands.WebResponseObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Uri,

        [Parameter()]
        [string]$Method = 'GET',

        [Parameter()]
        [System.Collections.IDictionary]$Headers,

        [Parameter()]
        $Body,

        [Parameter()]
        [string]$ContentType,

        [Parameter()]
        [int]$TimeoutSec
    )

    $current = [Net.ServicePointManager]::SecurityProtocol
    $required = [Net.SecurityProtocolType]::Tls12

    $tls13Value = [enum]::GetValues([Net.SecurityProtocolType]) |
        Where-Object { $_.ToString() -eq 'Tls13' } |
        Select-Object -First 1

    if ($null -ne $tls13Value) {
        $required = $required -bor $tls13Value
    }

    $desired = $current -bor $required
    if ($desired -ne $current) {
        [Net.ServicePointManager]::SecurityProtocol = $desired
    }

    $forward = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true }
    if ($PSBoundParameters.ContainsKey('Headers')) { $forward.Headers = $Headers }
    if ($PSBoundParameters.ContainsKey('Body')) { $forward.Body = $Body }
    if ($PSBoundParameters.ContainsKey('ContentType')) { $forward.ContentType = $ContentType }
    if ($PSBoundParameters.ContainsKey('TimeoutSec')) { $forward.TimeoutSec = $TimeoutSec }

    return Invoke-WebRequest @forward
}
