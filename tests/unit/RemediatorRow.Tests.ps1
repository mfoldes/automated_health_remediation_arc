#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Get-ScriptVersion' {
    It 'reads Data/version.txt' {
        InModuleScope ArcRemediator {
            $v = Get-ScriptVersion
            $v | Should -Not -BeNullOrEmpty
            [version]$v | Should -BeOfType ([version])
        }
    }
}

Describe 'ConvertTo-RemediatorExitCode' {

    Context 'Success bucket (exit 0)' {
        It '<outcome> maps to exit 0' -ForEach @(
            @{ outcome = 'Healthy' }
            @{ outcome = 'FleetPaused' }
            @{ outcome = 'MachinePaused' }
            @{ outcome = 'ObserveOnly' }
            @{ outcome = 'CooldownSkipped' }
            @{ outcome = 'ServicesRepaired' }
            @{ outcome = 'ConnectivityBlocked' }
            @{ outcome = 'NeedsHuman' }
            @{ outcome = 'BreakerTripped' }
            @{ outcome = 'ResourceNotFound' }
            @{ outcome = 'ExpiredRejoinSuccess' }
        ) {
            InModuleScope ArcRemediator -Parameters @{ o = $outcome } {
                param($o)
                (ConvertTo-RemediatorExitCode -Outcome $o) | Should -Be 0
            }
        }
    }

    Context 'Failure buckets' {
        It 'ExpiredRejoinFailure -> 1' { InModuleScope ArcRemediator { (ConvertTo-RemediatorExitCode -Outcome 'ExpiredRejoinFailure') | Should -Be 1 } }
        It 'AuthFailure -> 2' { InModuleScope ArcRemediator { (ConvertTo-RemediatorExitCode -Outcome 'AuthFailure') | Should -Be 2 } }
        It 'ArmForbidden -> 2' { InModuleScope ArcRemediator { (ConvertTo-RemediatorExitCode -Outcome 'ArmForbidden') | Should -Be 2 } }
        It 'ConfigMismatch -> 2' { InModuleScope ArcRemediator { (ConvertTo-RemediatorExitCode -Outcome 'ConfigMismatch') | Should -Be 2 } }
        It 'AzureMachineError -> 2' { InModuleScope ArcRemediator { (ConvertTo-RemediatorExitCode -Outcome 'AzureMachineError') | Should -Be 2 } }
        It 'ArmThrottled -> 3' { InModuleScope ArcRemediator { (ConvertTo-RemediatorExitCode -Outcome 'ArmThrottled') | Should -Be 3 } }
        It 'ArmTransientFailure -> 3' { InModuleScope ArcRemediator { (ConvertTo-RemediatorExitCode -Outcome 'ArmTransientFailure') | Should -Be 3 } }
        It 'Error -> 4' { InModuleScope ArcRemediator { (ConvertTo-RemediatorExitCode -Outcome 'Error') | Should -Be 4 } }
        It 'unknown outcome -> 4' { InModuleScope ArcRemediator { (ConvertTo-RemediatorExitCode -Outcome 'NonsenseOutcome') | Should -Be 4 } }
    }

    Context 'Secondary-only LAW ingestion failure' {
        It 'LogIngestionFailure alone -> 0 (exit follows primary)' {
            InModuleScope ArcRemediator {
                (ConvertTo-RemediatorExitCode -Outcome 'LogIngestionFailure' -LogIngestionOnlyFailed) | Should -Be 0
            }
        }
        It 'LogIngestionFailure WITHOUT -LogIngestionOnlyFailed -> 0 (still maps to success by design)' {
            InModuleScope ArcRemediator {
                (ConvertTo-RemediatorExitCode -Outcome 'LogIngestionFailure') | Should -Be 0
            }
        }
    }
}

