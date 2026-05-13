#Requires -Version 5.1

function Out-CloudConfigSample {
    <#
        .SYNOPSIS
            Emit a working cloud-specific config sample JSON the operator
            can install at %ProgramData%\ArcRemediator\config.json after
            DPAPI-wrapping.

        .DESCRIPTION
             Setup-AzureSide
            must emit a working JSON sample that the operator's GPO /
            scripted-install path consumes. The shape matches the design exactly:

                CloudProfile, ArcCredential.*, MonitorCredential.*,
                SubscriptionId, ScopedResourceGroups, LogIngestionEndpoint,
                DcrImmutableId, StreamName, KillSwitchUrl,
                PrivateLinkScopeResourceId, ArcGatewayResourceId, ProxyUrl,
                EnableAutomaticAgentUpgrade, CircuitBreakerFailureThreshold,
                Mode, Version

            Mode defaults to 'Observe' so a fresh canary host never
            mutates state on its first run.

            For AzureGovernmentDoD: ArcGatewayResourceId is forced to
            $null and EnableAutomaticAgentUpgrade to $false regardless
            of caller input (capability flags)
            and Microsoft Learn, both features are Azure-public-only.

        .PARAMETER OutputPath
            File path to write. If empty, returns the JSON string.

        .PARAMETER CloudProfile
            'Commercial' or 'AzureGovernmentDoD'.

        .PARAMETER ArcCredential
            Object with TenantId, ClientId, CredentialType,
            ClientSecret, CertificateThumbprint.

        .PARAMETER MonitorCredential
            Object with the same shape as ArcCredential plus
            UseArcCredential ($true/$false).

        .PARAMETER SubscriptionId
            Subscription where Arc resources live.

        .PARAMETER ScopedResourceGroupName
            Arc resource groups the remediator may act on.

        .PARAMETER LogIngestionEndpoint
            Logs Ingestion URL (from DCR.endpoints.logsIngestion or DCE).

        .PARAMETER DcrImmutableId
            Immutable ID from the DCR.

        .PARAMETER StreamName
            'Custom-ArcRemediation' by default.

        .PARAMETER KillSwitchUrl
            Service SAS URL of the kill-switch blob.

        .PARAMETER PrivateLinkScopeResourceId
            Optional. ARM resource ID of the Arc private link scope.

        .PARAMETER ArcGatewayResourceId
            Optional. ARM resource ID of the Arc Gateway. Ignored for
            AzureGovernmentDoD.

        .PARAMETER ProxyUrl
            Optional HTTP proxy URL.

        .PARAMETER EnableAutomaticAgentUpgrade
            Default $false. Ignored (forced $false) for
            AzureGovernmentDoD.

        .PARAMETER CircuitBreakerFailureThreshold
            Default 3.

        .PARAMETER Mode
            'Observe' (default) or 'Enforce'.

        .PARAMETER Version
            Default '1.0.0'.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'ScopedResourceGroupName is a deliberate array param; the design names this field ScopedResourceGroups in the emitted JSON.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [ValidateSet('Commercial', 'AzureGovernmentDoD')]
        [string]$CloudProfile,

        [Parameter(Mandatory)]
        [PSObject]$ArcCredential,

        [Parameter(Mandatory)]
        [PSObject]$MonitorCredential,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string[]]$ScopedResourceGroupName,

        [Parameter(Mandatory)]
        [string]$LogIngestionEndpoint,

        [Parameter(Mandatory)]
        [string]$DcrImmutableId,

        [Parameter(Mandatory)]
        [string]$KillSwitchUrl,

        [Parameter()]
        [string]$StreamName = 'Custom-ArcRemediation',

        [Parameter()]
        [string]$PrivateLinkScopeResourceId,

        [Parameter()]
        [string]$ArcGatewayResourceId,

        [Parameter()]
        [string]$ProxyUrl,

        [Parameter()]
        [bool]$EnableAutomaticAgentUpgrade = $false,

        [Parameter()]
        [int]$CircuitBreakerFailureThreshold = 3,

        [Parameter()]
        [ValidateSet('Observe', 'Enforce')]
        [string]$Mode = 'Observe',

        [Parameter()]
        [string]$Version = '1.0.0'
    )

    # DoD/IL5 forced overrides per the capability flags.
    if ($CloudProfile -eq 'AzureGovernmentDoD') {
        $ArcGatewayResourceId = $null
        $EnableAutomaticAgentUpgrade = $false
    }

    $config = [ordered]@{
        CloudProfile = $CloudProfile
        ArcCredential = [ordered]@{
            TenantId = $ArcCredential.TenantId
            ClientId = $ArcCredential.ClientId
            CredentialType = $ArcCredential.CredentialType
            ClientSecret = $ArcCredential.ClientSecret
            CertificateThumbprint = $ArcCredential.CertificateThumbprint
        }
        MonitorCredential = [ordered]@{
            UseArcCredential = [bool]($MonitorCredential.UseArcCredential)
            TenantId = $MonitorCredential.TenantId
            ClientId = $MonitorCredential.ClientId
            CredentialType = $MonitorCredential.CredentialType
            ClientSecret = $MonitorCredential.ClientSecret
            CertificateThumbprint = $MonitorCredential.CertificateThumbprint
        }
        SubscriptionId = $SubscriptionId
        ScopedResourceGroups = @($ScopedResourceGroupName)
        LogIngestionEndpoint = $LogIngestionEndpoint
        DcrImmutableId = $DcrImmutableId
        StreamName = $StreamName
        KillSwitchUrl = $KillSwitchUrl
        PrivateLinkScopeResourceId = $PrivateLinkScopeResourceId
        ArcGatewayResourceId = $ArcGatewayResourceId
        ProxyUrl = $ProxyUrl
        EnableAutomaticAgentUpgrade = $EnableAutomaticAgentUpgrade
        CircuitBreakerFailureThreshold = $CircuitBreakerFailureThreshold
        Mode = $Mode
        Version = $Version
    }

    $json = $config | ConvertTo-Json -Depth 10

    if ($OutputPath) {
        if ($PSCmdlet.ShouldProcess($OutputPath, 'Write config sample')) {
            $dir = Split-Path -Parent $OutputPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8 -NoNewline
        }
    }

    return $json
}
