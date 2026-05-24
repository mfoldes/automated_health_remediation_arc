#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:PrivateDir = Join-Path $script:RepoRoot 'azure-setup/private'
    $script:TestsDir = Join-Path $script:RepoRoot 'azure-setup/tests'

    . (Join-Path $script:TestsDir 'AzStubs.ps1')
    . (Join-Path $script:PrivateDir 'New-DirectDcr.ps1')
    . (Join-Path $script:PrivateDir 'Test-DcrReuse.ps1')
    . (Join-Path $script:PrivateDir 'New-OptionalDce.ps1')
    . (Join-Path $script:PrivateDir 'Set-DcrMetricsPublisher.ps1')

    $script:Subscription = '00000000-0000-0000-0000-000000000000'
    $script:ResourceGroup = 'rg-arc-mvp'
    $script:WorkspaceId = "/subscriptions/$script:Subscription/resourceGroups/$script:ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/law-arc"

    function Test-DcrReuse_HappyResponse {
        param([bool]$WithLogs = $true, [bool]$WithDce = $false, [string]$DceId = $null)

        $props = @{ immutableId = 'dcr-immutable-xyz' }
        if ($WithLogs) {
            $props.endpoints = @{ logsIngestion = 'https://arc-dcr-1234.eastus-1.ingest.monitor.azure.com' }
        }
        if ($WithDce) {
            $props.dataCollectionEndpointId = $DceId
        }

        @{
            properties = $props
        } | ConvertTo-Json -Depth 10
    }
}

Describe 'New-DirectDcr' {

    BeforeEach {
        Mock -CommandName Get-AzContext -MockWith {
            [PSCustomObject]@{
                Subscription = [PSCustomObject]@{ Id = $script:Subscription }
            }
        }
    }

    Context 'PUT payload shape' {
        It "sends kind=Direct at the resource root and a transformKql projecting TimeGenerated from EventTimeUtc" {
            $script:capturedPayload = $null
            Mock -CommandName Invoke-AzRestMethod -MockWith {
                param($Path, $Method, $Payload)
                $script:capturedPayload = $Payload
                [PSCustomObject]@{
                    StatusCode = 200
                    Content = '{"properties":{"immutableId":"dcr-imm-1","endpoints":{"logsIngestion":"https://x.eastus-1.ingest.monitor.azure.com"}}}'
                }
            }

            $null = New-DirectDcr `
                -ResourceGroupName $script:ResourceGroup `
                -DcrName 'dcr-arc' `
                -Location 'eastus' `
                -WorkspaceResourceId $script:WorkspaceId

            $obj = $script:capturedPayload | ConvertFrom-Json
            $obj.kind | Should -Be 'Direct'
            $obj.properties.streamDeclarations.'Custom-ArcRemediation' | Should -Not -BeNullOrEmpty
            $obj.properties.dataFlows[0].outputStream | Should -Be 'Custom-ArcRemediation_CL'
            $obj.properties.dataFlows[0].streams[0] | Should -Be 'Custom-ArcRemediation'
            $obj.properties.dataFlows[0].transformKql | Should -Match 'TimeGenerated\s*=\s*EventTimeUtc'
        }

        It 'targets api-version=2024-03-11 and PUTs to Microsoft.Insights/dataCollectionRules/{name}' {
            Mock -CommandName Invoke-AzRestMethod -MockWith {
                [PSCustomObject]@{
                    StatusCode = 200
                    Content = '{"properties":{"immutableId":"dcr-imm-2","endpoints":{"logsIngestion":"https://x"}}}'
                }
            }

            $null = New-DirectDcr `
                -ResourceGroupName $script:ResourceGroup `
                -DcrName 'dcr-arc' `
                -Location 'eastus' `
                -WorkspaceResourceId $script:WorkspaceId

            Assert-MockCalled Invoke-AzRestMethod -Scope It -ParameterFilter {
                $Method -eq 'PUT' -and
                $Path -like '*/Microsoft.Insights/dataCollectionRules/dcr-arc*' -and
                $Path -like '*api-version=2024-03-11*'
            }
        }
    }

    Context 'Fails closed when kind:Direct is not honored' {
        It 'throws when the response is missing properties.endpoints.logsIngestion' {
            Mock -CommandName Invoke-AzRestMethod -MockWith {
                [PSCustomObject]@{
                    StatusCode = 200
                    Content = '{"properties":{"immutableId":"dcr-imm-no-endpoint"}}'
                }
            }

            { New-DirectDcr `
                -ResourceGroupName $script:ResourceGroup `
                -DcrName 'dcr-missing-endpoint' `
                -Location 'eastus' `
                -WorkspaceResourceId $script:WorkspaceId } |
                Should -Throw -ExpectedMessage '*missing*properties.endpoints.logsIngestion*'
        }

        It 'throws on non-2xx PUT' {
            Mock -CommandName Invoke-AzRestMethod -MockWith {
                [PSCustomObject]@{ StatusCode = 400; Content = '{"error":"bad-region"}' }
            }
            { New-DirectDcr `
                -ResourceGroupName $script:ResourceGroup `
                -DcrName 'dcr-bad' `
                -Location 'eastus' `
                -WorkspaceResourceId $script:WorkspaceId } |
                Should -Throw -ExpectedMessage '*HTTP 400*'
        }
    }
}

