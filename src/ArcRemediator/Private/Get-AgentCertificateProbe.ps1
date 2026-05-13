#Requires -Version 5.1

function Get-AgentCertificateProbe {
    <#
        .SYNOPSIS
            Best-effort surface of Arc agent certificate expiry metadata
            from azcmagent show -j output.

        .DESCRIPTION
            Per the requirement, the certificate probe
            is best-effort only:

              * If azcmagent show -j exposes certificate metadata, parse
                NotBefore / NotAfter into datetimes and compute
                DaysUntilExpiry.
              * If it does not (older agent versions, or the field shape
                changes), return Status='Unavailable' and never throw.

            The implementation MUST NOT attempt to read HIMDS internal
            certificate stores directly - those are agent-internal
            implementation details that vary by agent version and have
            no Microsoft-supported public interface (design).

            The tolerant field-name lookup handles per-version drift in
            the JSON key spelling. The fields searched are documented
            inline; new spellings should be added here as Microsoft
            publishes them rather than guessed elsewhere in the module.

        .PARAMETER ConnectivitySettings
            Output of Get-ArcConnectivitySettings, which already holds
            the parsed JSON in its RawJson field.

        .PARAMETER Now
            Override current time for tests. Defaults to UtcNow.

        .OUTPUTS
            PSCustomObject with:
              NotBefore (datetime|null)
              NotAfter (datetime|null)
              DaysUntilExpiry (int|null)
              IsExpired (bool|null)
              Status ('OK'|'NearExpiry'|'Expired'|'Unavailable')
              Source (string) 'azcmagent-show' | 'unavailable'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSObject]$ConnectivitySettings,
        [Parameter()] [datetime]$Now = ([datetime]::UtcNow)
    )

    $unavailable = [PSCustomObject]@{
        NotBefore = $null
        NotAfter = $null
        DaysUntilExpiry = $null
        IsExpired = $null
        Status = 'Unavailable'
        Source = 'unavailable'
    }

    if (-not ($ConnectivitySettings.PSObject.Properties.Name -contains 'RawJson')) {
        return $unavailable
    }
    $raw = [string]$ConnectivitySettings.RawJson
    if ([string]::IsNullOrWhiteSpace($raw)) { return $unavailable }

    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $null = $_; return $unavailable }
    if (-not $obj) { return $unavailable }

    # Tolerant field lookup: agent exposes certificate metadata under one
    # of several keys depending on version (none documented as stable).
    # ConvertFrom-Json on PS 5.1 auto-converts ISO 8601 strings to [datetime]
    # objects with Kind=Local, so check for that shape first before falling
    # back to a string parse.
    $notBefore = ConvertTo-UtcDateTime -Value (Get-PropertyValue -Object $obj -Names @('certificateNotBefore', 'agentCertificateNotBefore', 'certNotBefore'))
    $notAfter = ConvertTo-UtcDateTime -Value (Get-PropertyValue -Object $obj -Names @('certificateNotAfter', 'agentCertificateNotAfter', 'certNotAfter', 'certificateExpirationDate'))

    if (-not $notAfter) {
        return $unavailable
    }

    $daysLeft = [int][math]::Floor(($notAfter - $Now).TotalDays)
    $isExpired = ($notAfter -le $Now)

    $status = if ($isExpired) {
        'Expired'
    } elseif ($daysLeft -lt 14) {
        'NearExpiry'
    } else {
        'OK'
    }

    return [PSCustomObject]@{
        NotBefore = $notBefore
        NotAfter = $notAfter
        DaysUntilExpiry = $daysLeft
        IsExpired = $isExpired
        Status = $status
        Source = 'azcmagent-show'
    }
}

function Get-PropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSObject]$Object,
        [Parameter(Mandatory)] [string[]]$Names
    )
    $props = @($Object.PSObject.Properties.Name)
    foreach ($n in $Names) {
        if ($props -contains $n) {
            $v = $Object.$n
            if ($null -ne $v -and -not ($v -is [string] -and [string]::IsNullOrWhiteSpace($v))) {
                return $v
            }
        }
    }
    return $null
}

function ConvertTo-UtcDateTime {
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter()] [AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($s, $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    if ([datetime]::TryParse($s, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}
