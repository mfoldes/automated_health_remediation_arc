#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force

    function script:New-HealthyConnectivity {
        [PSCustomObject]@{
            Proxy = $null; PrivateLinkScopeResourceId = $null; ArcGatewayResourceId = $null
            Cloud = 'AzureCloud'; SubscriptionId = 'sub'; ResourceGroupName = 'rg'; ResourceName = 'm'; Location = 'eastus'
            AgentVersion = '1.45.0'; AgentStatus = 'Expired'
            IsClusterBacked = $false; ClusterEvidence = @(); HasConfigMismatch = $false; ConfigMismatchReason = $null
            NeedsHuman = $false; NeedsHumanReason = $null; ParseFailed = $false; RawJson = '{}'
        }
    }
    function script:New-CertCredential {
        [PSCustomObject]@{
            TenantId='t'; ClientId='c'; CredentialType='Certificate'
            CertificateThumbprint=('A'*40); ClientSecret=$null
        }
    }
    function script:New-EphemeralStatePath {
        Join-Path ([System.IO.Path]::GetTempPath()) ("arc-rejoin-state-$([guid]::NewGuid().ToString('N')).json")
    }
}

Describe 'Invoke-ExpiredRejoin' {

    Context 'Cluster-backed gate' {
        It 'returns NeedsHuman and writes NO marker when ConnectivitySettings.IsClusterBacked' {
            $cs = New-HealthyConnectivity
            $cs.IsClusterBacked = $true
            $cs.NeedsHumanReason = 'clusterResourceId=...'
            $cs.NeedsHuman = $true

            InModuleScope ArcRemediator -Parameters @{ cs = $cs; cred = New-CertCredential; sp = New-EphemeralStatePath } {
                param($cs, $cred, $sp)
                Mock Get-AzureResourceState { throw 'should not be called' }
                Mock Remove-ArcResource { throw 'should not be called' }
                Mock Invoke-AzcmagentConnect { throw 'should not be called' }
                Mock Set-RemediatorState { throw 'marker must not be written for cluster-backed' }

                $r = Invoke-ExpiredRejoin -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -ArcCredential $cred -AccessToken 'tok' `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' `
                    -ConnectivitySettings $cs -StatePath $sp -Confirm:$false

                $r.Outcome | Should -Be 'NeedsHuman'
                $r.MarkerWritten | Should -BeFalse
            }
        }

        It 'returns ConfigMismatch and writes NO marker when DoD+gateway mismatch' {
            $cs = New-HealthyConnectivity
            $cs.HasConfigMismatch = $true
            $cs.ConfigMismatchReason = 'Arc Gateway is configured locally but the active cloud profile (SupportsArcGateway=False) does not support gateway.'

            InModuleScope ArcRemediator -Parameters @{ cs = $cs; cred = New-CertCredential; sp = New-EphemeralStatePath } {
                param($cs, $cred, $sp)
                Mock Get-AzureResourceState { throw 'should not be called' }
                Mock Set-RemediatorState { throw 'marker must not be written for config mismatch' }

                $r = Invoke-ExpiredRejoin -CloudProfile (Get-CloudProfile -Name 'AzureGovernmentDoD') `
                    -ArcCredential $cred -AccessToken 'tok' `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' `
                    -ConnectivitySettings $cs -StatePath $sp -Confirm:$false

                $r.Outcome | Should -Be 'ConfigMismatch'
                $r.MarkerWritten | Should -BeFalse
            }
        }
    }

    Context 'Pre-destructive re-read state changed - safe abort' {
        It 'returns Aborted (no marker) when ARM re-read no longer classifies as Expired' {
            InModuleScope ArcRemediator -Parameters @{ cs = New-HealthyConnectivity; cred = New-CertCredential; sp = New-EphemeralStatePath } {
                param($cs, $cred, $sp)
                Mock Get-AzureResourceState -MockWith {
                    [PSCustomObject]@{ Classification = 'Connected'; StatusCode = 200; ETag = 'W/"x"'; Tags = $null; Location = 'eastus'; Name = 'm'; Raw = $null; ErrorMessage = $null }
                }
                Mock Remove-ArcResource { throw 'should not be called' }
                Mock Set-RemediatorState { throw 'marker must NOT be written when aborting before destructive' }

                $r = Invoke-ExpiredRejoin -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -ArcCredential $cred -AccessToken 'tok' `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' `
                    -ConnectivitySettings $cs -StatePath $sp -Confirm:$false

                $r.Outcome | Should -Be 'Aborted'
                $r.MarkerWritten | Should -BeFalse
                $r.Detail | Should -Match 'Connected'
            }
        }
    }

    Context 'WhatIf skips destructive path and writes NO marker' {
        It 'returns WhatIf without writing the cooldown marker' {
            InModuleScope ArcRemediator -Parameters @{ cs = New-HealthyConnectivity; cred = New-CertCredential; sp = New-EphemeralStatePath } {
                param($cs, $cred, $sp)
                Mock Get-AzureResourceState -MockWith {
                    [PSCustomObject]@{ Classification = 'Expired'; StatusCode = 200; ETag = 'W/"e"'; Tags = ([PSCustomObject]@{ env = 'prod' }); Location = 'eastus'; Name = 'm'; Raw = $null; ErrorMessage = $null }
                }
                Mock Remove-ArcResource { throw 'should not be called' }
                Mock Set-RemediatorState { throw 'marker must NOT be written for WhatIf' }
                $r = Invoke-ExpiredRejoin -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -ArcCredential $cred -AccessToken 'tok' `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' `
                    -ConnectivitySettings $cs -StatePath $sp -WhatIf
                $r.Outcome | Should -Be 'WhatIf'
                $r.MarkerWritten | Should -BeFalse
            }
        }
    }

    Context 'Happy path: full delete + connect + tag restore + verify' {
        It 'writes marker InProgress, runs the sequence, returns ExpiredRejoined with Completed marker' {
            $statePath = New-EphemeralStatePath
            try {
                InModuleScope ArcRemediator -Parameters @{ cs = New-HealthyConnectivity; cred = New-CertCredential; sp = $statePath } {
                    param($cs, $cred, $sp)
                    $env:T_ER_CALLS = '0'
                    Mock Get-AzureResourceState -MockWith {
                        $env:T_ER_CALLS = ([int]$env:T_ER_CALLS + 1).ToString()
                        if ([int]$env:T_ER_CALLS -le 1) {
                            return [PSCustomObject]@{
                                Classification = 'Expired'; StatusCode = 200; ETag = 'W/"pre"'
                                Tags = ([PSCustomObject]@{ env = 'prod'; owner = 'sre' })
                                Location = 'eastus'; Name = 'm'; Raw = $null; ErrorMessage = $null
                            }
                        }
                        return [PSCustomObject]@{
                            Classification = 'Connected'; StatusCode = 200; ETag = 'W/"post"'
                            Tags = ([PSCustomObject]@{}); Location = 'eastus'; Name = 'm'; Raw = $null; ErrorMessage = $null
                        }
                    }
                    Mock Remove-ArcResource -MockWith {
                        [PSCustomObject]@{ Success=$true; InitialStatusCode=204; AsyncOperationUrl=$null; AsyncResult=$null; Verified404=$true; ElapsedSeconds=2; ErrorMessage=$null }
                    }
                    Mock Invoke-AzcmagentDisconnect -MockWith {
                        [PSCustomObject]@{ ExitCode=0; Stdout='disconnected'; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                    }
                    Mock Invoke-AzcmagentConnect -MockWith {
                        [PSCustomObject]@{
                            ProcessResult = [PSCustomObject]@{ ExitCode=0; Stdout='ok'; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                            UsedConfigFile = $false
                            GatewayHonored = $false
                            AutomaticUpgradeHonored = $false
                            WhatIf = $false
                        }
                    }
                    Mock Set-AzureResourceTags -MockWith {
                        param($SetTags)
                        [PSCustomObject]@{ Success=$true; Classification='Connected'; Conflict=$false; ETag='W/"post"'; AppliedTags=$SetTags; ErrorMessage=$null }
                    }

                    $r = Invoke-ExpiredRejoin -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                        -ArcCredential $cred -AccessToken 'tok' `
                        -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' `
                        -ConnectivitySettings $cs -StatePath $sp -Confirm:$false

                    $r.Outcome | Should -Be 'ExpiredRejoined'
                    $r.MarkerWritten | Should -BeTrue
                    $r.AttemptId | Should -Not -BeNullOrEmpty
                    $r.FinalState.Classification | Should -Be 'Connected'
                    Should -Invoke Remove-ArcResource -Times 1 -Exactly
                    Should -Invoke Invoke-AzcmagentDisconnect -Times 1 -Exactly
                    Should -Invoke Invoke-AzcmagentConnect -Times 1 -Exactly
                    Should -Invoke Set-AzureResourceTags -Times 1 -Exactly
                }
                # State file should now exist with Outcome=Completed.
                (Test-Path -LiteralPath $statePath) | Should -BeTrue
                $persisted = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                $persisted.LastExpiredAttemptOutcome | Should -Be 'Completed'
                $persisted.LastExpiredAttemptCompletedUtc | Should -Not -BeNullOrEmpty
                $persisted.LastExpiredAttemptId | Should -Not -BeNullOrEmpty
            } finally {
                Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Marker is written BEFORE the first destructive call' {
        It 'leaves DeleteFailed marker (with cooldown timestamp) when DELETE fails after marker write' {
            $statePath = New-EphemeralStatePath
            try {
                InModuleScope ArcRemediator -Parameters @{ cs = New-HealthyConnectivity; cred = New-CertCredential; sp = $statePath } {
                    param($cs, $cred, $sp)
                    Mock Get-AzureResourceState -MockWith {
                        [PSCustomObject]@{
                            Classification = 'Expired'; StatusCode = 200; ETag = 'W/"pre"'
                            Tags = $null; Location = 'eastus'; Name = 'm'; Raw = $null; ErrorMessage = $null
                        }
                    }
                    Mock Remove-ArcResource -MockWith {
                        [PSCustomObject]@{ Success=$false; InitialStatusCode=403; AsyncOperationUrl=$null; AsyncResult=$null; Verified404=$null; ElapsedSeconds=1; ErrorMessage='Forbidden' }
                    }
                    Mock Invoke-AzcmagentDisconnect { throw 'should not be called after DELETE failure' }
                    Mock Invoke-AzcmagentConnect { throw 'should not be called after DELETE failure' }

                    $r = Invoke-ExpiredRejoin -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                        -ArcCredential $cred -AccessToken 'tok' `
                        -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' `
                        -ConnectivitySettings $cs -StatePath $sp -Confirm:$false

                    $r.Outcome | Should -Be 'ExpiredRejoinFailure'
                    $r.MarkerWritten | Should -BeTrue
                    $r.Detail | Should -Match 'Forbidden'
                }
                $persisted = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                $persisted.LastExpiredAttemptOutcome | Should -Be 'DeleteFailed'
                $persisted.LastExpiredAttemptStartedUtc | Should -Not -BeNullOrEmpty
            } finally {
                Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Tag restoration uses Set-AzureResourceTags, NOT azcmagent connect --tags' {
        It 'restores every original tag via ARM PATCH after connect succeeds' {
            $statePath = New-EphemeralStatePath
            try {
                InModuleScope ArcRemediator -Parameters @{ cs = New-HealthyConnectivity; cred = New-CertCredential; sp = $statePath } {
                    param($cs, $cred, $sp)
                    $env:T_ER_TAGS_CALL = ''
                    $env:T_ER_CALLS = '0'
                    Mock Get-AzureResourceState -MockWith {
                        $env:T_ER_CALLS = ([int]$env:T_ER_CALLS + 1).ToString()
                        if ([int]$env:T_ER_CALLS -le 1) {
                            return [PSCustomObject]@{
                                Classification='Expired'; StatusCode=200; ETag='W/"pre"'
                                Tags=([PSCustomObject]@{ env='prod'; owner='sre'; cost='cc-42' })
                                Location='eastus'; Name='m'; Raw=$null; ErrorMessage=$null
                            }
                        }
                        return [PSCustomObject]@{ Classification='Connected'; StatusCode=200; ETag='W/"post"'; Tags=$null; Location='eastus'; Name='m'; Raw=$null; ErrorMessage=$null }
                    }
                    Mock Remove-ArcResource { [PSCustomObject]@{ Success=$true; InitialStatusCode=204; AsyncOperationUrl=$null; AsyncResult=$null; Verified404=$true; ElapsedSeconds=1; ErrorMessage=$null } }
                    Mock Invoke-AzcmagentDisconnect { [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) } }
                    Mock Invoke-AzcmagentConnect {
                        param($CloudProfile, $Credential, $SubscriptionId, $ResourceGroupName, $MachineName, $Location, $ProxyUrl, $PrivateLinkScopeResourceId, $ArcGatewayResourceId, $EnableAutomaticUpgrade, $TimeoutSec, $AzcmagentPath)
                        [PSCustomObject]@{
                            ProcessResult = [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                            UsedConfigFile = $false; GatewayHonored=$false; AutomaticUpgradeHonored=$false; WhatIf=$false
                        }
                    }
                    Mock Set-AzureResourceTags {
                        param($CloudProfile, $SubscriptionId, $ResourceGroupName, $MachineName, $AccessToken, $SetTags, $RemoveTagKeys, $TimeoutSec, $ApiVersion)
                        $env:T_ER_TAGS_CALL = ($SetTags.Keys | Sort-Object) -join ','
                        [PSCustomObject]@{ Success=$true; Classification='Connected'; Conflict=$false; ETag='W/"post"'; AppliedTags=$SetTags; ErrorMessage=$null }
                    }

                    $r = Invoke-ExpiredRejoin -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                        -ArcCredential $cred -AccessToken 'tok' `
                        -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' `
                        -ConnectivitySettings $cs -StatePath $sp -Confirm:$false

                    $r.Outcome | Should -Be 'ExpiredRejoined'
                }
                $env:T_ER_TAGS_CALL | Should -Be 'cost,env,owner'
            } finally {
                Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
            }
        }
    }
}
