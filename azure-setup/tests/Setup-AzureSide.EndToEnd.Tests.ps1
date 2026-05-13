#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:TestsDir = Join-Path $script:RepoRoot 'azure-setup/tests'
    $script:DriverPath = Join-Path $script:RepoRoot 'azure-setup/Setup-AzureSide.ps1'

    . (Join-Path $script:TestsDir 'AzStubs.ps1')

    function script:Install-EndToEndMocks {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] [string]$ExpectedEnv,
            [Parameter(Mandatory)] [string]$StorageName,
            [Parameter(Mandatory)] [string]$StorageSuffix,
            [Parameter(Mandatory)] [string]$WorkspaceName,
            [Parameter(Mandatory)] [string]$CloudProfile,
            [Parameter(Mandatory)] [string]$IngestSubdomain
        )

        # Use process env-vars so the mock callbacks resolve them at fire time
        # regardless of Pester scope. Locals/script-scope vars set in
        # BeforeAll/BeforeEach are not always visible inside Mock { } in Pester 5.
        $env:T_E2E_EXPECTED_ENV = $ExpectedEnv
        $env:T_E2E_STORAGE_NAME = $StorageName
        $env:T_E2E_STORAGE_SUFFIX = $StorageSuffix
        $env:T_E2E_WORKSPACE_NAME = $WorkspaceName
        $env:T_E2E_CLOUD_PROFILE = $CloudProfile
        $env:T_E2E_INGEST_SUBDOMAIN = $IngestSubdomain
    }
}

