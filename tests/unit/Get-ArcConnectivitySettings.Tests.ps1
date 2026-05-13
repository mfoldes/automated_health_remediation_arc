#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Get-ArcConnectivitySettings' {

    Context 'Happy path (Commercial, public connectivity)' {
        It 'parses the common azcmagent show fields' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    $json = @'
{
  "agentVersion": "1.45.0",
  "resourceName": "srv-prod-1",
  "resourceGroupName": "rg-arc-prod",
  "subscriptionId": "00000000-0000-0000-0000-000000000000",
  "tenantId": "11111111-1111-1111-1111-111111111111",
  "location": "eastus",
  "cloud": "AzureCloud",
  "agentStatus": "Connected",
  "proxyUrl": "",
  "privateLinkScopeId": "",
  "arcGateway": null
}
'@
                    [PSCustomObject]@{ ExitCode=0; Stdout=$json; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $r = Get-ArcConnectivitySettings -CloudProfile (Get-CloudProfile -Name 'Commercial')
                $r.ParseFailed | Should -BeFalse
                $r.AgentVersion | Should -Be '1.45.0'
                $r.Cloud | Should -Be 'AzureCloud'
                $r.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000000'
                $r.ResourceGroupName | Should -Be 'rg-arc-prod'
                $r.ResourceName | Should -Be 'srv-prod-1'
                $r.Location | Should -Be 'eastus'
                $r.AgentStatus | Should -Be 'Connected'
                $r.Proxy | Should -BeNullOrEmpty
                $r.PrivateLinkScopeResourceId | Should -BeNullOrEmpty
                $r.ArcGatewayResourceId | Should -BeNullOrEmpty
                $r.IsClusterBacked | Should -BeFalse
                $r.HasConfigMismatch | Should -BeFalse
                $r.NeedsHuman | Should -BeFalse
            }
        }
    }

    Context 'DoD/IL5 config mismatch: gateway configured but profile forbids' {
        It 'sets HasConfigMismatch=$true when DoD profile sees a non-null arcGateway' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    $json = @'
{
  "agentVersion": "1.45.0",
  "cloud": "AzureUSGovernment",
  "subscriptionId": "s","resourceGroupName":"rg","resourceName":"n","location":"usgovvirginia",
  "agentStatus": "Connected",
  "arcGateway": "/subscriptions/s/resourceGroups/rg/providers/Microsoft.HybridCompute/gateways/gw1"
}
'@
                    [PSCustomObject]@{ ExitCode=0; Stdout=$json; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $r = Get-ArcConnectivitySettings -CloudProfile (Get-CloudProfile -Name 'AzureGovernmentDoD')
                $r.ArcGatewayResourceId | Should -Match '/gateways/gw1$'
                $r.HasConfigMismatch | Should -BeTrue
                $r.ConfigMismatchReason | Should -Match 'Arc Gateway is configured locally'
                $r.ConfigMismatchReason | Should -Match 'SupportsArcGateway=False'
            }
        }
    }

    Context 'Cluster-backed / Azure Local evidence' {
        It 'flags IsClusterBacked + NeedsHuman when clusterResourceId is present' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    $json = @'
{
  "cloud":"AzureCloud","subscriptionId":"s","resourceGroupName":"rg","resourceName":"n","location":"eastus",
  "agentStatus":"Connected",
  "clusterResourceId":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/c1"
}
'@
                    [PSCustomObject]@{ ExitCode=0; Stdout=$json; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $r = Get-ArcConnectivitySettings -CloudProfile (Get-CloudProfile -Name 'Commercial')
                $r.IsClusterBacked | Should -BeTrue
                @($r.ClusterEvidence) | Should -Contain 'clusterResourceId=/subscriptions/s/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/c1'
                $r.NeedsHuman | Should -BeTrue
                $r.NeedsHumanReason | Should -Match 'Cluster-backed'
            }
        }

        It 'flags Azure Local via extendedLocation presence' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    $json = @'
{
  "cloud":"AzureCloud","subscriptionId":"s","resourceGroupName":"rg","resourceName":"n","location":"eastus",
  "agentStatus":"Connected",
  "extendedLocation": { "name":"el1","type":"CustomLocation" }
}
'@
                    [PSCustomObject]@{ ExitCode=0; Stdout=$json; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $r = Get-ArcConnectivitySettings -CloudProfile (Get-CloudProfile -Name 'Commercial')
                $r.IsClusterBacked | Should -BeTrue
                $r.NeedsHuman | Should -BeTrue
            }
        }
    }

    Context 'Private link or supported gateway with missing identifiers' {
        It 'returns NeedsHuman when private link is configured but resource identifiers are missing' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    $json = @'
{
  "cloud":"AzureCloud","agentStatus":"Disconnected",
  "privateLinkScopeId":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.HybridCompute/privateLinkScopes/pls1"
}
'@
                    [PSCustomObject]@{ ExitCode=0; Stdout=$json; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $r = Get-ArcConnectivitySettings -CloudProfile (Get-CloudProfile -Name 'Commercial')
                $r.PrivateLinkScopeResourceId | Should -Match '/privateLinkScopes/pls1$'
                $r.NeedsHuman | Should -BeTrue
                $r.NeedsHumanReason | Should -Match 'reconnect via public defaults'
            }
        }
    }

    Context 'Parse failure (best-effort)' {
        It 'sets ParseFailed=$true on garbage output and does not throw' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    [PSCustomObject]@{ ExitCode=99; Stdout='<<<not json>>>'; Stderr='boom'; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                { Get-ArcConnectivitySettings -CloudProfile (Get-CloudProfile -Name 'Commercial') } | Should -Not -Throw
                $r = Get-ArcConnectivitySettings -CloudProfile (Get-CloudProfile -Name 'Commercial')
                $r.ParseFailed | Should -BeTrue
                $r.NeedsHuman | Should -BeFalse
            }
        }
    }
}
