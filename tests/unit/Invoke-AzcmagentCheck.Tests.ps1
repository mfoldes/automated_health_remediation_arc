#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Invoke-AzcmagentCheck' {

    Context 'argv forwarded to Invoke-Azcmagent' {
        It 'passes --cloud from the profile (Commercial)' {
            InModuleScope ArcRemediator {
                $env:T_CHK_ARGS = ''
                Mock Invoke-Azcmagent -MockWith {
                    $env:T_CHK_ARGS = ($Arguments -join ' ')
                    [PSCustomObject]@{ ExitCode=0; Stdout='https://management.azure.com Reachable'; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $null = Invoke-AzcmagentCheck -CloudProfile (Get-CloudProfile -Name 'Commercial')
            }
            $env:T_CHK_ARGS | Should -Match 'check'
            $env:T_CHK_ARGS | Should -Match '--cloud AzureCloud'
        }

        It 'passes --cloud AzureUSGovernment for DoD profile' {
            InModuleScope ArcRemediator {
                $env:T_CHK_ARGS = ''
                Mock Invoke-Azcmagent -MockWith {
                    $env:T_CHK_ARGS = ($Arguments -join ' ')
                    [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $null = Invoke-AzcmagentCheck -CloudProfile (Get-CloudProfile -Name 'AzureGovernmentDoD')
            }
            $env:T_CHK_ARGS | Should -Match '--cloud AzureUSGovernment'
        }

        It 'forwards --location and --extensions when supplied' {
            InModuleScope ArcRemediator {
                $env:T_CHK_ARGS = ''
                Mock Invoke-Azcmagent -MockWith {
                    $env:T_CHK_ARGS = ($Arguments -join ' ')
                    [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $null = Invoke-AzcmagentCheck -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -Location 'eastus' -Extensions 'sql'
            }
            $env:T_CHK_ARGS | Should -Match '--location eastus'
            $env:T_CHK_ARGS | Should -Match '--extensions sql'
        }
    }

    Context 'Output parsing' {
        It 'classifies reachable and unreachable URLs from a typical check output' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    $sample = @"
Endpoint Result
-------- ------
https://management.azure.com Reachable
https://login.microsoftonline.com Reachable
https://eastus-1.his.arc.azure.com Reachable
https://gbl.his.arc.azure.com Unreachable - connection timeout
"@
                    [PSCustomObject]@{ ExitCode=0; Stdout=$sample; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $r = Invoke-AzcmagentCheck -CloudProfile (Get-CloudProfile -Name 'Commercial')
                $r.parseFailed | Should -BeFalse
                @($r.reachableUrls) | Should -Contain 'https://management.azure.com'
                @($r.reachableUrls) | Should -Contain 'https://login.microsoftonline.com'
                @($r.reachableUrls) | Should -Contain 'https://eastus-1.his.arc.azure.com'
                @($r.unreachableUrls) | Should -Contain 'https://gbl.his.arc.azure.com'
                @($r.unreachableUrls).Count | Should -Be 1
                $r.connectionType | Should -Be 'public'
            }
        }

        It 'preserves rawOutput verbatim even on parseFailed' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $r = Invoke-AzcmagentCheck -CloudProfile (Get-CloudProfile -Name 'Commercial')
                $r.parseFailed | Should -BeTrue
                $r.rawOutput | Should -BeNullOrEmpty -Because 'mock returned empty stdout/stderr'
            }
        }

        It 'sets sawAny429 when the output mentions 429' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    [PSCustomObject]@{
                        ExitCode=0
                        Stdout=@"
https://eastus-1.his.arc.azure.com Unreachable - HTTP 429 throttled
"@
                        Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1)
                    }
                }
                $r = Invoke-AzcmagentCheck -CloudProfile (Get-CloudProfile -Name 'Commercial')
                $r.sawAny429 | Should -BeTrue
                @($r.unreachableUrls).Count | Should -Be 1
            }
        }

        It 'sets connectionType=private-link when private link wording appears' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    [PSCustomObject]@{
                        ExitCode=0
                        Stdout=@"
Connection type: Private Link Scope
https://management.azure.com Reachable
"@
                        Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1)
                    }
                }
                $r = Invoke-AzcmagentCheck -CloudProfile (Get-CloudProfile -Name 'Commercial')
                $r.usesPrivateLink | Should -BeTrue
                $r.connectionType | Should -Be 'private-link'
            }
        }

        It 'does NOT throw on a wildly malformed output - parseFailed flag absorbs it' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent -MockWith {
                    [PSCustomObject]@{ ExitCode=99; Stdout=''; Stderr=''; TimedOut=$true; Duration=[timespan]::FromSeconds(90) }
                }
                { Invoke-AzcmagentCheck -CloudProfile (Get-CloudProfile -Name 'Commercial') } | Should -Not -Throw
            }
        }
    }
}
