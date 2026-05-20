#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Invoke-OrchestratorDispatch' {
    BeforeAll {
        $script:Cfg = [PSCustomObject]@{
            ArcCredential              = [PSCustomObject]@{ TenantId = 't'; ClientId = 'c'; CredentialType = 'ClientSecret'; ClientSecret = 's'; CertificateThumbprint = $null }
            SubscriptionId             = '00000000-0000-0000-0000-000000000000'
            EnableAutomaticAgentUpgrade = $false
            CircuitBreakerFailureThreshold = 3
        }
        $script:Connectivity = [PSCustomObject]@{
            ArcGatewayResourceId = $null
            NeedsHuman           = $false
            NeedsHumanReason     = $null
            IsClusterBacked      = $false
        }
        $script:Sw = [System.Diagnostics.Stopwatch]::new()
        $script:EventTime = [datetime]::UtcNow
        $script:StatePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "dispatch-state-$([guid]::NewGuid().ToString('N')).json")
    }

    AfterAll {
        if (Test-Path $script:StatePath) { Remove-Item $script:StatePath -Force }
    }

    Context 'Connected ARM state in Enforce mode returns Healthy' {
        It 'sets OutcomeString to Healthy and resets ConsecutiveFailures' {
            InModuleScope ArcRemediator {
                Mock Invoke-AzcmagentCheck  { return $null } -ParameterFilter { $true }
                Mock Test-AgentServices     { return [PSCustomObject]@{ Healthy=$true; NeedsHuman=$false; NeedsHumanReason=$null; Restarted=@() } }
                Mock Get-AgentCertificateProbe { return $null }
                Mock Get-TimeSyncProbe         { return $null }
                Mock Get-AgentVersionProbe     { return $null }
                Mock Set-RemediatorState       { $null = $_ }

                $cfg = [PSCustomObject]@{
                    ArcCredential              = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s'; CertificateThumbprint=$null }
                    SubscriptionId             = '00000000-0000-0000-0000-000000000000'
                    EnableAutomaticAgentUpgrade = $false
                    CircuitBreakerFailureThreshold = 3
                }
                $state = [PSCustomObject]@{
                    SchemaVersion = 1; ConsecutiveFailures = 2; BreakerTripped = $false
                    LastSuccessfulRunUtc = $null; LastExpiredAttemptStartedUtc = $null; LastExpiredAttemptOutcome = $null
                }
                $conn = [PSCustomObject]@{ ArcGatewayResourceId=$null; NeedsHuman=$false; NeedsHumanReason=$null; IsClusterBacked=$false }
                $rs   = [PSCustomObject]@{ Classification='Connected'; Location='eastus'; Tags=$null }
                $sw   = [System.Diagnostics.Stopwatch]::new()
                $sp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "disp-test-$([guid]::NewGuid().ToString('N')).json")

                $result = Invoke-OrchestratorDispatch `
                    -Config $cfg -State $state -Mode 'Enforce' `
                    -CloudProfile 'Commercial' -Connectivity $conn -ResourceState $rs `
                    -LocalRg 'rg-test' -LocalName 'vm-test' -ArmAccessToken 'tok' `
                    -EventTime ([datetime]::UtcNow) -StatePath $sp -Sw $sw

                $result.OutcomeString | Should -Be 'Healthy'
                $state.ConsecutiveFailures | Should -Be 0
                $state.BreakerTripped | Should -Be $false
            }
        }
    }

    Context 'Disconnected ARM state in Observe mode returns ObserveOnly' {
        It 'returns ObserveOnly without attempting service repair' {
            InModuleScope ArcRemediator {
                Mock Invoke-AzcmagentCheck  { return $null } -ParameterFilter { $true }
                Mock Test-AgentServices     { return [PSCustomObject]@{ Healthy=$false; NeedsHuman=$false; NeedsHumanReason=$null; Restarted=@() } }
                Mock Get-AgentCertificateProbe { return $null }
                Mock Get-TimeSyncProbe         { return $null }
                Mock Get-AgentVersionProbe     { return $null }
                Mock Repair-AgentServices      { throw 'Should not be called in Observe mode' }

                $cfg = [PSCustomObject]@{
                    ArcCredential              = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s'; CertificateThumbprint=$null }
                    SubscriptionId             = '00000000-0000-0000-0000-000000000000'
                    EnableAutomaticAgentUpgrade = $false
                    CircuitBreakerFailureThreshold = 3
                }
                $state = [PSCustomObject]@{
                    SchemaVersion=1; ConsecutiveFailures=0; BreakerTripped=$false
                    LastSuccessfulRunUtc=$null; LastExpiredAttemptStartedUtc=$null; LastExpiredAttemptOutcome=$null
                }
                $conn = [PSCustomObject]@{ ArcGatewayResourceId=$null; NeedsHuman=$false; NeedsHumanReason=$null; IsClusterBacked=$false }
                $rs   = [PSCustomObject]@{ Classification='Disconnected'; Location='eastus'; Tags=$null }
                $sw   = [System.Diagnostics.Stopwatch]::new()
                $sp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "disp-obs-$([guid]::NewGuid().ToString('N')).json")

                $result = Invoke-OrchestratorDispatch `
                    -Config $cfg -State $state -Mode 'Observe' `
                    -CloudProfile 'Commercial' -Connectivity $conn -ResourceState $rs `
                    -LocalRg 'rg-test' -LocalName 'vm-test' -ArmAccessToken 'tok' `
                    -EventTime ([datetime]::UtcNow) -StatePath $sp -Sw $sw

                $result.OutcomeString | Should -Be 'ObserveOnly'
                Assert-MockCalled Repair-AgentServices -Times 0 -Scope It
            }
        }
    }

    Context 'Expired ARM state with MaxRuntimeMinutes=0 triggers Aborted (self-deadline)' {
        It 'returns Aborted without calling Invoke-ExpiredRejoin' {
            InModuleScope ArcRemediator {
                Mock Invoke-AzcmagentCheck  { return $null } -ParameterFilter { $true }
                Mock Test-AgentServices     { return $null }
                Mock Get-AgentCertificateProbe { return $null }
                Mock Get-TimeSyncProbe         { return $null }
                Mock Get-AgentVersionProbe     { return $null }
                Mock Invoke-ExpiredRejoin      { throw 'Should not be called when deadline already hit' }

                $cfg = [PSCustomObject]@{
                    ArcCredential              = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s'; CertificateThumbprint=$null }
                    SubscriptionId             = '00000000-0000-0000-0000-000000000000'
                    EnableAutomaticAgentUpgrade = $false
                    CircuitBreakerFailureThreshold = 3
                    MaxRuntimeMinutes          = 0
                }
                $state = [PSCustomObject]@{
                    SchemaVersion=1; ConsecutiveFailures=0; BreakerTripped=$false
                    LastSuccessfulRunUtc=$null; LastExpiredAttemptStartedUtc=$null; LastExpiredAttemptOutcome=$null
                }
                $conn = [PSCustomObject]@{ ArcGatewayResourceId=$null; NeedsHuman=$false; NeedsHumanReason=$null; IsClusterBacked=$false }
                $rs   = [PSCustomObject]@{ Classification='Expired'; Location='eastus'; Tags=$null }
                # Stopwatch with nonzero elapsed forces TotalMinutes >= 0.
                $sw   = [System.Diagnostics.Stopwatch]::StartNew()
                $sp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "disp-dead-$([guid]::NewGuid().ToString('N')).json")

                $result = Invoke-OrchestratorDispatch `
                    -Config $cfg -State $state -Mode 'Enforce' `
                    -CloudProfile 'Commercial' -Connectivity $conn -ResourceState $rs `
                    -LocalRg 'rg-test' -LocalName 'vm-test' -ArmAccessToken 'tok' `
                    -EventTime ([datetime]::UtcNow) -StatePath $sp -Sw $sw

                $result.OutcomeString | Should -Be 'Aborted'
                $result.OutcomeDetail | Should -Match 'SelfDeadlineHit'
                Assert-MockCalled Invoke-ExpiredRejoin -Times 0 -Scope It
            }
        }
    }
}
