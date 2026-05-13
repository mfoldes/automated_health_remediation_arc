#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Remove-ArcResource' {

    Context '204 No Content path' {
        It 'returns Success with Verified404 after a 204 + GET 404' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{ StatusCode = 204; Content = ''; Headers = @{} }
                }
                Mock Get-AzureResourceState -MockWith {
                    [PSCustomObject]@{ Classification = 'ResourceNotFound'; StatusCode = 404; ETag = $null; Tags = $null; Location = $null; Name = 'm'; Raw = $null; ErrorMessage = $null }
                }
                $r = Remove-ArcResource -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 's' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 't' -Confirm:$false
                $r.Success | Should -BeTrue
                $r.InitialStatusCode | Should -Be 204
                $r.Verified404 | Should -BeTrue
            }
        }
    }

    Context '404 on DELETE is idempotent success' {
        It 'returns Success when ARM DELETE returns 404 (already gone)' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    $resp = [PSCustomObject]@{ StatusCode = 404 }
                    $exc = [System.Net.WebException]::new('not found')
                    $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                    throw $exc
                }
                Mock Get-AzureResourceState -MockWith { throw 'should not be called' }
                $r = Remove-ArcResource -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 's' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 't' -Confirm:$false
                $r.Success | Should -BeTrue
                $r.InitialStatusCode | Should -Be 404
                $r.Verified404 | Should -BeTrue
            }
        }
    }

    Context '202 Accepted async path' {
        It 'reads Azure-AsyncOperation header, polls, verifies 404' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{
                        StatusCode = 202
                        Content = ''
                        Headers = @{ 'Azure-AsyncOperation' = 'https://management.azure.com/op/abc' }
                    }
                }
                Mock Wait-ArmAsyncOperation -MockWith {
                    [PSCustomObject]@{ Success = $true; FinalStatus = 'Succeeded'; TimedOut = $false; ElapsedSeconds = 12; PollCount = 3; ErrorMessage = $null }
                }
                Mock Get-AzureResourceState -MockWith {
                    [PSCustomObject]@{ Classification = 'ResourceNotFound'; StatusCode = 404; ETag = $null; Tags = $null; Location = $null; Name = 'm'; Raw = $null; ErrorMessage = $null }
                }
                $r = Remove-ArcResource -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 's' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 't' -Confirm:$false
                $r.Success | Should -BeTrue
                $r.InitialStatusCode | Should -Be 202
                $r.AsyncOperationUrl | Should -Be 'https://management.azure.com/op/abc'
                $r.Verified404 | Should -BeTrue
            }
        }

        It 'falls back to Location header when Azure-AsyncOperation is absent' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{
                        StatusCode = 202
                        Content = ''
                        Headers = @{ 'Location' = 'https://management.azure.com/op/loc1' }
                    }
                }
                Mock Wait-ArmAsyncOperation -MockWith {
                    [PSCustomObject]@{ Success = $true; FinalStatus = 'Succeeded'; TimedOut = $false; ElapsedSeconds = 1; PollCount = 1; ErrorMessage = $null }
                }
                Mock Get-AzureResourceState -MockWith {
                    [PSCustomObject]@{ Classification = 'ResourceNotFound'; StatusCode = 404; ETag = $null; Tags = $null; Location = $null; Name = 'm'; Raw = $null; ErrorMessage = $null }
                }
                $r = Remove-ArcResource -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 's' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 't' -Confirm:$false
                $r.AsyncOperationUrl | Should -Match '/op/loc1$'
            }
        }

        It 'fails closed when 202 returns with no usable header' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{ StatusCode = 202; Content = ''; Headers = @{} }
                }
                $r = Remove-ArcResource -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 's' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 't' -Confirm:$false
                $r.Success | Should -BeFalse
                $r.ErrorMessage | Should -Match 'neither Azure-AsyncOperation nor Location'
            }
        }

        It 'propagates async Failed up as Success=$false with the error message' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{
                        StatusCode = 202
                        Content = ''
                        Headers = @{ 'Azure-AsyncOperation' = 'https://management.azure.com/op/abc' }
                    }
                }
                Mock Wait-ArmAsyncOperation -MockWith {
                    [PSCustomObject]@{ Success = $false; FinalStatus = 'Failed'; TimedOut = $false; ElapsedSeconds = 12; PollCount = 3; ErrorMessage = 'Async operation Failed: dependency conflict' }
                }
                $r = Remove-ArcResource -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 's' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 't' -Confirm:$false
                $r.Success | Should -BeFalse
                $r.ErrorMessage | Should -Match 'dependency conflict'
            }
        }
    }

    Context '202 verification failure' {
        It "Success=$false when async Succeeded but post-GET still finds the resource" {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{ StatusCode = 202; Content = ''; Headers = @{ 'Azure-AsyncOperation' = 'https://management.azure.com/op/abc' } }
                }
                Mock Wait-ArmAsyncOperation -MockWith {
                    [PSCustomObject]@{ Success = $true; FinalStatus = 'Succeeded'; TimedOut = $false; ElapsedSeconds = 1; PollCount = 1; ErrorMessage = $null }
                }
                Mock Get-AzureResourceState -MockWith {
                    [PSCustomObject]@{ Classification = 'Connected'; StatusCode = 200; ETag = 'W/"x"'; Tags = $null; Location = 'eastus'; Name = 'm'; Raw = $null; ErrorMessage = $null }
                }
                $r = Remove-ArcResource -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 's' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 't' -Confirm:$false
                $r.Success | Should -BeFalse
                $r.Verified404 | Should -BeFalse
                $r.ErrorMessage | Should -Match 'did not return 404'
            }
        }
    }

    Context 'WhatIf safety' {
        It 'does NOT call ARM DELETE under -WhatIf' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith { throw 'should not be called' }
                Mock Get-AzureResourceState -MockWith { throw 'should not be called' }
                $r = Remove-ArcResource -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 's' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 't' -WhatIf
                $r.Success | Should -BeFalse
                $r.ErrorMessage | Should -Match 'WhatIf'
                Should -Invoke Invoke-WebRequestWithTls -Times 0 -Exactly
            }
        }
    }
}
