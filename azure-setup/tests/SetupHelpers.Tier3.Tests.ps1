#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:PrivateDir = Join-Path $script:RepoRoot 'azure-setup/private'
    $script:TestsDir = Join-Path $script:RepoRoot 'azure-setup/tests'

    . (Join-Path $script:TestsDir 'AzStubs.ps1')
    . (Join-Path $script:PrivateDir 'New-KillSwitchInfra.ps1')
    . (Join-Path $script:PrivateDir 'New-LawAndTable.ps1')
}

Describe 'New-KillSwitchInfra' {

    BeforeEach {
        # Common storage context object the helper reads as $sa.Context.
        $script:fakeCtx = [PSCustomObject]@{ StorageAccountName = 'satest' }
    }

    Context 'Storage account create vs reuse' {
        It 'skips New-AzStorageAccount when an account exists' {
            Mock -CommandName Get-AzStorageAccount -MockWith {
                [PSCustomObject]@{ StorageAccountName = 'satest'; Context = $script:fakeCtx }
            }
            Mock -CommandName New-AzStorageAccount {}
            Mock -CommandName Get-AzStorageContainer -MockWith { [PSCustomObject]@{ Name = 'arc-remediator' } }
            Mock -CommandName New-AzStorageContainer {}
            Mock -CommandName Get-AzStorageBlob -MockWith { [PSCustomObject]@{ Name = 'kill-switch.txt' } }
            Mock -CommandName Set-AzStorageBlobContent {}
            Mock -CommandName Get-AzStorageContainerStoredAccessPolicy -MockWith {
                [PSCustomObject]@{ Policy = 'arc-remediator-readonly' }
            }
            Mock -CommandName New-AzStorageContainerStoredAccessPolicy {}
            Mock -CommandName New-AzStorageBlobSASToken -MockWith {
                'https://satest.blob.core.windows.net/arc-remediator/kill-switch.txt?sig=fake&se=...'
            }

            $null = New-KillSwitchInfra `
                -ResourceGroupName 'rg-arc' -StorageAccountName 'satest' -Location 'eastus'

            Assert-MockCalled New-AzStorageAccount -Times 0 -Scope It
        }

        It 'creates the account with MinimumTlsVersion TLS1_2 and AllowBlobPublicAccess $false' {
            Mock -CommandName Get-AzStorageAccount -MockWith { $null }
            Mock -CommandName New-AzStorageAccount -MockWith {
                [PSCustomObject]@{ StorageAccountName = 'satest'; Context = $script:fakeCtx }
            }
            Mock -CommandName Get-AzStorageContainer -MockWith { $null }
            Mock -CommandName New-AzStorageContainer {}
            Mock -CommandName Get-AzStorageBlob -MockWith { $null }
            Mock -CommandName Set-AzStorageBlobContent {}
            Mock -CommandName Get-AzStorageContainerStoredAccessPolicy -MockWith { @() }
            Mock -CommandName New-AzStorageContainerStoredAccessPolicy {}
            Mock -CommandName New-AzStorageBlobSASToken -MockWith { 'https://satest.blob.core.windows.net/arc-remediator/kill-switch.txt?sig=fake' }

            $null = New-KillSwitchInfra `
                -ResourceGroupName 'rg-arc' -StorageAccountName 'satest' -Location 'eastus'

            Assert-MockCalled New-AzStorageAccount -Scope It -ParameterFilter {
                $MinimumTlsVersion -eq 'TLS1_2' -and $AllowBlobPublicAccess -eq $false
            }
        }
    }

    Context 'Container privacy + blob seeding' {
        BeforeEach {
            Mock -CommandName Get-AzStorageAccount -MockWith {
                [PSCustomObject]@{ StorageAccountName = 'satest'; Context = $script:fakeCtx }
            }
            Mock -CommandName Get-AzStorageContainer -MockWith { $null }
            Mock -CommandName Get-AzStorageBlob -MockWith { $null }
            Mock -CommandName Get-AzStorageContainerStoredAccessPolicy -MockWith { @() }
            Mock -CommandName New-AzStorageContainerStoredAccessPolicy {}
            Mock -CommandName New-AzStorageBlobSASToken -MockWith { 'https://satest.blob.core.windows.net/arc-remediator/kill-switch.txt?sig=fake' }
            Mock -CommandName Set-AzStorageBlobContent {}
        }

        It 'creates the container with Permission Off (private)' {
            Mock -CommandName New-AzStorageContainer {}
            $null = New-KillSwitchInfra -ResourceGroupName 'rg' -StorageAccountName 'satest' -Location 'eastus'
            Assert-MockCalled New-AzStorageContainer -Scope It -ParameterFilter { $Permission -eq 'Off' }
        }

        It "seeds the blob with the literal text 'enabled' (no trailing newline)" {
            Mock -CommandName New-AzStorageContainer {}
            $script:seedFile = $null
            Mock -CommandName Set-AzStorageBlobContent -MockWith {
                param($File, $Container, $Blob, $Context)
                $script:seedFile = (Get-Content -LiteralPath $File -Raw)
            } -ParameterFilter { $true }

            $null = New-KillSwitchInfra -ResourceGroupName 'rg' -StorageAccountName 'satest' -Location 'eastus'

            $script:seedFile | Should -Be 'enabled'
        }
    }

    Context 'SAS' {
        It 'returns a KillSwitchUrl backed by the stored access policy' {
            Mock -CommandName Get-AzStorageAccount -MockWith {
                [PSCustomObject]@{ StorageAccountName = 'satest'; Context = $script:fakeCtx }
            }
            Mock -CommandName Get-AzStorageContainer -MockWith { [PSCustomObject]@{ Name = 'arc-remediator' } }
            Mock -CommandName Get-AzStorageBlob -MockWith { [PSCustomObject]@{ Name = 'kill-switch.txt' } }
            Mock -CommandName Get-AzStorageContainerStoredAccessPolicy -MockWith {
                [PSCustomObject]@{ Policy = 'arc-remediator-readonly' }
            }
            Mock -CommandName New-AzStorageBlobSASToken -MockWith {
                'https://satest.blob.core.windows.net/arc-remediator/kill-switch.txt?sig=fake&sp=r&si=arc-remediator-readonly'
            }

            $result = New-KillSwitchInfra -ResourceGroupName 'rg' -StorageAccountName 'satest' -Location 'eastus'

            $result.KillSwitchUrl | Should -Match 'arc-remediator/kill-switch\.txt\?'
            $result.AccessPolicyName | Should -Be 'arc-remediator-readonly'
            Assert-MockCalled New-AzStorageBlobSASToken -Scope It -ParameterFilter {
                $Policy -eq 'arc-remediator-readonly' -and $FullUri.IsPresent
            }
        }
    }
}

