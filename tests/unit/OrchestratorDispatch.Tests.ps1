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

    Context 'Paused tag gate' {
        It 'returns MachinePaused without running any probes when Remediation=Paused tag is set' {
            InModuleScope ArcRemediator {
                Mock Invoke-AzcmagentCheck  { throw 'Should not be called: probes skipped when Paused' }
                Mock Test-AgentServices     { throw 'Should not be called: probes skipped when Paused' }
                Mock Get-AgentCertificateProbe { throw 'Should not be called: probes skipped when Paused' }
                Mock Get-TimeSyncProbe         { throw 'Should not be called: probes skipped when Paused' }
                Mock Get-AgentVersionProbe     { throw 'Should not be called: probes skipped when Paused' }
                Mock Invoke-ExpiredRejoin      { throw 'Should not be called: paused machine' }

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
                # Tags include the Remediation=Paused operator tag and another tag to confirm
                # we don't special-case single-property objects.
                $rs   = [PSCustomObject]@{
                    Classification='Disconnected'; Location='eastus'
                    Tags=[PSCustomObject]@{ env='prod'; Remediation='Paused' }
                }
                $sw   = [System.Diagnostics.Stopwatch]::new()
                $sp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "disp-paused-$([guid]::NewGuid().ToString('N')).json")

                $result = Invoke-OrchestratorDispatch `
                    -Config $cfg -State $state -Mode 'Enforce' `
                    -CloudProfile 'Commercial' -Connectivity $conn -ResourceState $rs `
                    -LocalRg 'rg-test' -LocalName 'vm-test' -ArmAccessToken 'tok' `
                    -EventTime ([datetime]::UtcNow) -StatePath $sp -Sw $sw

                $result.OutcomeString | Should -Be 'MachinePaused'
                $result.ProbeCheck    | Should -BeNullOrEmpty
                $result.ProbeServices | Should -BeNullOrEmpty
            }
        }

        It 'does NOT return MachinePaused when tag value is not exactly Paused (wrong case)' {
            InModuleScope ArcRemediator {
                Mock Invoke-AzcmagentCheck  { return $null }
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
                    SchemaVersion=1; ConsecutiveFailures=0; BreakerTripped=$false
                    LastSuccessfulRunUtc=$null; LastExpiredAttemptStartedUtc=$null; LastExpiredAttemptOutcome=$null
                }
                $conn = [PSCustomObject]@{ ArcGatewayResourceId=$null; NeedsHuman=$false; NeedsHumanReason=$null; IsClusterBacked=$false }
                # 'paused' (lower-case) must NOT trigger the gate — tag matching is case-sensitive.
                $rs   = [PSCustomObject]@{
                    Classification='Connected'; Location='eastus'
                    Tags=[PSCustomObject]@{ Remediation='paused' }
                }
                $sw   = [System.Diagnostics.Stopwatch]::new()
                $sp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "disp-notpaused-$([guid]::NewGuid().ToString('N')).json")

                $result = Invoke-OrchestratorDispatch `
                    -Config $cfg -State $state -Mode 'Enforce' `
                    -CloudProfile 'Commercial' -Connectivity $conn -ResourceState $rs `
                    -LocalRg 'rg-test' -LocalName 'vm-test' -ArmAccessToken 'tok' `
                    -EventTime ([datetime]::UtcNow) -StatePath $sp -Sw $sw

                $result.OutcomeString | Should -Not -Be 'MachinePaused'
            }
        }

        It 'does NOT trigger MachinePaused when Tags object is empty (no properties)' {
            InModuleScope ArcRemediator {
                Mock Invoke-AzcmagentCheck  { return $null }
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
                    SchemaVersion=1; ConsecutiveFailures=0; BreakerTripped=$false
                    LastSuccessfulRunUtc=$null; LastExpiredAttemptStartedUtc=$null; LastExpiredAttemptOutcome=$null
                }
                $conn = [PSCustomObject]@{ ArcGatewayResourceId=$null; NeedsHuman=$false; NeedsHumanReason=$null; IsClusterBacked=$false }
                $rs   = [PSCustomObject]@{
                    Classification='Connected'; Location='eastus'
                    Tags=[PSCustomObject]@{}
                }
                $sw   = [System.Diagnostics.Stopwatch]::new()
                $sp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "disp-emptytags-$([guid]::NewGuid().ToString('N')).json")

                $result = Invoke-OrchestratorDispatch `
                    -Config $cfg -State $state -Mode 'Enforce' `
                    -CloudProfile 'Commercial' -Connectivity $conn -ResourceState $rs `
                    -LocalRg 'rg-test' -LocalName 'vm-test' -ArmAccessToken 'tok' `
                    -EventTime ([datetime]::UtcNow) -StatePath $sp -Sw $sw

                $result.OutcomeString | Should -Not -Be 'MachinePaused'
                $result.OutcomeString | Should -Be 'Healthy'
            }
        }
    }

    Context 'Agent cert NearExpiry escalates to NeedsHuman in Disconnected state' {
        It 'returns NeedsHuman with cert status when Get-AgentCertificateProbe returns NearExpiry' {
            InModuleScope ArcRemediator {
                Mock Invoke-AzcmagentCheck  { return $null }
                Mock Test-AgentServices     { return [PSCustomObject]@{ Healthy=$false; NeedsHuman=$false; NeedsHumanReason=$null; Restarted=@() } }
                Mock Get-AgentCertificateProbe { return [PSCustomObject]@{ Status='NearExpiry'; DaysUntilExpiry=7; IsExpired=$false; Source='azcmagent-show' } }
                Mock Get-TimeSyncProbe         { return $null }
                Mock Get-AgentVersionProbe     { return $null }
                Mock Invoke-ExpiredRejoin      { throw 'Should not attempt rejoin when cert NearExpiry' }

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
                $sp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "disp-certnear-$([guid]::NewGuid().ToString('N')).json")

                $result = Invoke-OrchestratorDispatch `
                    -Config $cfg -State $state -Mode 'Enforce' `
                    -CloudProfile 'Commercial' -Connectivity $conn -ResourceState $rs `
                    -LocalRg 'rg-test' -LocalName 'vm-test' -ArmAccessToken 'tok' `
                    -EventTime ([datetime]::UtcNow) -StatePath $sp -Sw $sw

                $result.OutcomeString | Should -Be 'NeedsHuman'
                $result.OutcomeDetail | Should -Match 'NearExpiry'
                $result.OutcomeDetail | Should -Match 'DaysUntilExpiry=7'
            }
        }

        It 'returns NeedsHuman when agent cert is Expired' {
            InModuleScope ArcRemediator {
                Mock Invoke-AzcmagentCheck  { return $null }
                Mock Test-AgentServices     { return $null }
                Mock Get-AgentCertificateProbe { return [PSCustomObject]@{ Status='Expired'; DaysUntilExpiry=0; IsExpired=$true; Source='azcmagent-show' } }
                Mock Get-TimeSyncProbe         { return $null }
                Mock Get-AgentVersionProbe     { return $null }
                Mock Invoke-ExpiredRejoin      { throw 'Should not attempt rejoin when cert Expired' }

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
                $sp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "disp-certexp-$([guid]::NewGuid().ToString('N')).json")

                $result = Invoke-OrchestratorDispatch `
                    -Config $cfg -State $state -Mode 'Enforce' `
                    -CloudProfile 'Commercial' -Connectivity $conn -ResourceState $rs `
                    -LocalRg 'rg-test' -LocalName 'vm-test' -ArmAccessToken 'tok' `
                    -EventTime ([datetime]::UtcNow) -StatePath $sp -Sw $sw

                $result.OutcomeString | Should -Be 'NeedsHuman'
                $result.OutcomeDetail | Should -Match 'Expired'
            }
        }
    }

    Context 'Reconnect-only short cooldown' {
        It 'uses ReconnectOnlyCooldownHours (24h default) instead of 7-day cooldown when last outcome was ConnectFailed' {
            InModuleScope ArcRemediator {
                Mock Invoke-AzcmagentCheck  { return $null }
                Mock Test-AgentServices     { return $null }
                Mock Get-AgentCertificateProbe { return $null }
                Mock Get-TimeSyncProbe         { return $null }
                Mock Get-AgentVersionProbe     { return $null }
                Mock Invoke-ExpiredRejoin      { throw 'Should not be called; still within cooldown' }

                $cfg = [PSCustomObject]@{
                    ArcCredential              = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s'; CertificateThumbprint=$null }
                    SubscriptionId             = '00000000-0000-0000-0000-000000000000'
                    EnableAutomaticAgentUpgrade = $false
                    CircuitBreakerFailureThreshold = 3
                    # No ReconnectOnlyCooldownHours -> defaults to 24.
                }
                # Last attempt was 12 hours ago (within 24h but within 7 days too).
                # With the old flat 7-day cooldown this would NOT be in cooldown (12h < 7d but 12h < 24h IS in cooldown).
                $twelveHoursAgo = (Get-Date).ToUniversalTime().AddHours(-12).ToString('o')
                $state = [PSCustomObject]@{
                    SchemaVersion=1; ConsecutiveFailures=1; BreakerTripped=$false
                    LastSuccessfulRunUtc=$null
                    LastExpiredAttemptStartedUtc=$twelveHoursAgo
                    LastExpiredAttemptOutcome='ConnectFailed'
                }
                $conn = [PSCustomObject]@{ ArcGatewayResourceId=$null; NeedsHuman=$false; NeedsHumanReason=$null; IsClusterBacked=$false }
                $rs   = [PSCustomObject]@{ Classification='Expired'; Location='eastus'; Tags=$null }
                $sw   = [System.Diagnostics.Stopwatch]::new()
                $sp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "disp-reconnect-cd-$([guid]::NewGuid().ToString('N')).json")

                $result = Invoke-OrchestratorDispatch `
                    -Config $cfg -State $state -Mode 'Enforce' `
                    -CloudProfile 'Commercial' -Connectivity $conn -ResourceState $rs `
                    -LocalRg 'rg-test' -LocalName 'vm-test' -ArmAccessToken 'tok' `
                    -EventTime ([datetime]::UtcNow) -StatePath $sp -Sw $sw

                $result.OutcomeString | Should -Be 'CooldownSkipped'
                $result.OutcomeDetail | Should -Match '24-hour'
                $result.OutcomeDetail | Should -Match 'ConnectFailed'
            }
        }

        It 'allows retry after ReconnectOnlyCooldownHours has elapsed even when within 7-day window' {
            InModuleScope ArcRemediator {
                Mock Invoke-AzcmagentCheck  { return $null }
                Mock Test-AgentServices     { return $null }
                Mock Get-AgentCertificateProbe { return $null }
                Mock Get-TimeSyncProbe         { return $null }
                Mock Get-AgentVersionProbe     { return $null }
                Mock Invoke-ExpiredRejoin {
                    [PSCustomObject]@{ Outcome='ExpiredRejoined'; MarkerWritten=$true; AttemptId='a'; Detail='ok'; FinalState=$null; DeleteResult=$null; ConnectResult=$null; TagsResult=$null; DurationMs=1 }
                }
                Mock Set-RemediatorState       { $null = $_ }

                $cfg = [PSCustomObject]@{
                    ArcCredential              = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s'; CertificateThumbprint=$null }
                    SubscriptionId             = '00000000-0000-0000-0000-000000000000'
                    EnableAutomaticAgentUpgrade = $false
                    CircuitBreakerFailureThreshold = 3
                    ReconnectOnlyCooldownHours = 6
                }
                # Last attempt was 8 hours ago, cooldown is 6 hours -> cooldown expired, retry allowed.
                $eightHoursAgo = (Get-Date).ToUniversalTime().AddHours(-8).ToString('o')
                $state = [PSCustomObject]@{
                    SchemaVersion=1; ConsecutiveFailures=1; BreakerTripped=$false
                    LastSuccessfulRunUtc=$null
                    LastExpiredAttemptStartedUtc=$eightHoursAgo
                    LastExpiredAttemptOutcome='ConnectFailed'
                }
                $conn = [PSCustomObject]@{ ArcGatewayResourceId=$null; NeedsHuman=$false; NeedsHumanReason=$null; IsClusterBacked=$false }
                $rs   = [PSCustomObject]@{ Classification='Expired'; Location='eastus'; Tags=$null }
                $sw   = [System.Diagnostics.Stopwatch]::new()
                $sp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "disp-reconnect-ok-$([guid]::NewGuid().ToString('N')).json")

                $result = Invoke-OrchestratorDispatch `
                    -Config $cfg -State $state -Mode 'Enforce' `
                    -CloudProfile 'Commercial' -Connectivity $conn -ResourceState $rs `
                    -LocalRg 'rg-test' -LocalName 'vm-test' -ArmAccessToken 'tok' `
                    -EventTime ([datetime]::UtcNow) -StatePath $sp -Sw $sw

                $result.OutcomeString | Should -Not -Be 'CooldownSkipped'
                Should -Invoke Invoke-ExpiredRejoin -Times 1 -Exactly
            }
        }
    }
}