Describe 'New-RemediatorRow' {

    Context 'Spec 10.2 column shape' {
        It 'emits all required columns with sensible defaults' {
            InModuleScope ArcRemediator {
                $row = New-RemediatorRow -EventTimeUtc ([datetime]::Parse('2026-05-12T01:23:45Z')).ToUniversalTime() `
                    -CloudProfile 'Commercial' -ScriptMode 'Observe' -Outcome 'Healthy' `
                    -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -MachineName 'm-1' `
                    -RunDurationMs 1234
                $row['CloudProfile'] | Should -Be 'Commercial'
                $row['ScriptMode'] | Should -Be 'Observe'
                $row['Outcome'] | Should -Be 'Healthy'
                $row['SubscriptionId'] | Should -Be 'sub-1'
                $row['ResourceGroup'] | Should -Be 'rg-1'
                $row['EventTimeUtc'] | Should -Match '^2026-05-12T01:23:45'
                $row['Hostname'] | Should -Not -BeNullOrEmpty
                $row['Fqdn'] | Should -Not -BeNullOrEmpty
                $row['ScriptVersion'] | Should -Not -BeNullOrEmpty
                $row['RunDurationMs'] | Should -Be 1234
                @($row['ActionsAttempted']).Count | Should -Be 0
                @($row['ActionsSuccessful']).Count | Should -Be 0
                $row['BreakerTripped'] | Should -BeFalse
                $row['ConsecutiveFailures'] | Should -Be 0
                $row['SchemaVersion'] | Should -Be '1'
            }
        }
    }

    Context 'Region comes from the resource location, NOT the agent version (regression)' {
        It 'pulls Region from ResourceState.Location, not AgentVersion' {
            InModuleScope ArcRemediator {
                $state = [PSCustomObject]@{ Classification='Connected'; StatusCode=200; ETag='W/"x"'; Tags=$null; Location='westus2'; Name='m'; Raw=$null; ErrorMessage=$null }
                $cs = [PSCustomObject]@{ AgentVersion='1.45.0'; AgentStatus='Connected'; Location='eastus' }
                $row = New-RemediatorRow -EventTimeUtc ([datetime]::UtcNow) `
                    -CloudProfile 'Commercial' -ScriptMode 'Observe' -Outcome 'Healthy' `
                    -ResourceState $state -ConnectivitySettings $cs
                $row['Region'] | Should -Be 'westus2'
                $row['Region'] | Should -Not -Be '1.45.0'
                $row['AgentVersion'] | Should -Be '1.45.0'
            }
        }

        It 'falls back to ConnectivitySettings.Location when ResourceState is null' {
            InModuleScope ArcRemediator {
                $cs = [PSCustomObject]@{ AgentVersion='1.45.0'; AgentStatus='Connected'; Location='eastus'; ResourceGroupName='rg-cs' }
                $row = New-RemediatorRow -EventTimeUtc ([datetime]::UtcNow) `
                    -CloudProfile 'Commercial' -ScriptMode 'Observe' -Outcome 'Healthy' `
                    -ConnectivitySettings $cs
                $row['Region'] | Should -Be 'eastus'
                $row['ResourceGroup'] | Should -Be 'rg-cs'
            }
        }
    }

    Context 'AzureResourceId synthesis' {
        It 'pulls AzureResourceId from ResourceState.Raw.id when present' {
            InModuleScope ArcRemediator {
                $raw = [PSCustomObject]@{ id = '/subscriptions/SS/resourceGroups/RG/providers/Microsoft.HybridCompute/machines/MM' }
                $state = [PSCustomObject]@{ Classification='Connected'; StatusCode=200; ETag='W/"x"'; Tags=$null; Location='eastus'; Name='MM'; Raw=$raw; ErrorMessage=$null }
                $row = New-RemediatorRow -EventTimeUtc ([datetime]::UtcNow) `
                    -CloudProfile 'Commercial' -ScriptMode 'Observe' -Outcome 'Healthy' -ResourceState $state
                $row['AzureResourceId'] | Should -Be '/subscriptions/SS/resourceGroups/RG/providers/Microsoft.HybridCompute/machines/MM'
            }
        }

        It 'synthesizes AzureResourceId from sub/RG/name when ResourceState is absent' {
            InModuleScope ArcRemediator {
                $row = New-RemediatorRow -EventTimeUtc ([datetime]::UtcNow) `
                    -CloudProfile 'Commercial' -ScriptMode 'Observe' -Outcome 'Healthy' `
                    -SubscriptionId 'sub-x' -ResourceGroupName 'rg-x' -MachineName 'm-x'
                $row['AzureResourceId'] | Should -Be '/subscriptions/sub-x/resourceGroups/rg-x/providers/Microsoft.HybridCompute/machines/m-x'
            }
        }
    }

    Context 'Error message truncation + stack trace hashing' {
        It 'truncates ErrorMessage to MaxErrorChars and hashes the StackTrace' {
            InModuleScope ArcRemediator {
                $longErr = 'X' * 5000
                $row = New-RemediatorRow -EventTimeUtc ([datetime]::UtcNow) `
                    -CloudProfile 'Commercial' -ScriptMode 'Observe' -Outcome 'Error' `
                    -ErrorMessage $longErr -LocalStackTrace ($longErr * 2) -MaxErrorChars 200
                $row['ErrorMessage'].Length | Should -BeLessThan 220
                $row['ErrorMessage'] | Should -Match '\[truncated\]'
                $row['StackTraceHash'] | Should -Match '^[0-9a-f]{64}$'
            }
        }

        It 'leaves short ErrorMessage as-is and StackTraceHash $null when no trace provided' {
            InModuleScope ArcRemediator {
                $row = New-RemediatorRow -EventTimeUtc ([datetime]::UtcNow) `
                    -CloudProfile 'Commercial' -ScriptMode 'Observe' -Outcome 'AuthFailure' `
                    -ErrorMessage 'short error' -ErrorType 'AuthFailure'
                $row['ErrorMessage'] | Should -Be 'short error'
                $row['StackTraceHash'] | Should -BeNullOrEmpty
            }
        }
    }

    Context 'RemediatorState fields' {
        It 'populates ConsecutiveFailures / BreakerTripped / LastRemediationUtc / ResetByUser' {
            InModuleScope ArcRemediator {
                $state = [PSCustomObject]@{
                    ConsecutiveFailures = 3
                    BreakerTripped = $true
                    LastSuccessfulRunUtc = '2026-05-10T12:00:00Z'
                    ResetByUser = 'local:michael'
                }
                $row = New-RemediatorRow -EventTimeUtc ([datetime]::UtcNow) `
                    -CloudProfile 'Commercial' -ScriptMode 'Enforce' -Outcome 'BreakerTripped' `
                    -RemediatorState $state
                $row['ConsecutiveFailures'] | Should -Be 3
                $row['BreakerTripped'] | Should -BeTrue
                $row['LastRemediationUtc'] | Should -Be '2026-05-10T12:00:00Z'
                $row['ResetByUser'] | Should -Be 'local:michael'
            }
        }
    }

    Context 'FQDN lookup is best-effort and never crashes the run' {
        It 'does not throw even if DNS lookup fails (cannot easily mock GetHostEntry; smoke test only)' {
            InModuleScope ArcRemediator {
                { New-RemediatorRow -EventTimeUtc ([datetime]::UtcNow) `
                    -CloudProfile 'Commercial' -ScriptMode 'Observe' -Outcome 'Healthy' } | Should -Not -Throw
            }
        }
    }
}
