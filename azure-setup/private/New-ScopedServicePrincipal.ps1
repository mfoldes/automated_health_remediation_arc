#Requires -Version 5.1

function New-ScopedServicePrincipal {
    <#
        .SYNOPSIS
            Create or reuse a dedicated scoped service principal for the Arc
            Remediator MVP and emit credential information as a PSObject.

        .DESCRIPTION
             Setup-AzureSide.ps1 must create
            (or reuse) two service principal identities per cloud: one for
            Arc remediation (ARM ops, role: Azure Connected Machine
            Resource Administrator + Onboarding) and one for Logs Ingestion
            (role: Monitoring Metrics Publisher on the DCR). This helper
            handles a single SP at a time; the driver invokes it twice with
            different -DisplayName values.

            The function is idempotent: an existing AAD application or
            service principal with the supplied DisplayName is reused; only
            missing pieces are created.

            By default a self-signed certificate is generated in
            Cert:\LocalMachine\My, the public-key bytes are uploaded to the
            AAD application as a credential, and the thumbprint is returned.
            Operators export the private key (Export-PfxCertificate) and
            distribute it out of band. Certificate credentials are the
            production default.

            -UseClientSecret switches to the lab/canary path: a short-lived
            client-secret credential is created. -SecretValidityDays
            defaults to 90 to enforce rotation; we forbid a
            single all-fleet broad secret as a production default.

        .PARAMETER DisplayName
            AAD application display name. Must be unique per intended scope
            (e.g. 'sp-arc-remediator-commercial-canary-1'). Required.

        .PARAMETER UseClientSecret
            Use a client-secret credential instead of a certificate. Marked
            for lab/canary use only.

        .PARAMETER CertificateValidityDays
            Cert credential validity. Defaults to 365.

        .PARAMETER SecretValidityDays
            Secret credential validity. Defaults to 90.

        .OUTPUTS
            PSCustomObject with the fields:
              ApplicationId AAD app (client) ID
              ObjectId SP object ID (used for role assignments)
              TenantId From the current Az context
              CredentialType 'Certificate' or 'ClientSecret'
              ClientSecret Plaintext secret (lab/canary only)
              CertificateThumbprint Cert thumbprint (production path)
              CredentialExpiry NotAfter / EndDate of the credential
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$DisplayName,

        [Parameter()]
        [switch]$UseClientSecret,

        [Parameter()]
        [int]$CertificateValidityDays = 365,

        [Parameter()]
        [int]$SecretValidityDays = 90
    )

    # Reuse existing AAD app if present (idempotent).
    $app = Get-AzADApplication -DisplayName $DisplayName -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $app) {
        if (-not $PSCmdlet.ShouldProcess($DisplayName, 'New-AzADApplication')) {
            return
        }
        $app = New-AzADApplication -DisplayName $DisplayName -ErrorAction Stop
    }

    # Reuse existing SP if present.
    $sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $sp) {
        if (-not $PSCmdlet.ShouldProcess($DisplayName, 'New-AzADServicePrincipal')) {
            return
        }
        $sp = New-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction Stop
    }

    $tenantId = (Get-AzContext).Tenant.Id

    if ($UseClientSecret) {
        $end = (Get-Date).AddDays($SecretValidityDays)
        if (-not $PSCmdlet.ShouldProcess($DisplayName, 'New-AzADAppCredential (secret)')) {
            return
        }
        $cred = New-AzADAppCredential -ApplicationId $app.AppId -EndDate $end -ErrorAction Stop
        return [PSCustomObject]@{
            ApplicationId = $app.AppId
            ObjectId = $sp.Id
            TenantId = $tenantId
            CredentialType = 'ClientSecret'
            ClientSecret = $cred.SecretText
            CertificateThumbprint = $null
            CredentialExpiry = $end
        }
    }

    # Default path: self-signed certificate.
    $end = (Get-Date).AddDays($CertificateValidityDays)
    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'New-SelfSignedCertificate + New-AzADAppCredential (cert)')) {
        return
    }
    $cert = New-SelfSignedCertificate `
        -Subject "CN=$DisplayName" `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -KeyExportPolicy Exportable `
        -KeySpec Signature `
        -KeyLength 4096 `
        -KeyAlgorithm RSA `
        -HashAlgorithm SHA256 `
        -NotAfter $end

    $certBase64 = [System.Convert]::ToBase64String($cert.GetRawCertData())
    $null = New-AzADAppCredential -ApplicationId $app.AppId -CertValue $certBase64 -EndDate $end -ErrorAction Stop

    return [PSCustomObject]@{
        ApplicationId = $app.AppId
        ObjectId = $sp.Id
        TenantId = $tenantId
        CredentialType = 'Certificate'
        ClientSecret = $null
        CertificateThumbprint = $cert.Thumbprint
        CredentialExpiry = $end
    }
}
