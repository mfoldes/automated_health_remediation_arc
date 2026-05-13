#Requires -Version 5.1

function Get-AzureToken {
    <#
        .SYNOPSIS
            Acquire an Entra access token for an explicit audience (ARM or Monitor)
            using either a certificate (JWT-bearer) or a short-lived client secret.

        .DESCRIPTION
             the remediator must acquire
            separate tokens per audience and must not silently reuse one token shape
            for both. This helper enforces two distinct code paths:

              * Purpose=Arc -> v1 token endpoint /oauth2/token with body parameter resource=<ArmTokenResource>
              * Purpose=Monitor -> v2 token endpoint /oauth2/v2.0/token with body parameter scope=<MonitorTokenScope>

            Token values, client secrets, and signed JWT assertions are never written
            to logs, exceptions, or process arguments. Exception messages are scrubbed
            of body content before re-throw.

            Cloud profile supplies the Entra authority, the ARM v1 resource string,
            and the Monitor v2 scope. The two MVP clouds are Commercial and
            AzureGovernmentDoD; both audiences are exercised in tests for each.

        .PARAMETER CloudProfile
            The hashtable/object returned by Get-CloudProfile. Must expose
            EntraAuthority, ArmTokenResource, MonitorTokenScope.

        .PARAMETER Credential
            One of the credential blocks from the DPAPI-decrypted config:
            ArcCredential or MonitorCredential. Must expose TenantId, ClientId,
            CredentialType ('Certificate' or 'ClientSecret'), and either
            CertificateThumbprint (for Certificate) or ClientSecret (for ClientSecret).

        .PARAMETER Purpose
            'Arc' (ARM v1 resource flow) or 'Monitor' (v2 /.default scope flow).

        .PARAMETER TimeoutSec
            HTTP request timeout. Defaults to 30 seconds.

        .OUTPUTS
            PSCustomObject with: Purpose, AccessToken (string), TokenType,
            ExpiresOnUtc (datetime). The token string is returned because the
            caller will set it on an Authorization header; it is the caller's
            responsibility never to log this value.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '',
        Justification = 'The -Credential parameter takes a DPAPI-decrypted config block (TenantId/ClientId/CredentialType/ClientSecret/CertificateThumbprint), not a PSCredential. PSCredential cannot represent a certificate-thumbprint flow.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [PSObject]$CloudProfile,

        [Parameter(Mandatory)]
        [PSObject]$Credential,

        [Parameter(Mandatory)]
        [ValidateSet('Arc', 'Monitor')]
        [string]$Purpose,

        [Parameter()]
        [int]$TimeoutSec = 30
    )

    if (-not $Credential.TenantId) { throw "Get-AzureToken($Purpose): TenantId missing on credential." }
    if (-not $Credential.ClientId) { throw "Get-AzureToken($Purpose): ClientId missing on credential." }

    $authority = $CloudProfile.EntraAuthority.TrimEnd('/')
    if ($Purpose -eq 'Arc') {
        $tokenUrl = "$authority/$($Credential.TenantId)/oauth2/token"
        $resourceKey = 'resource'
        $resourceVal = $CloudProfile.ArmTokenResource
    } else {
        $tokenUrl = "$authority/$($Credential.TenantId)/oauth2/v2.0/token"
        $resourceKey = 'scope'
        $resourceVal = $CloudProfile.MonitorTokenScope
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('grant_type=client_credentials')
    $parts.Add("$resourceKey=$([System.Net.WebUtility]::UrlEncode($resourceVal))")
    $parts.Add("client_id=$([System.Net.WebUtility]::UrlEncode($Credential.ClientId))")

    switch ($Credential.CredentialType) {
        'ClientSecret' {
            if (-not $Credential.ClientSecret) {
                throw "Get-AzureToken($Purpose): CredentialType=ClientSecret but ClientSecret is empty."
            }
            $parts.Add("client_secret=$([System.Net.WebUtility]::UrlEncode([string]$Credential.ClientSecret))")
        }
        'Certificate' {
            if (-not $Credential.CertificateThumbprint) {
                throw "Get-AzureToken($Purpose): CredentialType=Certificate but CertificateThumbprint is empty."
            }
            $assertion = New-ClientAssertion `
                -ClientId $Credential.ClientId `
                -Thumbprint $Credential.CertificateThumbprint `
                -Audience $tokenUrl
            $parts.Add('client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer')
            $parts.Add("client_assertion=$([System.Net.WebUtility]::UrlEncode($assertion))")
        }
        default {
            throw "Get-AzureToken($Purpose): Unsupported CredentialType '$($Credential.CredentialType)'. Expected 'Certificate' or 'ClientSecret'."
        }
    }

    $body = [string]::Join('&', $parts.ToArray())

    try {
        $response = Invoke-RestMethodWithTls `
            -Uri $tokenUrl `
            -Method 'POST' `
            -Body $body `
            -ContentType 'application/x-www-form-urlencoded' `
            -TimeoutSec $TimeoutSec
    } catch {
        # Scrub: never let the request body (which holds client_secret or
        # client_assertion) leak into a re-thrown exception or upstream log.
        # We rely on Invoke-RestMethod's exception message which does NOT
        # normally include the body, but we add a defensive throw that
        # carries only the status and target URL host - not query string.
        $msg = $_.Exception.Message
        $msg = [regex]::Replace($msg, 'client_secret=[^&\s"]+', 'client_secret=<redacted>')
        $msg = [regex]::Replace($msg, 'client_assertion=[^&\s"]+', 'client_assertion=<redacted>')
        throw "Get-AzureToken($Purpose) token request failed: $msg"
    }

    $respProps = @($response.PSObject.Properties.Name)
    if (-not ($respProps -contains 'access_token') -or [string]::IsNullOrEmpty([string]$response.access_token)) {
        throw "Get-AzureToken($Purpose): token response missing access_token."
    }

    $expiresIn = 3600
    if ($respProps -contains 'expires_in') {
        $expiresIn = [int]$response.expires_in
    }

    return [PSCustomObject]@{
        Purpose = $Purpose
        AccessToken = [string]$response.access_token
        TokenType = if ($respProps -contains 'token_type') { [string]$response.token_type } else { 'Bearer' }
        ExpiresOnUtc = (Get-Date).ToUniversalTime().AddSeconds($expiresIn)
    }
}
