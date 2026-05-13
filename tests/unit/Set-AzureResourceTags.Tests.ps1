#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Set-AzureResourceTags' {

    Context 'Tag merge preserves unrelated tags' {
        It 'removes Remediation=ResetBreaker while preserving env, owner' {
            InModuleScope ArcRemediator {
                Mock Get-AzureResourceState -MockWith {
                    [PSCustomObject]@{
                        Classification = 'Connected'
                        StatusCode = 200
                        ETag = 'W/"merge-1"'
                        Tags = [PSCustomObject]@{
                            env = 'prod'
                            owner = 'sre'
                            Remediation = 'ResetBreaker'
                        }
                        Location = 'eastus'
                        Name = 'm'
                        Raw = $null
                        ErrorMessage = $null
                    }
                }
                $env:T_TG_BODY = ''
                $env:T_TG_IFMATCH = ''
                Mock Invoke-RestMethodWithTls -MockWith {
                    $env:T_TG_BODY = [string]$Body
                    $env:T_TG_IFMATCH = if ($Headers.Contains('If-Match')) { [string]$Headers['If-Match'] } else { '' }
                    return $null
                }
                $r = Set-AzureResourceTags -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'tok' `
                    -RemoveTagKeys @('Remediation')
                $r.Success | Should -BeTrue
                $r.Conflict | Should -BeFalse
                $r.ETag | Should -Be 'W/"merge-1"'
                $r.AppliedTags.Count | Should -Be 2
                $r.AppliedTags.ContainsKey('env') | Should -BeTrue
                $r.AppliedTags.ContainsKey('owner') | Should -BeTrue
                $r.AppliedTags.ContainsKey('Remediation') | Should -BeFalse
            }
            $env:T_TG_IFMATCH | Should -Be 'W/"merge-1"'
            $env:T_TG_BODY | Should -Match '"env":\s*"prod"'
            $env:T_TG_BODY | Should -Match '"owner":\s*"sre"'
            $env:T_TG_BODY | Should -Not -Match 'ResetBreaker'
        }

        It 'sets new tags on top of existing ones' {
            InModuleScope ArcRemediator {
                Mock Get-AzureResourceState -MockWith {
                    [PSCustomObject]@{
                        Classification = 'Connected'; StatusCode = 200; ETag = 'W/"s1"'
                        Tags = [PSCustomObject]@{ env = 'prod' }
                        Location = 'eastus'; Name = 'm'; Raw = $null; ErrorMessage = $null
                    }
                }
                Mock Invoke-RestMethodWithTls -MockWith { return $null }
                $r = Set-AzureResourceTags -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'tok' `
                    -SetTags @{ Remediation = 'Paused' }
                $r.Success | Should -BeTrue
                $r.AppliedTags['env'] | Should -Be 'prod'
                $r.AppliedTags['Remediation'] | Should -Be 'Paused'
            }
        }
    }

    Context 'ETag conflict (412) handling' {
        It 'retries exactly once on the first 412, then succeeds' {
            InModuleScope ArcRemediator {
                $env:T_TG_GET_CALLS = '0'
                $env:T_TG_PATCH_CALLS = '0'
                Mock Get-AzureResourceState -MockWith {
                    $env:T_TG_GET_CALLS = ([int]$env:T_TG_GET_CALLS + 1).ToString()
                    [PSCustomObject]@{
                        Classification = 'Connected'; StatusCode = 200
                        ETag = "W/`"etag-$($env:T_TG_GET_CALLS)`""
                        Tags = [PSCustomObject]@{}
                        Location = 'eastus'; Name = 'm'; Raw = $null; ErrorMessage = $null
                    }
                }
                Mock Invoke-RestMethodWithTls -MockWith {
                    $env:T_TG_PATCH_CALLS = ([int]$env:T_TG_PATCH_CALLS + 1).ToString()
                    if ([int]$env:T_TG_PATCH_CALLS -eq 1) {
                        $resp = [PSCustomObject]@{ StatusCode = 412 }
                        $exc = [System.Net.WebException]::new('precondition failed')
                        $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                        throw $exc
                    }
                    return $null
                }
                $r = Set-AzureResourceTags -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'tok' `
                    -SetTags @{ k = 'v' }
                $r.Success | Should -BeTrue
                $r.Conflict | Should -BeFalse
                $r.ETag | Should -Be 'W/"etag-2"'
            }
            [int]$env:T_TG_GET_CALLS | Should -Be 2
            [int]$env:T_TG_PATCH_CALLS | Should -Be 2
        }

        It 'returns Conflict=$true after the second 412 without a third attempt' {
            InModuleScope ArcRemediator {
                $env:T_TG_PATCH_CALLS = '0'
                Mock Get-AzureResourceState -MockWith {
                    [PSCustomObject]@{
                        Classification = 'Connected'; StatusCode = 200; ETag = 'W/"persistent"'
                        Tags = [PSCustomObject]@{}
                        Location = 'eastus'; Name = 'm'; Raw = $null; ErrorMessage = $null
                    }
                }
                Mock Invoke-RestMethodWithTls -MockWith {
                    $env:T_TG_PATCH_CALLS = ([int]$env:T_TG_PATCH_CALLS + 1).ToString()
                    $resp = [PSCustomObject]@{ StatusCode = 412 }
                    $exc = [System.Net.WebException]::new('still conflicting')
                    $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                    throw $exc
                }
                $r = Set-AzureResourceTags -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'tok' `
                    -SetTags @{ k = 'v' }
                $r.Success | Should -BeFalse
                $r.Conflict | Should -BeTrue
            }
            [int]$env:T_TG_PATCH_CALLS | Should -Be 2
        }
    }

    Context 'ARM not reachable' {
        It 'returns Success=$false (no PATCH) when pre-write GET returns ResourceNotFound' {
            InModuleScope ArcRemediator {
                Mock Get-AzureResourceState -MockWith {
                    [PSCustomObject]@{
                        Classification = 'ResourceNotFound'; StatusCode = 404; ETag = $null
                        Tags = $null; Location = $null; Name = 'm'; Raw = $null
                        ErrorMessage = '404'
                    }
                }
                Mock Invoke-RestMethodWithTls -MockWith { throw 'should not be called' }
                $r = Set-AzureResourceTags -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'tok' `
                    -SetTags @{ k = 'v' }
                $r.Success | Should -BeFalse
                $r.Classification | Should -Be 'ResourceNotFound'
                $r.ErrorMessage | Should -Match 'pre-write ARM GET returned ResourceNotFound'
                Should -Invoke Invoke-RestMethodWithTls -Times 0 -Exactly
            }
        }
    }
}
