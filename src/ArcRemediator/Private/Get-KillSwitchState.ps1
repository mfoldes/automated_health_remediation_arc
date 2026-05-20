#Requires -Version 5.1

function Get-KillSwitchState {
    <#
        .SYNOPSIS
            Read the kill-switch SAS blob and classify whether the remediator
            may proceed for this run.

        .DESCRIPTION
             the kill switch is
            read BEFORE Azure auth. The blob body must be exactly the
            literal string 'enabled' (after trim) for the remediator to
            proceed. Anything else - different content, 403, 404, network
            timeout - pauses the run.

            The blob is fetched via Invoke-RestMethodWithTls so the same
            TLS 1.2+ floor applies as for ARM/Monitor calls. The SAS URL
            holds a credential in its query string (sig=, se=, sp=, etc.).
            Errors are scrubbed so the query string never reaches a log,
            exception, or returned object.

        .PARAMETER KillSwitchUrl
            The Service SAS URL of the kill-switch blob, including query
            parameters. Must be a full https:// URL.

        .PARAMETER TimeoutSec
            HTTP request timeout. Default 15 seconds.

        .OUTPUTS
            PSCustomObject with:
              CanProceed (bool) - $true only if body is exact 'enabled'
              Reason (string)- 'Enabled' | 'DisabledContent' | 'NotFound' | 'Forbidden' | 'Unreachable' | 'BadConfig'
              LastError (string)- error detail with SAS query string redacted
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$KillSwitchUrl,

        [Parameter()]
        [int]$TimeoutSec = 15
    )

    if ([string]::IsNullOrWhiteSpace($KillSwitchUrl) -or
        ($KillSwitchUrl -notmatch '^https?://')) {
        return [PSCustomObject]@{
            CanProceed = $false
            Reason = 'BadConfig'
            LastError = 'KillSwitchUrl is empty or not an http(s) URL.'
            SasExpiryWarning = $null
        }
    }

    try {
        $raw = Invoke-RestMethodWithTls `
            -Uri $KillSwitchUrl `
            -Method 'GET' `
            -TimeoutSec $TimeoutSec
    } catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $resp = $_.Exception.Response
            if ($resp.PSObject.Properties.Name -contains 'StatusCode' -and $resp.StatusCode) {
                $statusCode = [int]$resp.StatusCode
            }
        }

        $reason = switch ($statusCode) {
            403 { 'Forbidden' }
            404 { 'NotFound' }
            default { 'Unreachable' }
        }

        $msg = Get-RedactedSasError -Message $_.Exception.Message
        return [PSCustomObject]@{
            CanProceed = $false
            Reason = $reason
            LastError = $msg
            SasExpiryWarning = $null
        }
    }

    # Invoke-RestMethod will deserialize 'enabled' to the string 'enabled',
    # so this comparison is safe for both text/plain and application/octet-stream
    # so long as the blob body is small enough to fit in $raw as a string.
    $text = if ($null -ne $raw) { [string]$raw } else { '' }
    $trimmed = $text.Trim()

    if ($trimmed -ceq 'enabled') {
        $sasExpiryWarning = $null
        if ($KillSwitchUrl -match '[?&]se=([^&]+)') {
            $seValue = [System.Uri]::UnescapeDataString($Matches[1])
            $expiry = [datetime]::MinValue
            if ([datetime]::TryParse($seValue, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$expiry)) {
                $daysLeft = ($expiry.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays
                if ($daysLeft -lt 30) {
                    $sasExpiryWarning = "Kill-switch SAS token expires in $([math]::Floor($daysLeft)) days ($seValue). Rotate before expiry to avoid fleet-wide pause."
                }
            }
        }
        return [PSCustomObject]@{
            CanProceed = $true
            Reason = 'Enabled'
            LastError = $null
            SasExpiryWarning = $sasExpiryWarning
        }
    }

    return [PSCustomObject]@{
        CanProceed = $false
        Reason = 'DisabledContent'
        LastError = "Blob body did not match expected literal 'enabled'."
        SasExpiryWarning = $null
    }
}

function Get-RedactedSasError {
    <#
        .SYNOPSIS
            Strip SAS query-string parameters from any error message that
            may have inlined the full kill-switch URL.

        .DESCRIPTION
            Replaces 'https?://<host><path>?<query>' with
            'https?://<host><path>?<redacted>' so sig=, se=, sp=, and other
            SAS tokens never reach logs or returned LastError fields.
            Also catches bare 'sig=...' tokens that some error formatters
            interpolate without the surrounding URL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Message)

    if ([string]::IsNullOrEmpty($Message)) { return $Message }

    $out = [regex]::Replace($Message, '(https?://[^\s"''<>]+?)\?[^\s"''<>]+', '$1?<redacted>')
    $out = [regex]::Replace($out, '\b(sig|se|sp|sv|sr|st|skoid|sktid|skt|ske|sks|skv|sig)=([^&\s"''<>]+)', '$1=<redacted>')
    return $out
}
