#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force

    function script:New-EphemeralLayout {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("arc-orch-$([guid]::NewGuid().ToString('N'))")
        $cfg = Join-Path $root 'config.json'
        $state = Join-Path $root 'state.json'
        $logs = Join-Path $root 'logs'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        [PSCustomObject]@{ Root = $root; Config = $cfg; State = $state; Logs = $logs }
    }

    function script:Write-FakeConfig {
        param(
            [Parameter(Mandatory)] [string]$Path,
            [Parameter()] [string]$CloudProfile = 'Commercial',
            [Parameter()] [string]$Mode = 'Observe'
        )
        $obj = [ordered]@{
            CloudProfile = $CloudProfile
            ArcCredential = [ordered]@{
                TenantId='11111111-1111-1111-1111-111111111111'; ClientId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                CredentialType='ClientSecret'; ClientSecret='lab-secret'; CertificateThumbprint=$null
            }
            MonitorCredential = [ordered]@{
                UseArcCredential=$true
                TenantId=$null; ClientId=$null; CredentialType=$null; ClientSecret=$null; CertificateThumbprint=$null
            }
            SubscriptionId = '00000000-0000-0000-0000-000000000000'
            ScopedResourceGroups = @('rg-prod')
            LogIngestionEndpoint = 'https://fake-dcr.eastus-1.ingest.monitor.azure.com'
            DcrImmutableId = 'dcr-imm-test'
            StreamName = 'Custom-ArcRemediation'
            KillSwitchUrl = 'https://fake.blob.core.windows.net/arc-remediator/kill-switch.txt?sig=fake&sp=r'
            PrivateLinkScopeResourceId = $null
            ArcGatewayResourceId = $null
            ProxyUrl = $null
            EnableAutomaticAgentUpgrade = $false
            CircuitBreakerFailureThreshold = 3
            Mode = $Mode
            Version = '1.0.0'
        }
        ($obj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

# All Mock setups happen inside InModuleScope so the mocked private
# functions resolve in the module's command table. The shared mock
# scaffold is defined per-test as a script block stored on $env so the
# In-ModuleScope block can dot-source it - this avoids the well-known
# pitfall that BeforeAll-declared `function script:X` definitions are
# not visible inside InModuleScope.

Describe 'Invoke-ArcRemediation' {

    Context 'Kill switch read happens BEFORE Azure auth' {
        It 'returns FleetPaused without any token acquisition when kill switch is not enabled' {
            $layout = New-EphemeralLayout
            try {
                Write-FakeConfig -Path $layout.Config
                InModuleScope ArcRemediator -Parameters @{ cfg = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfg, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$false; Reason='Forbidden'; LastError=$null } }
                    Mock Get-AzureToken { throw 'must not be called' }
                    Mock Get-AzureResourceState { throw 'must not be called' }
                    Mock Invoke-ExpiredRejoin { throw 'must not be called' }
                    Mock Get-ArcConnectivitySettings { throw 'must not be called' }
                    Mock Send-LogAnalytics { [PSCustomObject]@{ Success=$true; StatusCode=204; RowCount=1; ErrorMessage=$null } }

                    $r = Invoke-ArcRemediation -ConfigPath $cfg -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'FleetPaused'
                    $r.ExitCode | Should -Be 0
                    Should -Invoke Get-AzureToken -Times 0 -Exactly
                    Should -Invoke Get-AzureResourceState -Times 0 -Exactly
                    Should -Invoke Invoke-ExpiredRejoin -Times 0 -Exactly
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Cloud profile mismatch (the requirement)' {
        It 'fails closed with ConfigMismatch when config=DoD but local agent reports AzureCloud (no ARM/Monitor token)' {
            $layout = New-EphemeralLayout
            try {
                Write-FakeConfig -Path $layout.Config -CloudProfile 'AzureGovernmentDoD' -Mode 'Enforce'
                InModuleScope ArcRemediator -Parameters @{ cfg = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfg, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$true; Reason='Enabled'; LastError=$null } }
                    Mock Get-ArcConnectivitySettings {
                        # Local agent reports Commercial AzureCloud while config says DoD.
                        [PSCustomObject]@{
                            Proxy=$null; PrivateLinkScopeResourceId=$null; ArcGatewayResourceId=$null
                            Cloud='AzureCloud'; SubscriptionId='00000000-0000-0000-0000-000000000000'
                            ResourceGroupName='rg-prod'; ResourceName='host-1'; Location='eastus'
                            AgentVersion='1.45.0'; AgentStatus='Connected'
                            IsClusterBacked=$false; ClusterEvidence=@(); HasConfigMismatch=$false
                            ConfigMismatchReason=$null; NeedsHuman=$false; NeedsHumanReason=$null
                            ParseFailed=$false; RawJson='{}'
                        }
                    }
                    Mock Get-AzureToken { throw 'must not be called - cloud mismatch fails closed before token acquisition' }
                    Mock Get-AzureResourceState { throw 'must not be called' }
                    Mock Invoke-ExpiredRejoin { throw 'must not be called' }
                    Mock Send-LogAnalytics { throw 'must not be called - no token means no LAW row' }

                    $r = Invoke-ArcRemediation -ConfigPath $cfg -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'ConfigMismatch'
                    $r.OutcomeDetail | Should -Match 'AzureGovernmentDoD'
                    $r.OutcomeDetail | Should -Match 'AzureCloud'
                    $r.ExitCode | Should -Be 2
                    Should -Invoke Get-AzureToken -Times 0 -Exactly
                    Should -Invoke Get-AzureResourceState -Times 0 -Exactly
                    Should -Invoke Send-LogAnalytics -Times 0 -Exactly
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Connected -> Healthy' {
        It 'returns Healthy in Observe mode without any mutation' {
            $layout = New-EphemeralLayout
            try {
                Write-FakeConfig -Path $layout.Config -Mode 'Observe'
                InModuleScope ArcRemediator -Parameters @{ cfg = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfg, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$true; Reason='Enabled'; LastError=$null } }
                    Mock Get-ArcConnectivitySettings {
                        [PSCustomObject]@{
                            Proxy=$null; PrivateLinkScopeResourceId=$null; ArcGatewayResourceId=$null
                            Cloud='AzureCloud'; SubscriptionId='00000000-0000-0000-0000-000000000000'
                            ResourceGroupName='rg-prod'; ResourceName='host-1'; Location='eastus'
                            AgentVersion='1.45.0'; AgentStatus='Connected'
                            IsClusterBacked=$false; ClusterEvidence=@(); HasConfigMismatch=$false
                            ConfigMismatchReason=$null; NeedsHuman=$false; NeedsHumanReason=$null
                            ParseFailed=$false; RawJson='{}'
                        }
                    }
                    Mock Get-AzureToken { [PSCustomObject]@{ Purpose=$Purpose; AccessToken='tok'; TokenType='Bearer'; ExpiresOnUtc=(Get-Date).AddHours(1) } }
                    Mock Get-AzureResourceState { [PSCustomObject]@{ Classification='Connected'; StatusCode=200; ETag='W/"x"'; Tags=([PSCustomObject]@{}); Location='eastus'; Name='host-1'; Raw=$null; ErrorMessage=$null } }
                    Mock Invoke-AzcmagentCheck { [PSCustomObject]@{ rawOutput='ok'; exitCode=0; connectionType='public'; reachableUrls=@(); unreachableUrls=@(); usesProxy=$false; usesPrivateLink=$false; usesGateway=$false; sawAny429=$false; parseFailed=$false } }
                    Mock Test-AgentServices { [PSCustomObject]@{ Services=@(); MissingRequired=@(); StoppedRequired=@(); NeedsHuman=$false; NeedsHumanReason=$null } }
                    Mock Get-AgentCertificateProbe { [PSCustomObject]@{ Status='OK'; DaysUntilExpiry=365; IsExpired=$false; Source='azcmagent-show' } }
                    Mock Get-TimeSyncProbe { [PSCustomObject]@{ Status='OK'; OffsetSeconds=0.1; IsWithinTolerance=$true; MaxOffsetSeconds=60; RawOutput='' } }
                    Mock Get-AgentVersionProbe { [PSCustomObject]@{ Status='OK'; MeetsFloor=$true; Version='1.45.0'; SupportedFloor='1.40.0' } }
                    Mock Repair-AgentServices { throw 'must not be called in Observe mode' }
                    Mock Invoke-ExpiredRejoin { throw 'must not be called for Connected state' }
                    Mock Send-LogAnalytics { [PSCustomObject]@{ Success=$true; StatusCode=204; RowCount=1; ErrorMessage=$null } }

                    $r = Invoke-ArcRemediation -ConfigPath $cfg -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'Healthy'
                    $r.ExitCode | Should -Be 0
                    Should -Invoke Send-LogAnalytics -Times 1 -Exactly
                    Should -Invoke Invoke-ExpiredRejoin -Times 0 -Exactly
                    Should -Invoke Repair-AgentServices -Times 0 -Exactly
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Disconnected + Observe = ObserveOnly' {
        It 'does NOT call Repair-AgentServices when mode=Observe' {
            $layout = New-EphemeralLayout
            try {
                Write-FakeConfig -Path $layout.Config -Mode 'Observe'
                InModuleScope ArcRemediator -Parameters @{ cfg = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfg, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$true; Reason='Enabled'; LastError=$null } }
                    Mock Get-ArcConnectivitySettings {
                        [PSCustomObject]@{
                            Proxy=$null; PrivateLinkScopeResourceId=$null; ArcGatewayResourceId=$null
                            Cloud='AzureCloud'; SubscriptionId='00000000-0000-0000-0000-000000000000'
                            ResourceGroupName='rg-prod'; ResourceName='host-1'; Location='eastus'
                            AgentVersion='1.45.0'; AgentStatus='Disconnected'
                            IsClusterBacked=$false; ClusterEvidence=@(); HasConfigMismatch=$false
                            ConfigMismatchReason=$null; NeedsHuman=$false; NeedsHumanReason=$null
                            ParseFailed=$false; RawJson='{}'
                        }
                    }
                    Mock Get-AzureToken { [PSCustomObject]@{ Purpose=$Purpose; AccessToken='tok'; TokenType='Bearer'; ExpiresOnUtc=(Get-Date).AddHours(1) } }
                    Mock Get-AzureResourceState { [PSCustomObject]@{ Classification='Disconnected'; StatusCode=200; ETag='W/"x"'; Tags=$null; Location='eastus'; Name='host-1'; Raw=$null; ErrorMessage=$null } }
                    Mock Invoke-AzcmagentCheck { [PSCustomObject]@{ rawOutput=''; exitCode=0; connectionType='public'; reachableUrls=@(); unreachableUrls=@(); usesProxy=$false; usesPrivateLink=$false; usesGateway=$false; sawAny429=$false; parseFailed=$true } }
                    Mock Test-AgentServices { [PSCustomObject]@{ Services=@(); MissingRequired=@(); StoppedRequired=@(); NeedsHuman=$false; NeedsHumanReason=$null } }
                    Mock Get-AgentCertificateProbe { [PSCustomObject]@{ Status='Unavailable'; DaysUntilExpiry=$null; IsExpired=$null; Source='unavailable' } }
                    Mock Get-TimeSyncProbe { [PSCustomObject]@{ Status='Unknown'; OffsetSeconds=$null; IsWithinTolerance=$null; MaxOffsetSeconds=60; RawOutput='' } }
                    Mock Get-AgentVersionProbe { [PSCustomObject]@{ Status='OK'; MeetsFloor=$true; Version='1.45.0'; SupportedFloor='1.40.0' } }
                    Mock Repair-AgentServices { throw 'must not be called in Observe mode' }
                    Mock Send-LogAnalytics { [PSCustomObject]@{ Success=$true; StatusCode=204; RowCount=1; ErrorMessage=$null } }

                    $r = Invoke-ArcRemediation -ConfigPath $cfg -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'ObserveOnly'
                    $r.ExitCode | Should -Be 0
                    Should -Invoke Repair-AgentServices -Times 0 -Exactly
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Disconnected + Enforce' {
        It 'returns ServicesRepaired when Repair-AgentServices restarts a stopped service' {
            $layout = New-EphemeralLayout
            try {
                Write-FakeConfig -Path $layout.Config -Mode 'Enforce'
                InModuleScope ArcRemediator -Parameters @{ cfg = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfg, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$true; Reason='Enabled'; LastError=$null } }
                    Mock Get-ArcConnectivitySettings {
                        [PSCustomObject]@{
                            Proxy=$null; PrivateLinkScopeResourceId=$null; ArcGatewayResourceId=$null
                            Cloud='AzureCloud'; SubscriptionId='00000000-0000-0000-0000-000000000000'
                            ResourceGroupName='rg-prod'; ResourceName='host-1'; Location='eastus'
                            AgentVersion='1.45.0'; AgentStatus='Disconnected'
                            IsClusterBacked=$false; ClusterEvidence=@(); HasConfigMismatch=$false
                            ConfigMismatchReason=$null; NeedsHuman=$false; NeedsHumanReason=$null
                            ParseFailed=$false; RawJson='{}'
                        }
                    }
                    Mock Get-AzureToken { [PSCustomObject]@{ Purpose=$Purpose; AccessToken='tok'; TokenType='Bearer'; ExpiresOnUtc=(Get-Date).AddHours(1) } }
                    Mock Get-AzureResourceState { [PSCustomObject]@{ Classification='Disconnected'; StatusCode=200; ETag='W/"x"'; Tags=$null; Location='eastus'; Name='host-1'; Raw=$null; ErrorMessage=$null } }
                    Mock Invoke-AzcmagentCheck { [PSCustomObject]@{ rawOutput=''; exitCode=0; connectionType='public'; reachableUrls=@(); unreachableUrls=@(); usesProxy=$false; usesPrivateLink=$false; usesGateway=$false; sawAny429=$false; parseFailed=$true } }
                    Mock Test-AgentServices { [PSCustomObject]@{ Services=@(); MissingRequired=@(); StoppedRequired=@('GCArcService'); NeedsHuman=$false; NeedsHumanReason=$null } }
                    Mock Get-AgentCertificateProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-TimeSyncProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-AgentVersionProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Repair-AgentServices { [PSCustomObject]@{ Before=$null; After=$null; Restarted=@('GCArcService'); FailedToRestart=@(); NeedsHuman=$false; NeedsHumanReason=$null } }
                    Mock Send-LogAnalytics { [PSCustomObject]@{ Success=$true; StatusCode=204; RowCount=1; ErrorMessage=$null } }

                    $r = Invoke-ArcRemediation -ConfigPath $cfg -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'ServicesRepaired'
                    $r.ExitCode | Should -Be 0
                    Should -Invoke Repair-AgentServices -Times 1 -Exactly
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Expired + Observe' {
        It 'returns ObserveOnly when classification=Expired and mode=Observe' {
            $layout = New-EphemeralLayout
            try {
                Write-FakeConfig -Path $layout.Config -Mode 'Observe'
                InModuleScope ArcRemediator -Parameters @{ cfg = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfg, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$true; Reason='Enabled'; LastError=$null } }
                    Mock Get-ArcConnectivitySettings {
                        [PSCustomObject]@{ Proxy=$null; PrivateLinkScopeResourceId=$null; ArcGatewayResourceId=$null
                            Cloud='AzureCloud'; SubscriptionId='00000000-0000-0000-0000-000000000000'
                            ResourceGroupName='rg-prod'; ResourceName='host-1'; Location='eastus'
                            AgentVersion='1.45.0'; AgentStatus='Expired'
                            IsClusterBacked=$false; ClusterEvidence=@(); HasConfigMismatch=$false
                            ConfigMismatchReason=$null; NeedsHuman=$false; NeedsHumanReason=$null
                            ParseFailed=$false; RawJson='{}'
                        }
                    }
                    Mock Get-AzureToken { [PSCustomObject]@{ Purpose=$Purpose; AccessToken='tok'; TokenType='Bearer'; ExpiresOnUtc=(Get-Date).AddHours(1) } }
                    Mock Get-AzureResourceState { [PSCustomObject]@{ Classification='Expired'; StatusCode=200; ETag='W/"x"'; Tags=([PSCustomObject]@{ env='prod' }); Location='eastus'; Name='host-1'; Raw=$null; ErrorMessage=$null } }
                    Mock Invoke-AzcmagentCheck { [PSCustomObject]@{ rawOutput=''; exitCode=0; connectionType='public'; reachableUrls=@(); unreachableUrls=@(); usesProxy=$false; usesPrivateLink=$false; usesGateway=$false; sawAny429=$false; parseFailed=$true } }
                    Mock Test-AgentServices { [PSCustomObject]@{ Services=@(); MissingRequired=@(); StoppedRequired=@(); NeedsHuman=$false; NeedsHumanReason=$null } }
                    Mock Get-AgentCertificateProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-TimeSyncProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-AgentVersionProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Invoke-ExpiredRejoin { throw 'must not be called in Observe mode' }
                    Mock Send-LogAnalytics { [PSCustomObject]@{ Success=$true; StatusCode=204; RowCount=1; ErrorMessage=$null } }

                    $r = Invoke-ArcRemediation -ConfigPath $cfg -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'ObserveOnly'
                    Should -Invoke Invoke-ExpiredRejoin -Times 0 -Exactly
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Expired + Enforce + cluster-free' {
        It 'invokes Invoke-ExpiredRejoin and maps Outcome to ExpiredRejoinSuccess (exit 0)' {
            $layout = New-EphemeralLayout
            try {
                Write-FakeConfig -Path $layout.Config -Mode 'Enforce'
                InModuleScope ArcRemediator -Parameters @{ cfg = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfg, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$true; Reason='Enabled'; LastError=$null } }
                    Mock Get-ArcConnectivitySettings {
                        [PSCustomObject]@{ Proxy=$null; PrivateLinkScopeResourceId=$null; ArcGatewayResourceId=$null
                            Cloud='AzureCloud'; SubscriptionId='00000000-0000-0000-0000-000000000000'
                            ResourceGroupName='rg-prod'; ResourceName='host-1'; Location='eastus'
                            AgentVersion='1.45.0'; AgentStatus='Expired'
                            IsClusterBacked=$false; ClusterEvidence=@(); HasConfigMismatch=$false
                            ConfigMismatchReason=$null; NeedsHuman=$false; NeedsHumanReason=$null
                            ParseFailed=$false; RawJson='{}'
                        }
                    }
                    Mock Get-AzureToken { [PSCustomObject]@{ Purpose=$Purpose; AccessToken='tok'; TokenType='Bearer'; ExpiresOnUtc=(Get-Date).AddHours(1) } }
                    Mock Get-AzureResourceState { [PSCustomObject]@{ Classification='Expired'; StatusCode=200; ETag='W/"x"'; Tags=([PSCustomObject]@{ env='prod' }); Location='eastus'; Name='host-1'; Raw=$null; ErrorMessage=$null } }
                    Mock Invoke-AzcmagentCheck { [PSCustomObject]@{ rawOutput=''; exitCode=0; connectionType='public'; reachableUrls=@(); unreachableUrls=@(); usesProxy=$false; usesPrivateLink=$false; usesGateway=$false; sawAny429=$false; parseFailed=$true } }
                    Mock Test-AgentServices { [PSCustomObject]@{ Services=@(); MissingRequired=@(); StoppedRequired=@(); NeedsHuman=$false; NeedsHumanReason=$null } }
                    Mock Get-AgentCertificateProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-TimeSyncProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-AgentVersionProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Invoke-ExpiredRejoin { [PSCustomObject]@{ Outcome='ExpiredRejoined'; Detail='ok'; AttemptId=[guid]::NewGuid().ToString(); MarkerWritten=$true; DeleteResult=$null; ConnectResult=$null; TagsResult=$null; FinalState=$null; ElapsedSeconds=10 } }
                    Mock Send-LogAnalytics { [PSCustomObject]@{ Success=$true; StatusCode=204; RowCount=1; ErrorMessage=$null } }

                    $r = Invoke-ArcRemediation -ConfigPath $cfg -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'ExpiredRejoinSuccess'
                    $r.ExitCode | Should -Be 0
                    Should -Invoke Invoke-ExpiredRejoin -Times 1 -Exactly
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Expired + Enforce within cooldown' {
        It 'short-circuits to CooldownSkipped (no destructive call) when marker is < 7 days old' {
            $layout = New-EphemeralLayout
            try {
                Write-FakeConfig -Path $layout.Config -Mode 'Enforce'
                $fresh = (Get-Date).AddDays(-3).ToUniversalTime().ToString('o')
                $state = [PSCustomObject]@{
                    LastSuccessfulRunUtc=$null; ConsecutiveFailures=0; BreakerTripped=$false; BreakerLastResetUtc=$null
                    LastExpiredAttemptId='prev'; LastExpiredAttemptResourceId='r'
                    LastExpiredAttemptStartedUtc=$fresh; LastExpiredAttemptCompletedUtc=$null
                    LastExpiredAttemptOutcome='DeleteFailed'; ResetByUser=$null
                }
                ($state | ConvertTo-Json) | Set-Content -LiteralPath $layout.State -Encoding UTF8

                InModuleScope ArcRemediator -Parameters @{ cfg = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfg, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$true; Reason='Enabled'; LastError=$null } }
                    Mock Get-ArcConnectivitySettings {
                        [PSCustomObject]@{ Proxy=$null; PrivateLinkScopeResourceId=$null; ArcGatewayResourceId=$null
                            Cloud='AzureCloud'; SubscriptionId='00000000-0000-0000-0000-000000000000'
                            ResourceGroupName='rg-prod'; ResourceName='host-1'; Location='eastus'
                            AgentVersion='1.45.0'; AgentStatus='Expired'
                            IsClusterBacked=$false; ClusterEvidence=@(); HasConfigMismatch=$false
                            ConfigMismatchReason=$null; NeedsHuman=$false; NeedsHumanReason=$null
                            ParseFailed=$false; RawJson='{}'
                        }
                    }
                    Mock Get-AzureToken { [PSCustomObject]@{ Purpose=$Purpose; AccessToken='tok'; TokenType='Bearer'; ExpiresOnUtc=(Get-Date).AddHours(1) } }
                    Mock Get-AzureResourceState { [PSCustomObject]@{ Classification='Expired'; StatusCode=200; ETag='W/"x"'; Tags=$null; Location='eastus'; Name='host-1'; Raw=$null; ErrorMessage=$null } }
                    Mock Invoke-AzcmagentCheck { [PSCustomObject]@{ rawOutput=''; exitCode=0; connectionType='public'; reachableUrls=@(); unreachableUrls=@(); usesProxy=$false; usesPrivateLink=$false; usesGateway=$false; sawAny429=$false; parseFailed=$true } }
                    Mock Test-AgentServices { [PSCustomObject]@{ Services=@(); MissingRequired=@(); StoppedRequired=@(); NeedsHuman=$false; NeedsHumanReason=$null } }
                    Mock Get-AgentCertificateProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-TimeSyncProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-AgentVersionProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Invoke-ExpiredRejoin { throw 'must not be called within cooldown' }
                    Mock Send-LogAnalytics { [PSCustomObject]@{ Success=$true; StatusCode=204; RowCount=1; ErrorMessage=$null } }

                    $r = Invoke-ArcRemediation -ConfigPath $cfg -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'CooldownSkipped'
                    $r.ExitCode | Should -Be 0
                    Should -Invoke Invoke-ExpiredRejoin -Times 0 -Exactly
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'ArmForbidden short-circuits to exit 2' {
        It 'returns ArmForbidden without entering the state-branch switch' {
            $layout = New-EphemeralLayout
            try {
                Write-FakeConfig -Path $layout.Config -Mode 'Enforce'
                InModuleScope ArcRemediator -Parameters @{ cfg = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfg, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$true; Reason='Enabled'; LastError=$null } }
                    Mock Get-ArcConnectivitySettings {
                        [PSCustomObject]@{ Proxy=$null; PrivateLinkScopeResourceId=$null; ArcGatewayResourceId=$null
                            Cloud='AzureCloud'; SubscriptionId='00000000-0000-0000-0000-000000000000'
                            ResourceGroupName='rg-prod'; ResourceName='host-1'; Location='eastus'
                            AgentVersion='1.45.0'; AgentStatus='Connected'
                            IsClusterBacked=$false; ClusterEvidence=@(); HasConfigMismatch=$false
                            ConfigMismatchReason=$null; NeedsHuman=$false; NeedsHumanReason=$null
                            ParseFailed=$false; RawJson='{}'
                        }
                    }
                    Mock Get-AzureToken { [PSCustomObject]@{ Purpose=$Purpose; AccessToken='tok'; TokenType='Bearer'; ExpiresOnUtc=(Get-Date).AddHours(1) } }
                    Mock Get-AzureResourceState { [PSCustomObject]@{ Classification='ArmForbidden'; StatusCode=403; ETag=$null; Tags=$null; Location=$null; Name='host-1'; Raw=$null; ErrorMessage='Forbidden' } }
                    Mock Invoke-ExpiredRejoin { throw 'must not be called' }
                    Mock Send-LogAnalytics { [PSCustomObject]@{ Success=$true; StatusCode=204; RowCount=1; ErrorMessage=$null } }

                    $r = Invoke-ArcRemediation -ConfigPath $cfg -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'ArmForbidden'
                    $r.ExitCode | Should -Be 2
                    Should -Invoke Invoke-ExpiredRejoin -Times 0 -Exactly
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'LogIngestionFailure as a secondary status' {
        It 'reports LogIngestionFailed=$true but ExitCode follows the primary Healthy outcome (0)' {
            $layout = New-EphemeralLayout
            try {
                Write-FakeConfig -Path $layout.Config -Mode 'Observe'
                InModuleScope ArcRemediator -Parameters @{ cfg = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfg, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$true; Reason='Enabled'; LastError=$null } }
                    Mock Get-ArcConnectivitySettings {
                        [PSCustomObject]@{ Proxy=$null; PrivateLinkScopeResourceId=$null; ArcGatewayResourceId=$null
                            Cloud='AzureCloud'; SubscriptionId='00000000-0000-0000-0000-000000000000'
                            ResourceGroupName='rg-prod'; ResourceName='host-1'; Location='eastus'
                            AgentVersion='1.45.0'; AgentStatus='Connected'
                            IsClusterBacked=$false; ClusterEvidence=@(); HasConfigMismatch=$false
                            ConfigMismatchReason=$null; NeedsHuman=$false; NeedsHumanReason=$null
                            ParseFailed=$false; RawJson='{}'
                        }
                    }
                    Mock Get-AzureToken { [PSCustomObject]@{ Purpose=$Purpose; AccessToken='tok'; TokenType='Bearer'; ExpiresOnUtc=(Get-Date).AddHours(1) } }
                    Mock Get-AzureResourceState { [PSCustomObject]@{ Classification='Connected'; StatusCode=200; ETag='W/"x"'; Tags=$null; Location='eastus'; Name='host-1'; Raw=$null; ErrorMessage=$null } }
                    Mock Invoke-AzcmagentCheck { [PSCustomObject]@{ rawOutput=''; exitCode=0; connectionType='public'; reachableUrls=@(); unreachableUrls=@(); usesProxy=$false; usesPrivateLink=$false; usesGateway=$false; sawAny429=$false; parseFailed=$true } }
                    Mock Test-AgentServices { [PSCustomObject]@{ Services=@(); MissingRequired=@(); StoppedRequired=@(); NeedsHuman=$false; NeedsHumanReason=$null } }
                    Mock Get-AgentCertificateProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-TimeSyncProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-AgentVersionProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Send-LogAnalytics { [PSCustomObject]@{ Success=$false; StatusCode=503; RowCount=1; ErrorMessage='upstream' } }

                    $r = Invoke-ArcRemediation -ConfigPath $cfg -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'Healthy'
                    $r.ExitCode | Should -Be 0
                    $r.LogIngestionFailed | Should -BeTrue
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Missing config file' {
        It 'returns ConfigMismatch (exit 2) without throwing' {
            $missing = Join-Path ([System.IO.Path]::GetTempPath()) "nonexistent-$([guid]::NewGuid()).json"
            $logs = Join-Path ([System.IO.Path]::GetTempPath()) "arc-orch-logs-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Path $logs -Force | Out-Null
            try {
                $r = Invoke-ArcRemediation -ConfigPath $missing -StatePath (Join-Path $logs '..\state.json') -LogDirectory $logs
                $r.Outcome | Should -Be 'ConfigMismatch'
                $r.ExitCode | Should -Be 2
            } finally {
                Remove-Item -LiteralPath $logs -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Self-deadline guard on Expired Enforce path' {
        It 'returns Aborted (not ExpiredRejoinSuccess) when MaxRuntimeMinutes=0 and machine is Expired' {
            $layout = New-EphemeralLayout
            try {
                # Write config with MaxRuntimeMinutes=0 so any positive elapsed time triggers the guard.
                $cfg = [ordered]@{
                    CloudProfile = 'Commercial'
                    MaxRuntimeMinutes = 0
                    ArcCredential = [ordered]@{
                        TenantId='11111111-1111-1111-1111-111111111111'; ClientId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                        CredentialType='ClientSecret'; ClientSecret='lab-secret'; CertificateThumbprint=$null
                    }
                    MonitorCredential = [ordered]@{ UseArcCredential=$true; TenantId=$null; ClientId=$null; CredentialType=$null; ClientSecret=$null; CertificateThumbprint=$null }
                    SubscriptionId = '00000000-0000-0000-0000-000000000000'
                    ScopedResourceGroups = @()
                    LogIngestionEndpoint = 'https://fake-dcr.eastus-1.ingest.monitor.azure.com'
                    DcrImmutableId = 'dcr-imm-test'
                    StreamName = 'Custom-ArcRemediation'
                    KillSwitchUrl = 'https://fake.blob.core.windows.net/arc-remediator/kill-switch.txt?sig=fake&sp=r'
                    PrivateLinkScopeResourceId = $null; ArcGatewayResourceId = $null; ProxyUrl = $null
                    EnableAutomaticAgentUpgrade = $false; CircuitBreakerFailureThreshold = 3
                    Mode = 'Enforce'; Version = '1.0.0'
                }
                ($cfg | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $layout.Config -Encoding UTF8

                InModuleScope ArcRemediator -Parameters @{ cfgPath = $layout.Config; sp = $layout.State; logs = $layout.Logs } {
                    param($cfgPath, $sp, $logs)

                    Mock Get-DecryptedConfig { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
                    Mock Get-KillSwitchState { [PSCustomObject]@{ CanProceed=$true; Reason='Enabled'; LastError=$null } }
                    Mock Get-ArcConnectivitySettings {
                        [PSCustomObject]@{ Proxy=$null; PrivateLinkScopeResourceId=$null; ArcGatewayResourceId=$null
                            Cloud='AzureCloud'; SubscriptionId='00000000-0000-0000-0000-000000000000'
                            ResourceGroupName='rg-prod'; ResourceName='host-1'; Location='eastus'
                            AgentVersion='1.45.0'; AgentStatus='Expired'
                            IsClusterBacked=$false; ClusterEvidence=@(); HasConfigMismatch=$false
                            ConfigMismatchReason=$null; NeedsHuman=$false; NeedsHumanReason=$null
                            ParseFailed=$false; RawJson='{}'
                        }
                    }
                    Mock Get-AzureToken { [PSCustomObject]@{ Purpose=$Purpose; AccessToken='tok'; TokenType='Bearer'; ExpiresOnUtc=(Get-Date).AddHours(1) } }
                    Mock Get-AzureResourceState { [PSCustomObject]@{ Classification='Expired'; StatusCode=200; ETag='W/"x"'; Tags=$null; Location='eastus'; Name='host-1'; Raw=$null; ErrorMessage=$null } }
                    Mock Invoke-AzcmagentCheck { [PSCustomObject]@{ rawOutput=''; exitCode=0; connectionType='public'; reachableUrls=@(); unreachableUrls=@(); usesProxy=$false; usesPrivateLink=$false; usesGateway=$false; sawAny429=$false; parseFailed=$true } }
                    Mock Test-AgentServices { [PSCustomObject]@{ Services=@(); MissingRequired=@(); StoppedRequired=@(); NeedsHuman=$false; NeedsHumanReason=$null } }
                    Mock Get-AgentCertificateProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-TimeSyncProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Get-AgentVersionProbe { [PSCustomObject]@{ Status='OK' } }
                    Mock Invoke-ExpiredRejoin { throw 'Self-deadline guard must prevent this call' }
                    Mock Send-LogAnalytics { [PSCustomObject]@{ Success=$true; StatusCode=204; RowCount=1; ErrorMessage=$null } }

                    $r = Invoke-ArcRemediation -ConfigPath $cfgPath -StatePath $sp -LogDirectory $logs

                    $r.Outcome | Should -Be 'Aborted'
                    $r.OutcomeDetail | Should -Match 'SelfDeadlineHit'
                    Should -Invoke Invoke-ExpiredRejoin -Times 0 -Exactly
                }
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
