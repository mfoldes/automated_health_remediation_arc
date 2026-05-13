#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ManifestPath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
}

Describe 'Get-CloudProfile' {

    Context 'Commercial profile (per the endpoint table)' {
        BeforeAll {
            $script:p = InModuleScope ArcRemediator { Get-CloudProfile -Name 'Commercial' }
        }

        It 'declares AzEnvironment = AzureCloud' {
            $script:p.AzEnvironment | Should -Be 'AzureCloud'
        }

        It 'declares ARM endpoint and resource for public cloud' {
            $script:p.ArmEndpoint | Should -Be 'https://management.azure.com'
            $script:p.ArmTokenResource | Should -Be 'https://management.azure.com/'
        }

        It 'declares Monitor audience https://monitor.azure.com/.default' {
            $script:p.MonitorTokenScope | Should -Be 'https://monitor.azure.com/.default'
        }

        It 'declares Entra authority login.microsoftonline.com' {
            $script:p.EntraAuthority | Should -Be 'https://login.microsoftonline.com'
        }

        It 'declares storage suffix blob.core.windows.net' {
            $script:p.StorageSuffix | Should -Be 'blob.core.windows.net'
        }

        It 'supports Arc Gateway and automatic agent upgrade' {
            $script:p.SupportsArcGateway | Should -BeTrue
            $script:p.SupportsAutomaticAgentUpgrade | Should -BeTrue
        }

        It 'expects azcmagent cloud = AzureCloud' {
            $script:p.ExpectedAgentCloudValues | Should -Contain 'AzureCloud'
        }
    }

    Context 'AzureGovernmentDoD profile (per the endpoint table)' {
        BeforeAll {
            $script:p = InModuleScope ArcRemediator { Get-CloudProfile -Name 'AzureGovernmentDoD' }
        }

        It 'declares AzEnvironment = AzureUSGovernment' {
            $script:p.AzEnvironment | Should -Be 'AzureUSGovernment'
        }

        It 'declares ARM endpoint and resource for Azure Government' {
            $script:p.ArmEndpoint | Should -Be 'https://management.usgovcloudapi.net'
            $script:p.ArmTokenResource | Should -Be 'https://management.usgovcloudapi.net/'
        }

        It 'declares Monitor audience https://monitor.azure.us/.default' {
            $script:p.MonitorTokenScope | Should -Be 'https://monitor.azure.us/.default'
        }

        It 'declares Entra authority login.microsoftonline.us' {
            $script:p.EntraAuthority | Should -Be 'https://login.microsoftonline.us'
        }

        It 'declares storage suffix blob.core.usgovcloudapi.net' {
            $script:p.StorageSuffix | Should -Be 'blob.core.usgovcloudapi.net'
        }

        It 'does NOT support Arc Gateway (Azure-public-only per Microsoft Learn)' {
            $script:p.SupportsArcGateway | Should -BeFalse
        }

        It 'does NOT support automatic agent upgrade (Azure-public-only per Microsoft Learn)' {
            $script:p.SupportsAutomaticAgentUpgrade | Should -BeFalse
        }

        It 'expects azcmagent cloud = AzureUSGovernment' {
            $script:p.ExpectedAgentCloudValues | Should -Contain 'AzureUSGovernment'
        }
    }

    Context 'Unknown profiles' {
        It 'rejects unknown profile names via ValidateSet (no air-gapped, no China)' {
            InModuleScope ArcRemediator {
                { Get-CloudProfile -Name 'AzureChinaCloud' } | Should -Throw
                { Get-CloudProfile -Name 'AirGapped' } | Should -Throw
            }
        }
    }
}
