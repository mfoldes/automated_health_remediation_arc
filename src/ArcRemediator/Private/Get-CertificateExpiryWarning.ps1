#Requires -Version 5.1

function Get-CertificateExpiryWarning {
    <#
        .SYNOPSIS
            Check whether an SP certificate in the local store is expiring soon.

        .DESCRIPTION
            Mirrors the SAS expiry warning pattern from Get-KillSwitchState.
            Searches Cert:\LocalMachine\My for a certificate matching -Thumbprint;
            falls back to Cert:\CurrentUser\My if not found in LocalMachine.

            Returns a human-readable warning string if the certificate's NotAfter
            is within -WarningDays of today, or $null if the cert is healthy or
            cannot be found (finding the cert is best-effort; if the store is
            inaccessible or the thumbprint is absent, the warning is suppressed
            rather than blocking the run).

        .PARAMETER Thumbprint
            SHA-1 thumbprint of the certificate to check (hex, with or without
            spaces; case-insensitive).

        .PARAMETER WarningDays
            Number of days before expiry to start warning. Default 30.

        .OUTPUTS
            String or $null. String contains the warning; $null means no warning.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Thumbprint,

        [Parameter()]
        [int]$WarningDays = 30
    )

    # Normalise thumbprint: remove spaces and uppercase.
    $thumb = $Thumbprint -replace '\s', ''

    $cert = $null

    try {
        $cert = Get-Item "Cert:\LocalMachine\My\$thumb" -ErrorAction SilentlyContinue
    } catch {
        $cert = $null
    }

    if (-not $cert) {
        try {
            $cert = Get-Item "Cert:\CurrentUser\My\$thumb" -ErrorAction SilentlyContinue
        } catch {
            $cert = $null
        }
    }

    if (-not $cert) {
        return $null
    }

    $daysLeft = ($cert.NotAfter.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays
    if ($daysLeft -lt $WarningDays) {
        $daysFloor = [math]::Floor($daysLeft)
        return "SP certificate (thumbprint $thumb) expires in $daysFloor days ($($cert.NotAfter.ToString('u'))). Rotate before expiry to avoid authentication failures."
    }

    return $null
}