Describe 'Setup-AzureSide end-to-end (mocked Az, both clouds)' {

    BeforeEach {
        # ---- Mock Az.* surface end-to-end ----
        Mock -CommandName Get-AzContext -MockWith {
            [PSCustomObject]@{
                Subscription = [PSCustomObject]@{ Id = '00000000-0000-0000-0000-000000000000' }
                Tenant = [PSCustomObject]@{ Id = '11111111-1111-1111-1111-111111111111' }
                Environment = [PSCustomObject]@{ Name = $env:T_E2E_EXPECTED_ENV }
            }
        }
        Mock Get-AzResourceProvider -MockWith {
            param($ProviderNamespace)
            [PSCustomObject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = 'Registered' }
        }
        Mock Register-AzResourceProvider {}
        Mock Get-AzADApplication -MockWith {
            param($DisplayName, $ApplicationId)
            [PSCustomObject]@{ AppId = "app-$DisplayName-mock" }
        }
        Mock New-AzADApplication {}
        Mock Get-AzADServicePrincipal -MockWith {
            param($ApplicationId)
            [PSCustomObject]@{ Id = "sp-obj-$ApplicationId" }
        }
        Mock New-AzADServicePrincipal {}
        Mock New-SelfSignedCertificate -MockWith {
            $obj = [PSCustomObject]@{
                Thumbprint = ('A' * 40)
                NotAfter = (Get-Date).AddDays(365)
            }
            $obj | Add-Member -MemberType ScriptMethod -Name GetRawCertData -Value { [byte[]](1..32) }
            $obj
        }
        Mock New-AzADAppCredential {}
        Mock Get-AzRoleAssignment -MockWith { $null }
        Mock New-AzRoleAssignment {}

        # Storage
        Mock Get-AzStorageAccount -MockWith {
            $name = $env:T_E2E_STORAGE_NAME
            [PSCustomObject]@{ StorageAccountName = $name; Context = [PSCustomObject]@{ StorageAccountName = $name } }
        }
        Mock New-AzStorageAccount {}
        Mock Get-AzStorageContainer -MockWith { [PSCustomObject]@{ Name = 'arc-remediator' } }
        Mock New-AzStorageContainer {}
        Mock Get-AzStorageBlob -MockWith { [PSCustomObject]@{ Name = 'kill-switch.txt' } }
        Mock Set-AzStorageBlobContent {}
        Mock Get-AzStorageContainerStoredAccessPolicy -MockWith {
            [PSCustomObject]@{ Policy = 'arc-remediator-readonly' }
        }
        Mock New-AzStorageContainerStoredAccessPolicy {}
        Mock New-AzStorageBlobSASToken -MockWith {
            'https://{0}.{1}/arc-remediator/kill-switch.txt?sig=fake&si=arc-remediator-readonly' -f `
                $env:T_E2E_STORAGE_NAME, $env:T_E2E_STORAGE_SUFFIX
        }

        # LAW + REST
        Mock Get-AzOperationalInsightsWorkspace -MockWith {
            $ws = $env:T_E2E_WORKSPACE_NAME
            [PSCustomObject]@{
                ResourceId = "/subscriptions/sub/resourceGroups/rg-arc-infra/providers/Microsoft.OperationalInsights/workspaces/$ws"
            }
        }
        Mock New-AzOperationalInsightsWorkspace {}
        Mock Invoke-AzRestMethod -MockWith {
            param($Path, $Method, $Payload)
            if ($Path -like '*/tables/ArcRemediation_CL*') {
                return [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
            }
            if ($Path -like '*/dataCollectionEndpoints/*') {
                if ($Method -eq 'GET') { return [PSCustomObject]@{ StatusCode = 404; Content = '' } }
                return [PSCustomObject]@{
                    StatusCode = 201
                    Content = '{"properties":{"logsIngestion":{"endpoint":"https://fake-dce.ingest.monitor.azure.com"}}}'
                }
            }
            if ($Path -like '*/dataCollectionRules/*') {
                $cp = $env:T_E2E_CLOUD_PROFILE
                $sub = $env:T_E2E_INGEST_SUBDOMAIN
                $url = 'https://fake-dcr.{0}.ingest.monitor.azure.com' -f $sub
                $json = '{{"properties":{{"immutableId":"dcr-imm-{0}","endpoints":{{"logsIngestion":"{1}"}}}}}}' -f $cp, $url
                return [PSCustomObject]@{ StatusCode = 200; Content = $json }
            }
            return [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
        }
    }

    Context 'Commercial' {
        It 'runs the full driver and emits a Commercial config' {
            Install-EndToEndMocks `
                -ExpectedEnv 'AzureCloud' `
                -StorageName 'arcmediator001' `
                -StorageSuffix 'blob.core.windows.net' `
                -WorkspaceName 'law-arc-commercial' `
                -CloudProfile 'Commercial' `
                -IngestSubdomain 'eastus-1'

            $tempConfig = Join-Path $TestDrive 'config.commercial.sample.json'

            $result = & $script:DriverPath `
                -CloudProfile 'Commercial' `
                -SubscriptionId '00000000-0000-0000-0000-000000000000' `
                -Location 'eastus' `
                -InfraResourceGroupName 'rg-arc-infra' `
                -ScopedArcResourceGroupName @('rg-arc-prod-1', 'rg-arc-prod-2') `
                -StorageAccountName 'arcmediator001' `
                -WorkspaceName 'law-arc-commercial' `
                -DcrName 'dcr-arc-commercial' `
                -ConfigOutputPath $tempConfig

            $result.CloudProfile | Should -Be 'Commercial'
            $result.Dcr.ImmutableId | Should -Be 'dcr-imm-Commercial'

            (Test-Path $tempConfig) | Should -BeTrue
            $config = (Get-Content -LiteralPath $tempConfig -Raw) | ConvertFrom-Json
            $config.CloudProfile | Should -Be 'Commercial'
            $config.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000000'
            $config.Mode | Should -Be 'Observe'
            $config.StreamName | Should -Be 'Custom-ArcRemediation'
            $config.DcrImmutableId | Should -Match 'Commercial'
            $config.KillSwitchUrl | Should -Match 'blob\.core\.windows\.net'
            $config.LogIngestionEndpoint | Should -Match 'ingest\.monitor\.azure\.com'
            @($config.ScopedResourceGroups).Count | Should -Be 2
        }
    }

    Context 'AzureGovernmentDoD (no Arc Gateway, no automatic upgrade)' {
        It 'emits a DoD config with ArcGatewayResourceId=null and EnableAutomaticAgentUpgrade=$false' {
            Install-EndToEndMocks `
                -ExpectedEnv 'AzureUSGovernment' `
                -StorageName 'arcmediatorgov01' `
                -StorageSuffix 'blob.core.usgovcloudapi.net' `
                -WorkspaceName 'law-arc-usgov' `
                -CloudProfile 'AzureGovernmentDoD' `
                -IngestSubdomain 'usgovvirginia-1'

            $tempConfig = Join-Path $TestDrive 'config.usgovdod.sample.json'

            $result = & $script:DriverPath `
                -CloudProfile 'AzureGovernmentDoD' `
                -SubscriptionId '22222222-2222-2222-2222-222222222222' `
                -Location 'usgovvirginia' `
                -InfraResourceGroupName 'rg-arc-infra-gov' `
                -ScopedArcResourceGroupName @('rg-arc-gov-1') `
                -StorageAccountName 'arcmediatorgov01' `
                -WorkspaceName 'law-arc-usgov' `
                -DcrName 'dcr-arc-usgov' `
                -ConfigOutputPath $tempConfig

            $result.CloudProfile | Should -Be 'AzureGovernmentDoD'

            $config = (Get-Content -LiteralPath $tempConfig -Raw) | ConvertFrom-Json
            $config.CloudProfile | Should -Be 'AzureGovernmentDoD'
            $config.ArcGatewayResourceId | Should -BeNullOrEmpty
            $config.EnableAutomaticAgentUpgrade | Should -BeFalse
            $config.KillSwitchUrl | Should -Match 'blob\.core\.usgovcloudapi\.net'
        }

        It 'fails closed if the Az context is the wrong cloud' {
            Install-EndToEndMocks `
                -ExpectedEnv 'AzureCloud' `
                -StorageName 'sa' `
                -StorageSuffix 'blob.core.windows.net' `
                -WorkspaceName 'law' `
                -CloudProfile 'AzureGovernmentDoD' `
                -IngestSubdomain 'eastus-1'

            $tempConfig = Join-Path $TestDrive 'config.usgovdod.wrong.json'

            { & $script:DriverPath `
                -CloudProfile 'AzureGovernmentDoD' `
                -SubscriptionId '22222222-2222-2222-2222-222222222222' `
                -Location 'usgovvirginia' `
                -InfraResourceGroupName 'rg-x' `
                -ScopedArcResourceGroupName @('rg-x') `
                -StorageAccountName 'sa' `
                -WorkspaceName 'law' `
                -DcrName 'dcr' `
                -ConfigOutputPath $tempConfig } |
                Should -Throw -ExpectedMessage '*AzureCloud*does not match*AzureGovernmentDoD*'
        }
    }
}