Describe 'New-LawAndTable' {

    BeforeEach {
        Mock -CommandName Get-AzContext -MockWith {
            [PSCustomObject]@{
                Subscription = [PSCustomObject]@{ Id = '00000000-0000-0000-0000-000000000000' }
                Environment = [PSCustomObject]@{ Name = 'AzureCloud' }
            }
        }
    }

    Context 'Workspace create vs reuse' {
        It 'skips New-AzOperationalInsightsWorkspace when one exists' {
            Mock -CommandName Get-AzOperationalInsightsWorkspace -MockWith {
                [PSCustomObject]@{ ResourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law-arc' }
            }
            Mock -CommandName New-AzOperationalInsightsWorkspace {}
            Mock -CommandName Invoke-AzRestMethod -MockWith { [PSCustomObject]@{ StatusCode = 200; Content = '' } }

            $null = New-LawAndTable -ResourceGroupName 'rg' -WorkspaceName 'law-arc' -Location 'eastus'

            Assert-MockCalled New-AzOperationalInsightsWorkspace -Times 0 -Scope It
        }

        It 'creates the workspace with SKU PerGB2018 when none exists' {
            Mock -CommandName Get-AzOperationalInsightsWorkspace -MockWith { $null }
            Mock -CommandName New-AzOperationalInsightsWorkspace -MockWith {
                [PSCustomObject]@{ ResourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law-arc' }
            }
            Mock -CommandName Invoke-AzRestMethod -MockWith { [PSCustomObject]@{ StatusCode = 200; Content = '' } }

            $null = New-LawAndTable -ResourceGroupName 'rg' -WorkspaceName 'law-arc' -Location 'eastus'

            Assert-MockCalled New-AzOperationalInsightsWorkspace -Scope It -ParameterFilter {
                $Sku -eq 'PerGB2018'
            }
        }
    }

    Context 'Custom table PUT' {
        It 'targets /providers/Microsoft.OperationalInsights/workspaces/.../tables/ArcRemediation_CL' {
            Mock -CommandName Get-AzOperationalInsightsWorkspace -MockWith {
                [PSCustomObject]@{ ResourceId = 'fake-ws-id' }
            }
            Mock -CommandName Invoke-AzRestMethod -MockWith { [PSCustomObject]@{ StatusCode = 200; Content = '' } }

            $null = New-LawAndTable -ResourceGroupName 'rg-arc' -WorkspaceName 'law-arc' -Location 'eastus' -SubscriptionId '11111111-1111-1111-1111-111111111111'

            Assert-MockCalled Invoke-AzRestMethod -Scope It -ParameterFilter {
                $Method -eq 'PUT' -and
                $Path -like '*/Microsoft.OperationalInsights/workspaces/law-arc/tables/ArcRemediation_CL*' -and
                $Path -like '*api-version=2023-09-01*'
            }
        }

        It "payload schema includes TimeGenerated and EventTimeUtc as datetime columns" {
            Mock -CommandName Get-AzOperationalInsightsWorkspace -MockWith {
                [PSCustomObject]@{ ResourceId = 'fake-ws-id' }
            }
            $script:capturedPayload = $null
            Mock -CommandName Invoke-AzRestMethod -MockWith {
                param($Path, $Method, $Payload)
                $script:capturedPayload = $Payload
                [PSCustomObject]@{ StatusCode = 200; Content = '' }
            }

            $null = New-LawAndTable -ResourceGroupName 'rg-arc' -WorkspaceName 'law-arc' -Location 'eastus' -SubscriptionId '11111111-1111-1111-1111-111111111111'

            $obj = $script:capturedPayload | ConvertFrom-Json
            $colNames = @($obj.properties.schema.columns | ForEach-Object { $_.name })
            $colNames | Should -Contain 'TimeGenerated'
            $colNames | Should -Contain 'EventTimeUtc'
            $colNames | Should -Contain 'Outcome'
            $colNames | Should -Contain 'AzureSideState'
            $colNames | Should -Contain 'BreakerTripped'
        }

        It 'throws when the table PUT returns 4xx/5xx' {
            Mock -CommandName Get-AzOperationalInsightsWorkspace -MockWith {
                [PSCustomObject]@{ ResourceId = 'fake-ws-id' }
            }
            Mock -CommandName Invoke-AzRestMethod -MockWith {
                [PSCustomObject]@{ StatusCode = 403; Content = '{"error":"forbidden"}' }
            }

            { New-LawAndTable -ResourceGroupName 'rg' -WorkspaceName 'law-arc' -Location 'eastus' -SubscriptionId 'sub' } |
                Should -Throw -ExpectedMessage '*HTTP 403*'
        }
    }
}
