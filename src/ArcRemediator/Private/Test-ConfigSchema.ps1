#Requires -Version 5.1

function Test-ConfigSchema {
    <#
        .SYNOPSIS
            Validate the decrypted config object against the expected schema.

        .DESCRIPTION
            Called immediately after Get-DecryptedConfig. Returns a result
            object rather than throwing so the caller can emit a structured
            ConfigMismatch outcome instead of an unhandled Error.

            Validates:
            - Required string fields at the top level.
            - CloudProfile enum: Commercial | AzureGovernmentDoD.
            - CredentialType enum on ArcCredential: Certificate | ClientSecret.
            - CircuitBreakerFailureThreshold range [1, 100] when present.
            - ScopedResourceGroups: non-empty string array when present.
            - ArcCredential sub-object with required fields.
            - Unknown top-level keys emit a warning but do not fail.

        .PARAMETER Config
            The PSCustomObject returned by Get-DecryptedConfig.

        .OUTPUTS
            PSCustomObject with:
              IsValid (bool)
              Failures (string[])
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Config is used throughout the body.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Config
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    # ---- Required top-level string fields -----------------------------------
    $requiredStrings = @('SubscriptionId', 'KillSwitchUrl')
    foreach ($field in $requiredStrings) {
        if (-not $Config.PSObject.Properties[$field] -or
            [string]::IsNullOrWhiteSpace([string]$Config.PSObject.Properties[$field].Value)) {
            $failures.Add("Required field '$field' is missing or empty.")
        }
    }

    # ---- CloudProfile enum --------------------------------------------------
    $validClouds = @('Commercial', 'AzureGovernmentDoD')
    if ($Config.PSObject.Properties['CloudProfile']) {
        $cp = [string]$Config.CloudProfile
        if ($cp -notin $validClouds) {
            $failures.Add("CloudProfile '$cp' is not in the allowed set: $($validClouds -join ', ').")
        }
    } else {
        $failures.Add("Required field 'CloudProfile' is missing.")
    }

    # ---- CircuitBreakerFailureThreshold range -------------------------------
    if ($Config.PSObject.Properties['CircuitBreakerFailureThreshold']) {
        $cbft = $Config.CircuitBreakerFailureThreshold
        $cbftInt = 0
        if ([int]::TryParse([string]$cbft, [ref]$cbftInt)) {
            if ($cbftInt -lt 1 -or $cbftInt -gt 100) {
                $failures.Add("CircuitBreakerFailureThreshold must be in [1, 100]; got $cbftInt.")
            }
        } else {
            $failures.Add("CircuitBreakerFailureThreshold '$cbft' is not a valid integer.")
        }
    }

    # ---- ScopedResourceGroups: string array entries must be non-empty when present ----------
    if ($Config.PSObject.Properties['ScopedResourceGroups']) {
        $srg = @($Config.ScopedResourceGroups)
        foreach ($rg in $srg) {
            if ([string]::IsNullOrWhiteSpace([string]$rg)) {
                $failures.Add("ScopedResourceGroups contains a null or empty entry.")
                break
            }
        }
    }

    # ---- ArcCredential sub-object ------------------------------------------
    if ($Config.PSObject.Properties['ArcCredential'] -and $null -ne $Config.ArcCredential) {
        $arc = $Config.ArcCredential
        $arcRequired = @('TenantId', 'ClientId', 'CredentialType')
        foreach ($f in $arcRequired) {
            if (-not $arc.PSObject.Properties[$f] -or
                [string]::IsNullOrWhiteSpace([string]$arc.PSObject.Properties[$f].Value)) {
                $failures.Add("ArcCredential.$f is missing or empty.")
            }
        }

        # CredentialType enum
        $validCredTypes = @('Certificate', 'ClientSecret')
        if ($arc.PSObject.Properties['CredentialType']) {
            $ct = [string]$arc.CredentialType
            if ($ct -notin $validCredTypes) {
                $failures.Add("ArcCredential.CredentialType '$ct' is not in the allowed set: $($validCredTypes -join ', ').")
            } elseif ($ct -eq 'Certificate') {
                if (-not $arc.PSObject.Properties['CertificateThumbprint'] -or
                    [string]::IsNullOrWhiteSpace([string]$arc.PSObject.Properties['CertificateThumbprint'].Value)) {
                    $failures.Add("ArcCredential.CertificateThumbprint is required when CredentialType=Certificate.")
                }
            } elseif ($ct -eq 'ClientSecret') {
                if (-not $arc.PSObject.Properties['ClientSecret'] -or
                    [string]::IsNullOrWhiteSpace([string]$arc.PSObject.Properties['ClientSecret'].Value)) {
                    $failures.Add("ArcCredential.ClientSecret is required when CredentialType=ClientSecret.")
                }
            }
        }
    } else {
        $failures.Add("Required sub-object 'ArcCredential' is missing.")
    }

    # ---- Known top-level keys (unknown keys get a warning) -----------------
    $knownKeys = @(
        'SubscriptionId', 'KillSwitchUrl',
        'CloudProfile', 'Mode', 'CircuitBreakerFailureThreshold',
        'ScopedResourceGroups', 'BreakerResetUrl', 'EnableAutomaticAgentUpgrade',
        'MaxRuntimeMinutes', 'ReconnectOnlyCooldownHours',
        'ArcCredential', 'MonitorCredential',
        'LogIngestionEndpoint', 'DcrImmutableId', 'StreamName',
        'PrivateLinkScopeResourceId', 'ArcGatewayResourceId', 'ProxyUrl', 'Version'
    )
    foreach ($prop in $Config.PSObject.Properties) {
        if ($prop.Name -notin $knownKeys) {
            Write-Warning "Test-ConfigSchema: unknown config key '$($prop.Name)' — verify this field is intentional."
        }
    }

    return [PSCustomObject]@{
        IsValid  = ($failures.Count -eq 0)
        Failures = $failures.ToArray()
    }
}
