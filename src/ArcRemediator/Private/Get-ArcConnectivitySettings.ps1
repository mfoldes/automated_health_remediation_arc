#Requires -Version 5.1

function Get-ArcConnectivitySettings {
    <#
        .SYNOPSIS
            Read local Arc agent state via 'azcmagent show -j' and surface
            the connectivity-affecting fields the remediator needs before
            any Expired delete/rejoin.

        .DESCRIPTION
             the remediator must know - locally,
            before any destructive action - the configured proxy URL,
            private-link scope resource ID, Arc Gateway resource ID
            (when the cloud profile supports gateway), configured cloud,
            and the Arc resource identifiers (sub/RG/name/location).

            This function calls azcmagent.exe show -j, parses the JSON,
            and applies the documented fail-closed rules:

              * Azure Local / cluster-backed evidence -> NeedsHuman.
                The destructive delete/rejoin path must not touch a
                machine that is part of an HCI cluster, has an
                extended-location reference, or carries a parent
                cluster resource ID. The function does not block
                here; it sets IsClusterBacked + NeedsHuman so the
                caller surfaces the outcome correctly.

              * Cloud profile claims SupportsArcGateway=$false but
                local agent reports a non-null Arc Gateway resource ID
                -> ConfigMismatch. DoD/IL5 in particular treats a
                non-null gateway as ConfigMismatch.

              * Private-link or supported-gateway in use but the
                required resource ID cannot be determined from local
                config -> NeedsHuman. The remediator must not reconnect
                through public defaults over a private-link/gateway
                deployment.

            All field names use a tolerant `.PSObject.Properties.Name
            -contains` lookup because azcmagent's `show -j` JSON keys
            have varied across releases. Missing fields are returned
            as `$null`, not synthesized.

        .PARAMETER CloudProfile
            From Get-CloudProfile. SupportsArcGateway is consulted for
            the config-mismatch detection.

        .PARAMETER AzcmagentPath
            Override for tests.

        .PARAMETER TimeoutSec
            azcmagent show timeout. Default 30 s.

        .OUTPUTS
            PSCustomObject with:
              Proxy (string|null)
              PrivateLinkScopeResourceId (string|null)
              ArcGatewayResourceId (string|null)
              Cloud (string|null)
              SubscriptionId (string|null)
              ResourceGroupName (string|null)
              ResourceName (string|null)
              Location (string|null)
              AgentVersion (string|null)
              AgentStatus (string|null) Connected|Disconnected|Expired|...
              IsClusterBacked (bool)
              ClusterEvidence (string[])
              HasConfigMismatch (bool)
              ConfigMismatchReason (string|null)
              NeedsHuman (bool)
              NeedsHumanReason (string|null)
              ParseFailed (bool)
              RawJson (string)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Connectivity Settings is a deliberate aggregate noun (proxy + private link + gateway + cloud + resource IDs). ps1.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSObject]$CloudProfile,
        [Parameter()] [string]$AzcmagentPath,
        [Parameter()] [int]$TimeoutSec = 30
    )

    $invokeArgs = @{
        Arguments = @('show', '-j')
        TimeoutSec = $TimeoutSec
    }
    if ($AzcmagentPath) { $invokeArgs.AzcmagentPath = $AzcmagentPath }

    $proc = Invoke-Azcmagent @invokeArgs
    $raw = [string]$proc.Stdout

    $obj = $null
    $parseFailed = $false
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $parseFailed = $true
            $null = $_
        }
    } else {
        $parseFailed = $true
    }

    $proxy = $null
    $pls = $null
    $gw = $null
    $cloud = $null
    $sub = $null
    $rg = $null
    $name = $null
    $loc = $null
    $ver = $null
    $stat = $null
    $clusterEvidence = New-Object System.Collections.Generic.List[string]

    if ($obj) {
        $props = @($obj.PSObject.Properties.Name)

        $proxy = (Get-FirstStringProperty -Object $obj -Names @('proxyUrl', 'proxy', 'httpsProxy'))
        $pls = (Get-FirstStringProperty -Object $obj -Names @('privateLinkScopeId', 'privateLinkScope', 'privateLinkScopeResourceId'))
        $gw = (Get-FirstStringProperty -Object $obj -Names @('arcGateway', 'gatewayResourceId', 'arcGatewayResourceId'))
        $cloud = (Get-FirstStringProperty -Object $obj -Names @('cloud'))
        $sub = (Get-FirstStringProperty -Object $obj -Names @('subscriptionId'))
        $rg = (Get-FirstStringProperty -Object $obj -Names @('resourceGroupName', 'resourceGroup'))
        $name = (Get-FirstStringProperty -Object $obj -Names @('resourceName'))
        $loc = (Get-FirstStringProperty -Object $obj -Names @('location'))
        $ver = (Get-FirstStringProperty -Object $obj -Names @('agentVersion'))
        $stat = (Get-FirstStringProperty -Object $obj -Names @('agentStatus', 'status'))

        # Cluster-backed / Azure Local evidence
        foreach ($key in 'clusterResourceId', 'parentClusterResourceId') {
            if ($props -contains $key) {
                $val = $obj.$key
                if ($val) { $clusterEvidence.Add("$key=$val") }
            }
        }
        if ($props -contains 'extendedLocation') {
            $ext = $obj.extendedLocation
            if ($ext -and -not ($ext -is [string] -and [string]::IsNullOrWhiteSpace($ext))) {
                $clusterEvidence.Add('extendedLocation present')
            }
        }
        $hostType = Get-FirstStringProperty -Object $obj -Names @('hostType', 'machineType')
        if ($hostType -and ($hostType -imatch 'AzureLocal|HCI|Stack')) {
            $clusterEvidence.Add("hostType=$hostType")
        }
    }

    $isCluster = ($clusterEvidence.Count -gt 0)

    # Empty-string proxy/private-link/gateway should be treated as "not set".
    if ($proxy -and [string]::IsNullOrWhiteSpace($proxy)) { $proxy = $null }
    if ($pls -and [string]::IsNullOrWhiteSpace($pls)) { $pls = $null }
    if ($gw -and [string]::IsNullOrWhiteSpace($gw)) { $gw = $null }

    $configMismatch = $false
    $configReason = $null
    $needsHuman = $false
    $needsHumanReason = $null

    $profileSupportsGw = $false
    if ($CloudProfile.PSObject.Properties.Name -contains 'SupportsArcGateway') {
        $profileSupportsGw = [bool]$CloudProfile.SupportsArcGateway
    }

    if ($gw -and -not $profileSupportsGw) {
        $configMismatch = $true
        $configReason = "Arc Gateway is configured locally ($gw) but the active cloud profile (SupportsArcGateway=$profileSupportsGw) does not support gateway."
    }

    if ($isCluster) {
        $needsHuman = $true
        $needsHumanReason = "Cluster-backed / Azure Local evidence detected: $([string]::Join('; ', $clusterEvidence.ToArray())). Destructive remediation is not permitted."
    } elseif ($pls -and -not $pls) {
        # placeholder branch deliberately unreachable; left for future
    } elseif (($pls -or ($gw -and $profileSupportsGw)) -and -not ($sub -and $rg -and $name -and $loc)) {
        # Private link or supported gateway is active but we cannot identify
        # the resource enough to reconnect. Fail closed to NeedsHuman.
        $needsHuman = $true
        $needsHumanReason = 'Private link or Arc Gateway is in use, but the local resource identifiers (subscription/RG/name/location) could not be determined. Refusing to reconnect via public defaults.'
    }

    return [PSCustomObject]@{
        Proxy = $proxy
        PrivateLinkScopeResourceId = $pls
        ArcGatewayResourceId = $gw
        Cloud = $cloud
        SubscriptionId = $sub
        ResourceGroupName = $rg
        ResourceName = $name
        Location = $loc
        AgentVersion = $ver
        AgentStatus = $stat
        IsClusterBacked = $isCluster
        ClusterEvidence = @($clusterEvidence.ToArray())
        HasConfigMismatch = $configMismatch
        ConfigMismatchReason = $configReason
        NeedsHuman = $needsHuman
        NeedsHumanReason = $needsHumanReason
        ParseFailed = $parseFailed
        RawJson = $raw
    }
}

function Get-FirstStringProperty {
    <#
        .SYNOPSIS
            Return the first non-empty string property value from $Object
            matching any of $Names (case-sensitive, in order).

        .DESCRIPTION
            Tolerant accessor for agent-state JSON whose key spelling has
            varied across azcmagent releases.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSObject]$Object,
        [Parameter(Mandatory)] [string[]]$Names
    )
    $props = @($Object.PSObject.Properties.Name)
    foreach ($n in $Names) {
        if ($props -contains $n) {
            $v = $Object.$n
            if ($null -ne $v -and -not ($v -is [string] -and [string]::IsNullOrWhiteSpace($v))) {
                return [string]$v
            }
        }
    }
    return $null
}
