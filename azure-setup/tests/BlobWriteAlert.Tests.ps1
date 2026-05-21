#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:PrivateDir = Join-Path $script:RepoRoot 'azure-setup/private'
    $script:StubsPath = Join-Path $PSScriptRoot 'AzStubs.ps1'

    # Dot-source stubs first so Pester can Mock them.
    . $script:StubsPath

    # Dot-source all private helpers.
    Get-ChildItem -Path $script:PrivateDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'New-BlobWriteAlert' {

    BeforeEach {
        Mock Get-AzStorageAccount {
            return [PSCustomObject]@{
                Id = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/sa1'
            }
        }
        Mock Set-AzDiagnosticSetting { }
        Mock New-AzScheduledQueryRuleCriteria { return [PSCustomObject]@{ Query=''; TimeAggregation='Count' } }
        Mock New-AzScheduledQueryRule {
            return [PSCustomObject]@{
                Id   = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Insights/scheduledQueryRules/arc-remediator-blob-write-alert'
                Name = 'arc-remediator-blob-write-alert'
            }
        }
    }

    Context 'Successful creation' {
        It 'calls Set-AzDiagnosticSetting with StorageWrite and StorageRead categories' {
            $params = @{
                StorageAccountResourceId = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/sa1'
                WorkspaceResourceId      = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.OperationalInsights/workspaces/ws1'
                ResourceGroupName        = 'rg-1'
                Location                 = 'eastus'
                SubscriptionId           = 'sub-1'
            }
            New-BlobWriteAlert @params
            Assert-MockCalled Set-AzDiagnosticSetting -Exactly 1 -ParameterFilter {
                $Name -eq 'ArcRemediator-BlobAudit'
            }
        }

        It 'calls New-AzScheduledQueryRule with severity 1' {
            $params = @{
                StorageAccountResourceId = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/sa1'
                WorkspaceResourceId      = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.OperationalInsights/workspaces/ws1'
                ResourceGroupName        = 'rg-1'
                Location                 = 'eastus'
                SubscriptionId           = 'sub-1'
            }
            New-BlobWriteAlert @params
            Assert-MockCalled New-AzScheduledQueryRule -Exactly 1 -ParameterFilter {
                $Severity -eq 1
            }
        }

        It 'returns an object with AlertRuleName and DiagnosticSettingName' {
            $params = @{
                StorageAccountResourceId = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/sa1'
                WorkspaceResourceId      = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.OperationalInsights/workspaces/ws1'
                ResourceGroupName        = 'rg-1'
                Location                 = 'eastus'
                SubscriptionId           = 'sub-1'
            }
            $r = New-BlobWriteAlert @params
            $r.AlertRuleName | Should -Be 'arc-remediator-blob-write-alert'
            $r.DiagnosticSettingName | Should -Be 'ArcRemediator-BlobAudit'
        }

        It 'uses custom blob names when supplied' {
            $capturedQuery = $null
            Mock New-AzScheduledQueryRuleCriteria {
                $script:capturedQuery = $Query
                return [PSCustomObject]@{ Query=$Query }
            }
            $params = @{
                StorageAccountResourceId = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/sa1'
                WorkspaceResourceId      = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.OperationalInsights/workspaces/ws1'
                ResourceGroupName        = 'rg-1'
                Location                 = 'eastus'
                SubscriptionId           = 'sub-1'
                KillSwitchBlobName       = 'my-kill.txt'
                BreakerResetBlobName     = 'my-reset.txt'
            }
            New-BlobWriteAlert @params
            $script:capturedQuery | Should -Match 'my-kill.txt'
            $script:capturedQuery | Should -Match 'my-reset.txt'
        }
    }

    Context 'Diagnostic setting fallback to az cli' {
        It 'does not throw when Set-AzDiagnosticSetting fails and az cli succeeds' {
            Mock Set-AzDiagnosticSetting { throw 'Az cmdlet not available' }
            Mock New-AzScheduledQueryRule { return [PSCustomObject]@{ Id='x'; Name='arc-remediator-blob-write-alert' } }

            # Stub az cli global command — redirect to a no-op function.
            $script:azCalled = $false
            function script:az { $script:azCalled = $true; $global:LASTEXITCODE = 0 }

            $params = @{
                StorageAccountResourceId = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/sa1'
                WorkspaceResourceId      = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.OperationalInsights/workspaces/ws1'
                ResourceGroupName        = 'rg-1'
                Location                 = 'eastus'
                SubscriptionId           = 'sub-1'
            }
            { New-BlobWriteAlert @params } | Should -Not -Throw
        }
    }
}
