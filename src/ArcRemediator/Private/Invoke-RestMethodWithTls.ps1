#Requires -Version 5.1

function Invoke-RestMethodWithTls {
    <#
        .SYNOPSIS
            Invoke-RestMethod wrapper that ensures TLS 1.2+ for this single call.

        .DESCRIPTION
            Ensures [Net.ServicePointManager]::SecurityProtocol includes Tls12
            (and Tls13 when the enum value exists on the host) immediately before
            forwarding to Invoke-RestMethod. Idempotent. Never downgrades higher
            protocols that are already enabled.

            This wrapper exists so the remediator can enforce its own TLS floor
            without mutating SecurityProtocol globally at module load time.
            Module load must not touch SecurityProtocol; only requests issued
            through this wrapper raise the floor for the host process.

        .NOTES
            Do NOT collapse this function into Invoke-WebRequestWithTls.
            The two wrappers have different return types:
              - Invoke-RestMethodWithTls  -> deserialized object (auto-parsed JSON/XML).
                Use for ARM / Monitor calls where only the response body is needed.
              - Invoke-WebRequestWithTls  -> WebResponseObject with raw headers
                (ETag, Azure-AsyncOperation, Retry-After, Location, Status).
                Use when response headers drive the next action (async polling,
                conditional PUT, kill-switch HTTP status code).
            Collapsing them would require callers to pattern-match the return type
            or always pay the overhead of a full WebResponseObject, breaking the
            clean separation between "give me the data" and "give me the envelope".

        .PARAMETER Uri
            Target URI. Required.

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

        .PARAMETER WebSession
            Optional Web session for cookies/auth reuse.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Tls is an acronym, not a plural noun. False positive in PSScriptAnalyzer.')]
    [CmdletBinding()]
    [OutputType([object])]
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
        [int]$TimeoutSec,

        [Parameter()]
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
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

    $forward = @{ Uri = $Uri; Method = $Method }
    if ($PSBoundParameters.ContainsKey('Headers')) { $forward.Headers = $Headers }
    if ($PSBoundParameters.ContainsKey('Body')) { $forward.Body = $Body }
    if ($PSBoundParameters.ContainsKey('ContentType')) { $forward.ContentType = $ContentType }
    if ($PSBoundParameters.ContainsKey('TimeoutSec')) { $forward.TimeoutSec = $TimeoutSec }
    if ($PSBoundParameters.ContainsKey('WebSession')) { $forward.WebSession = $WebSession }

    return Invoke-RestMethod @forward
}