Describe 'Test-DcrReuse' {

    It 'returns Exists=$false on HTTP 404' {
        Mock -CommandName Invoke-AzRestMethod -MockWith {
            [PSCustomObject]@{ StatusCode = 404; Content = '' }
        }
        $result = Test-DcrReuse -DcrResourceId '/subscriptions/x/resourceGroups/x/providers/Microsoft.Insights/dataCollectionRules/missing'
        $result.Exists | Should -BeFalse
    }

    It 'reports HasLogsIngestion when properties.endpoints.logsIngestion is set' {
        Mock -CommandName Invoke-AzRestMethod -MockWith {
            [PSCustomObject]@{
                StatusCode = 200
                Content = (Test-DcrReuse_HappyResponse -WithLogs $true)
            }
        }
        $result = Test-DcrReuse -DcrResourceId '/subscriptions/x/resourceGroups/x/providers/Microsoft.Insights/dataCollectionRules/has-logs'
        $result.HasLogsIngestion | Should -BeTrue
        $result.Endpoint | Should -Match 'ingest.monitor.azure.com'
    }

    It 'falls back to the DCE endpoint when logsIngestion is absent but DCE is associated' {
        $script:callCount = 0
        Mock -CommandName Invoke-AzRestMethod -MockWith {
            param($Path, $Method)
            $script:callCount++
            if ($Path -like '*dataCollectionRules/*') {
                [PSCustomObject]@{
                    StatusCode = 200
                    Content = (Test-DcrReuse_HappyResponse -WithLogs $false -WithDce $true -DceId '/subscriptions/x/resourceGroups/x/providers/Microsoft.Insights/dataCollectionEndpoints/dce-1')
                }
            } else {
                # DCE GET
                [PSCustomObject]@{
                    StatusCode = 200
                    Content = '{"properties":{"logsIngestion":{"endpoint":"https://dce-1.eastus-1.ingest.monitor.azure.com"}}}'
                }
            }
        }
        $result = Test-DcrReuse -DcrResourceId '/subscriptions/x/resourceGroups/x/providers/Microsoft.Insights/dataCollectionRules/dce-backed'
        $result.HasLogsIngestion | Should -BeFalse
        $result.HasDce | Should -BeTrue
        $result.Endpoint | Should -Be 'https://dce-1.eastus-1.ingest.monitor.azure.com'
    }

    It 'reports neither when DCR exists but has no logsIngestion and no DCE (driver must replace or fail)' {
        Mock -CommandName Invoke-AzRestMethod -MockWith {
            [PSCustomObject]@{
                StatusCode = 200
                Content = (Test-DcrReuse_HappyResponse -WithLogs $false -WithDce $false)
            }
        }
        $result = Test-DcrReuse -DcrResourceId '/subscriptions/x/resourceGroups/x/providers/Microsoft.Insights/dataCollectionRules/stale'
        $result.HasLogsIngestion | Should -BeFalse
        $result.HasDce | Should -BeFalse
        $result.Endpoint | Should -BeNullOrEmpty
    }
}

