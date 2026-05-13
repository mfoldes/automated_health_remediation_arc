#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Wait-ArmAsyncOperation' {

    Context 'Terminal status detection' {
        It 'returns Success on Succeeded' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{
                        StatusCode = 200
                        Content = '{"status":"Succeeded"}'
                        Headers = @{}
                    }
                }
                Mock Start-Sleep {}
                $r = Wait-ArmAsyncOperation -OperationUrl 'https://management.azure.com/op/1' -AccessToken 't' -TimeoutSec 60
                $r.Success | Should -BeTrue
                $r.FinalStatus | Should -Be 'Succeeded'
                $r.TimedOut | Should -BeFalse
            }
        }

        It 'returns failure on Failed with error.message' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{
                        StatusCode = 200
                        Content = '{"status":"Failed","error":{"code":"BadRequest","message":"resource lock present"}}'
                        Headers = @{}
                    }
                }
                Mock Start-Sleep {}
                $r = Wait-ArmAsyncOperation -OperationUrl 'https://management.azure.com/op/1' -AccessToken 't' -TimeoutSec 60
                $r.Success | Should -BeFalse
                $r.FinalStatus | Should -Be 'Failed'
                $r.ErrorMessage | Should -Match 'resource lock present'
            }
        }

        It 'returns failure on Canceled' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{ StatusCode = 200; Content = '{"status":"Canceled"}'; Headers = @{} }
                }
                Mock Start-Sleep {}
                $r = Wait-ArmAsyncOperation -OperationUrl 'https://management.azure.com/op/1' -AccessToken 't' -TimeoutSec 60
                $r.Success | Should -BeFalse
                $r.FinalStatus | Should -Be 'Canceled'
            }
        }
    }

    Context 'Polling cadence' {
        It 'polls multiple times for InProgress and stops on Succeeded' {
            InModuleScope ArcRemediator {
                $env:T_AAO_CALLS = '0'
                Mock Invoke-WebRequestWithTls -MockWith {
                    $env:T_AAO_CALLS = ([int]$env:T_AAO_CALLS + 1).ToString()
                    $body = if ([int]$env:T_AAO_CALLS -lt 3) { '{"status":"InProgress"}' } else { '{"status":"Succeeded"}' }
                    [PSCustomObject]@{ StatusCode = 200; Content = $body; Headers = @{} }
                }
                Mock Start-Sleep {}
                $r = Wait-ArmAsyncOperation -OperationUrl 'https://management.azure.com/op/1' -AccessToken 't' -TimeoutSec 60
                $r.Success | Should -BeTrue
                $r.PollCount | Should -Be 3
            }
        }

        It 'honors Retry-After header when present' {
            InModuleScope ArcRemediator {
                $env:T_AAO_CALLS = '0'
                $env:T_AAO_SLEEPS = ''
                Mock Invoke-WebRequestWithTls -MockWith {
                    $env:T_AAO_CALLS = ([int]$env:T_AAO_CALLS + 1).ToString()
                    if ([int]$env:T_AAO_CALLS -eq 1) {
                        return [PSCustomObject]@{ StatusCode = 200; Content = '{"status":"InProgress"}'; Headers = @{ 'Retry-After' = '13' } }
                    }
                    [PSCustomObject]@{ StatusCode = 200; Content = '{"status":"Succeeded"}'; Headers = @{} }
                }
                Mock Start-Sleep {
                    param($Seconds)
                    $env:T_AAO_SLEEPS = $env:T_AAO_SLEEPS + "$Seconds;"
                }
                $null = Wait-ArmAsyncOperation -OperationUrl 'https://management.azure.com/op/1' -AccessToken 't' -TimeoutSec 60 -MaxBackoffSec 60
            }
            $env:T_AAO_SLEEPS | Should -Match '^13;'
        }

        It 'treats 4xx on the operation URL as terminal failure' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    $resp = [PSCustomObject]@{ StatusCode = 404 }
                    $exc = [System.Net.WebException]::new('not found')
                    $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                    throw $exc
                }
                Mock Start-Sleep {}
                $r = Wait-ArmAsyncOperation -OperationUrl 'https://management.azure.com/op/1' -AccessToken 't' -TimeoutSec 60
                $r.Success | Should -BeFalse
                $r.TimedOut | Should -BeFalse
                $r.ErrorMessage | Should -Match 'HTTP 404'
            }
        }
    }

    Context 'Timeout' {
        It 'returns TimedOut=$true when overall budget is exceeded' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{ StatusCode = 200; Content = '{"status":"InProgress"}'; Headers = @{} }
                }
                # Sleep advances simulated time; Pester's Mock for Start-Sleep
                # is a no-op which would loop forever. Instead, the deadline is
                # set to a past time by giving TimeoutSec = 0; the first iteration
                # will see deadline reached and return TimedOut.
                Mock Start-Sleep {}
                $r = Wait-ArmAsyncOperation -OperationUrl 'https://management.azure.com/op/1' -AccessToken 't' -TimeoutSec 0
                $r.Success | Should -BeFalse
                $r.TimedOut | Should -BeTrue
            }
        }
    }
}
