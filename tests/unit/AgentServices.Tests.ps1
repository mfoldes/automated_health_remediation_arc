#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Test-AgentServices' {

    Context 'All three required services present and running' {
        It 'returns NeedsHuman=$false with no missing/stopped services' {
            InModuleScope ArcRemediator {
                Mock Get-Service -MockWith {
                    param($Name)
                    [PSCustomObject]@{ Name = $Name; Status = 'Running' }
                }
                $r = Test-AgentServices
                $r.NeedsHuman | Should -BeFalse
                @($r.MissingRequired).Count | Should -Be 0
                @($r.StoppedRequired).Count | Should -Be 0
                @($r.Services).Count | Should -Be 4 # 3 required + ArcProxy
            }
        }
    }

    Context 'Missing required service' {
        It 'flags a missing himds as NeedsHuman' {
            InModuleScope ArcRemediator {
                Mock Get-Service -MockWith {
                    param($Name)
                    if ($Name -eq 'himds') { return $null }
                    [PSCustomObject]@{ Name = $Name; Status = 'Running' }
                }
                $r = Test-AgentServices
                $r.NeedsHuman | Should -BeTrue
                $r.NeedsHumanReason | Should -Match 'Missing required services.*himds'
                @($r.MissingRequired) | Should -Contain 'himds'
            }
        }
    }

    Context 'Stopped required service' {
        It 'records GCArcService=Stopped in StoppedRequired but does NOT set NeedsHuman (Repair handles it)' {
            InModuleScope ArcRemediator {
                Mock Get-Service -MockWith {
                    param($Name)
                    if ($Name -eq 'GCArcService') {
                        return [PSCustomObject]@{ Name = $Name; Status = 'Stopped' }
                    }
                    [PSCustomObject]@{ Name = $Name; Status = 'Running' }
                }
                $r = Test-AgentServices
                @($r.StoppedRequired) | Should -Contain 'GCArcService'
                $r.NeedsHuman | Should -BeFalse
            }
        }
    }

    Context 'ArcProxy gating' {
        It 'missing ArcProxy is OK when GatewayRequired=$false (default)' {
            InModuleScope ArcRemediator {
                Mock Get-Service -MockWith {
                    param($Name)
                    if ($Name -eq 'ArcProxy') { return $null }
                    [PSCustomObject]@{ Name = $Name; Status = 'Running' }
                }
                $r = Test-AgentServices
                $r.NeedsHuman | Should -BeFalse
            }
        }

        It 'missing ArcProxy is NeedsHuman when -GatewayRequired:$true' {
            InModuleScope ArcRemediator {
                Mock Get-Service -MockWith {
                    param($Name)
                    if ($Name -eq 'ArcProxy') { return $null }
                    [PSCustomObject]@{ Name = $Name; Status = 'Running' }
                }
                $r = Test-AgentServices -GatewayRequired:$true
                $r.NeedsHuman | Should -BeTrue
                $r.NeedsHumanReason | Should -Match 'Arc Gateway is required'
            }
        }
    }
}

Describe 'Repair-AgentServices' {

    Context 'Restarts a stopped required service' {
        It 'starts a stopped GCArcService and reports it in Restarted' {
            InModuleScope ArcRemediator {
                $env:T_RP_STATE_GCArcService = 'Stopped'
                Mock Get-Service -MockWith {
                    param($Name)
                    $status = 'Running'
                    if ($Name -eq 'GCArcService') {
                        $status = $env:T_RP_STATE_GCArcService
                    }
                    [PSCustomObject]@{ Name = $Name; Status = $status }
                }
                $env:T_RP_STARTED = ''
                Mock Start-Service -MockWith {
                    param($Name)
                    $env:T_RP_STARTED = $Name
                    if ($Name -eq 'GCArcService') {
                        $env:T_RP_STATE_GCArcService = 'Running'
                    }
                }
                $r = Repair-AgentServices
                @($r.Restarted) | Should -Contain 'GCArcService'
                @($r.FailedToRestart) | Should -Not -Contain 'GCArcService'
                $r.NeedsHuman | Should -BeFalse
            }
            $env:T_RP_STARTED | Should -Be 'GCArcService'
        }
    }

    Context 'Service refuses to start (permission, dependency)' {
        It 'records FailedToRestart and surfaces NeedsHuman' {
            InModuleScope ArcRemediator {
                $env:T_RP_STATE_GCArcService = 'Stopped'
                Mock Get-Service -MockWith {
                    param($Name)
                    $status = 'Running'
                    if ($Name -eq 'GCArcService') { $status = $env:T_RP_STATE_GCArcService }
                    [PSCustomObject]@{ Name = $Name; Status = $status }
                }
                Mock Start-Service -MockWith { throw 'access denied' }
                $r = Repair-AgentServices
                @($r.FailedToRestart) | Should -Contain 'GCArcService'
                $r.NeedsHuman | Should -BeTrue
                $r.NeedsHumanReason | Should -Match 'could not be restarted'
            }
        }
    }

    Context 'No work to do' {
        It 'returns Restarted=@() when nothing is stopped' {
            InModuleScope ArcRemediator {
                Mock Get-Service -MockWith {
                    param($Name)
                    [PSCustomObject]@{ Name = $Name; Status = 'Running' }
                }
                Mock Start-Service -MockWith { throw 'should not be called' }
                $r = Repair-AgentServices
                @($r.Restarted).Count | Should -Be 0
                @($r.FailedToRestart).Count | Should -Be 0
                $r.NeedsHuman | Should -BeFalse
                Should -Invoke Start-Service -Times 0 -Exactly
            }
        }
    }
}