Describe 'New-OptionalDce' {

    BeforeEach {
        Mock -CommandName Get-AzContext -MockWith {
            [PSCustomObject]@{
                Subscription = [PSCustomObject]@{ Id = $script:Subscription }
            }
        }
    }

    It 'reuses an existing DCE (no second PUT)' {
        $script:putCount = 0
        Mock -CommandName Invoke-AzRestMethod -MockWith {
            param($Path, $Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{
                    StatusCode = 200
                    Content = '{"properties":{"logsIngestion":{"endpoint":"https://existing-dce.eastus.ingest.monitor.azure.com"}}}'
                }
            } else {
                $script:putCount++
                [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
            }
        }
        $result = New-OptionalDce -ResourceGroupName $script:ResourceGroup -DceName 'dce-existing' -Location 'eastus'
        $script:putCount | Should -Be 0
        $result.LogsIngestionUrl | Should -Match 'existing-dce'
    }

    It 'PUTs a new DCE with api-version=2024-03-11 when missing' {
        $script:capturedMethod = $null
        Mock -CommandName Invoke-AzRestMethod -MockWith {
            param($Path, $Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ StatusCode = 404; Content = '' }
            } else {
                $script:capturedMethod = $Method
                if ($Path -notlike '*api-version=2024-03-11*') {
                    throw "wrong api-version: $Path"
                }
                [PSCustomObject]@{
                    StatusCode = 201
                    Content = '{"properties":{"logsIngestion":{"endpoint":"https://new-dce.eastus.ingest.monitor.azure.com"}}}'
                }
            }
        }
        $result = New-OptionalDce -ResourceGroupName $script:ResourceGroup -DceName 'dce-new' -Location 'eastus'
        $script:capturedMethod | Should -Be 'PUT'
        $result.LogsIngestionUrl | Should -Match 'new-dce'
    }
}

Describe 'Set-DcrMetricsPublisher' {

    It 'uses the Monitoring Metrics Publisher role ID (3913510d-...)' {
        Mock -CommandName Get-AzRoleAssignment -MockWith { $null }
        Mock -CommandName New-AzRoleAssignment {}

        Set-DcrMetricsPublisher `
            -DcrResourceId '/subscriptions/x/resourceGroups/x/providers/Microsoft.Insights/dataCollectionRules/dcr' `
            -LogsIngestionSpObjectId 'sp-logs-1'

        Assert-MockCalled New-AzRoleAssignment -Scope It -ParameterFilter {
            $RoleDefinitionId -eq '3913510d-42f4-4e42-8a64-420c390055eb'
        }
    }

    It 'scopes the assignment to the DCR resource (not subscription)' {
        Mock -CommandName Get-AzRoleAssignment -MockWith { $null }
        Mock -CommandName New-AzRoleAssignment {}

        Set-DcrMetricsPublisher `
            -DcrResourceId '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Insights/dataCollectionRules/dcr' `
            -LogsIngestionSpObjectId 'sp-logs-2'

        Assert-MockCalled New-AzRoleAssignment -Scope It -ParameterFilter {
            $Scope -eq '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Insights/dataCollectionRules/dcr'
        }
    }

    It 'skips when an assignment already exists' {
        Mock -CommandName Get-AzRoleAssignment -MockWith {
            [PSCustomObject]@{ RoleAssignmentId = 'existing' }
        }
        Mock -CommandName New-AzRoleAssignment {}

        Set-DcrMetricsPublisher `
            -DcrResourceId '/subscriptions/x/resourceGroups/x/providers/Microsoft.Insights/dataCollectionRules/dcr' `
            -LogsIngestionSpObjectId 'sp-logs-3'

        Assert-MockCalled New-AzRoleAssignment -Times 0 -Scope It
    }
}
