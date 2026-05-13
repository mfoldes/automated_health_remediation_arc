#Requires -Version 5.1

function New-ClientAssertion {
    <#
        .SYNOPSIS
            Build an RS256-signed JWT for the Entra confidential-client
            certificate-credential flow (urn:ietf:params:oauth:client-assertion-type:jwt-bearer).

        .DESCRIPTION
            Locates a certificate in Cert:\LocalMachine\My (preferred) or
            Cert:\CurrentUser\My (fallback) by thumbprint, constructs the
            JWT header and payload required by Microsoft Entra, and signs
            the header.payload with the certificate's RSA private key.

            Header:
              { "alg": "RS256", "typ": "JWT", "x5t": base64url(sha1(rawCertBytes)) }
              x5t is the base64url-encoded SHA-1 thumbprint of the certificate
              (which is also what the thumbprint string represents in hex).

            Payload:
              { "aud": <token endpoint URL>, "iss": <client_id>, "sub": <client_id>,
                "jti": <fresh guid>, "nbf": <now>, "exp": <now + 10 min> }

            The signed assertion is never logged. The function returns a
            base64url-encoded string and nothing else.

        .PARAMETER ClientId
            Application (client) ID of the SP.

        .PARAMETER Thumbprint
            SHA-1 thumbprint of the certificate (hex, no spaces, 40 chars).
            Case-insensitive.

        .PARAMETER Audience
            Token endpoint URL used as the JWT 'aud' claim. Must exactly
            match the URL the assertion will be POSTed to.

        .PARAMETER ValidityMinutes
            Assertion lifetime. Defaults to 10 minutes per Microsoft
            recommendation (max practical is 24 hours).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory: returns a signed JWT string. Performs no state change on the host.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$ClientId,
        [Parameter(Mandatory)] [string]$Thumbprint,
        [Parameter(Mandatory)] [string]$Audience,
        [Parameter()] [int] $ValidityMinutes = 10
    )

    $tp = $Thumbprint -replace '\s', '' -replace ':', ''
    $cert = $null
    foreach ($store in 'Cert:\LocalMachine\My', 'Cert:\CurrentUser\My') {
        if (Test-Path -LiteralPath $store) {
            $candidate = Get-ChildItem -LiteralPath $store -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -ieq $tp } |
                Select-Object -First 1
            if ($candidate) { $cert = $candidate; break }
        }
    }
    if (-not $cert) {
        throw "New-ClientAssertion: certificate with thumbprint '$tp' not found in LocalMachine\My or CurrentUser\My."
    }
    if (-not $cert.HasPrivateKey) {
        throw "New-ClientAssertion: certificate '$tp' has no accessible private key."
    }

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    if (-not $rsa) {
        throw "New-ClientAssertion: certificate '$tp' does not expose an RSA private key (RS256 required)."
    }

    $thumbBytes = New-Object byte[] ($tp.Length / 2)
    for ($i = 0; $i -lt $thumbBytes.Length; $i++) {
        $thumbBytes[$i] = [Convert]::ToByte($tp.Substring($i * 2, 2), 16)
    }
    $x5t = ConvertTo-Base64Url -Bytes $thumbBytes

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $exp = ([DateTimeOffset]::UtcNow.AddMinutes($ValidityMinutes)).ToUnixTimeSeconds()

    $header = [ordered]@{ alg = 'RS256'; typ = 'JWT'; x5t = $x5t } | ConvertTo-Json -Compress
    $payload = [ordered]@{
        aud = $Audience
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now
        exp = $exp
    } | ConvertTo-Json -Compress

    $headerB64 = ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($header))
    $payloadB64 = ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($payload))
    $signingInput = "$headerB64.$payloadB64"

    $signBytes = [Text.Encoding]::UTF8.GetBytes($signingInput)
    $sigBytes = $rsa.SignData(
        $signBytes,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

    $sigB64 = ConvertTo-Base64Url -Bytes $sigBytes
    return "$signingInput.$sigB64"
}

function ConvertTo-Base64Url {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [byte[]]$Bytes)
    $b64 = [Convert]::ToBase64String($Bytes)
    return ($b64.TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}
