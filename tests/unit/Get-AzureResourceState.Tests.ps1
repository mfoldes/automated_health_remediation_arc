#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force

    function script:New-FakeResponse {
        param(
            [Parameter(Mandatory)] [string]$Body,
            [Parameter()] [hashtable]$Headers = @{ ETag = 'W/"fake-etag-1"' }
        )
        [PSCustomObject]@{
            Content = $Body
            StatusCode = 200
            Headers = $Headers
        }
    }

    function script:New-FakeHttpError {
        param([Parameter(Mandatory)] [int]$StatusCode, [Parameter()] [string]$Message = 'mocked')
        $resp = [PSCustomObject]@{ StatusCode = $StatusCode }
        $exc = [System.Net.WebException]::new($Message)
        $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
        $exc
    }
}

Describe 'Get-AzureResourceState' {

    Context 'Status -> classification mapping (200 path)' {
        It 'classifies Connected from properties.status' {
            InModuleScope ArcRemediator {
                $body = '{"id":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.HybridCompute/machines/m","name":"m","location":"eastus","properties":{"status":"Connected"},"tags":{"env":"prod"}}'
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{ Content = $env:T_RS_BODY; StatusCode = 200; Headers = @{ ETag = 'W/"abc"' } }
                }
                $env:T_RS_BODY = $body
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'Connected'
                $r.StatusCode | Should -Be 200
                $r.ETag | Should -Be 'W/"abc"'
                $r.Location | Should -Be 'eastus'
                $r.Tags.env | Should -Be 'prod'
            }
        }

        It 'classifies Disconnected from properties.status' {
            InModuleScope ArcRemediator {
                $env:T_RS_BODY = '{"properties":{"status":"Disconnected"},"location":"eastus","tags":{}}'
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{ Content = $env:T_RS_BODY; StatusCode = 200; Headers = @{ ETag = 'W/"d1"' } }
                }
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'Disconnected'
            }
        }

        It "classifies 200 + properties.status == 'Error' as AzureMachineError (never Expired)" {
            InModuleScope ArcRemediator {
                $env:T_RS_BODY = '{"properties":{"status":"Error"},"location":"eastus","tags":{}}'
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{ Content = $env:T_RS_BODY; StatusCode = 200; Headers = @{ ETag = 'W/"e1"' } }
                }
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'AzureMachineError'
            }
        }

        It 'classifies an unrecognized status string as Unknown' {
            InModuleScope ArcRemediator {
                $env:T_RS_BODY = '{"properties":{"status":"Pending"},"location":"eastus","tags":{}}'
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{ Content = $env:T_RS_BODY; StatusCode = 200; Headers = @{} }
                }
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'Unknown'
            }
        }

        It 'classifies a malformed 200 body as Unknown (no parse, no crash)' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{ Content = '<<<not json>>>'; StatusCode = 200; Headers = @{} }
                }
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'Unknown'
                $r.ErrorMessage | Should -Match 'could not be parsed'
            }
        }
    }

    Context 'HTTP error path' {
        It 'maps 404 to ResourceNotFound' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    $resp = [PSCustomObject]@{ StatusCode = 404 }
                    $exc = [System.Net.WebException]::new('404 not found')
                    $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                    throw $exc
                }
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'ResourceNotFound'
            }
        }

        It 'maps 403 to ArmForbidden' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    $resp = [PSCustomObject]@{ StatusCode = 403 }
                    $exc = [System.Net.WebException]::new('403 forbidden')
                    $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                    throw $exc
                }
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'ArmForbidden'
            }
        }

        It 'maps 429 to ArmThrottled' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    $resp = [PSCustomObject]@{ StatusCode = 429 }
                    $exc = [System.Net.WebException]::new('429 throttled')
                    $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                    throw $exc
                }
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'ArmThrottled'
            }
        }

        It 'maps 500 to ArmTransientFailure' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    $resp = [PSCustomObject]@{ StatusCode = 500 }
                    $exc = [System.Net.WebException]::new('500 server')
                    $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                    throw $exc
                }
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'ArmTransientFailure'
            }
        }

        It 'maps network-level error (no status) to ArmTransientFailure' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith { throw 'DNS resolution failed' }
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'ArmTransientFailure'
            }
        }

        It 'never returns Expired for a 200+Error response' {
            InModuleScope ArcRemediator {
                Mock Invoke-WebRequestWithTls -MockWith {
                    [PSCustomObject]@{
                        Content = '{"properties":{"status":"Error","errorDetails":[{"code":"Expired"}]},"location":"eastus","tags":{}}'
                        StatusCode = 200; Headers = @{}
                    }
                }
                $r = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -SubscriptionId 'sub' -ResourceGroupName 'rg' -MachineName 'm' -AccessToken 'token'
                $r.Classification | Should -Be 'AzureMachineError'
                $r.Classification | Should -Not -Be 'Expired'
            }
        }
    }

    Context 'Request shape' {
        It 'targets the configured ArmEndpoint and api-version' {
            InModuleScope ArcRemediator {
                $env:T_RS_URI = ''
                Mock Invoke-WebRequestWithTls -MockWith {
                    $env:T_RS_URI = $Uri
                    [PSCustomObject]@{
                        Content = '{"properties":{"status":"Connected"},"location":"eastus","tags":{}}'
                        StatusCode = 200; Headers = @{ ETag = 'W/"x"' }
                    }
                }
                $null = Get-AzureResourceState -CloudProfile (Get-CloudProfile -Name 'AzureGovernmentDoD') `
                    -SubscriptionId 'subgov' -ResourceGroupName 'rg-gov' -MachineName 'mgov' -AccessToken 'tok'
                $env:T_RS_URI | Should -Match '^https://management\.usgovcloudapi\.net/subscriptions/subgov/resourceGroups/rg-gov/providers/Microsoft\.HybridCompute/machines/mgov\?api-version=2024-07-10$'
            }
        }
    }
}
