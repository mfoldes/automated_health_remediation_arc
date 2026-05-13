#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Send-LogAnalytics' {

    Context 'URI and body shape' {
        BeforeEach {
            $env:T_SL_URI = ''
            $env:T_SL_BODY = ''
            $env:T_SL_AUTH = ''
            $env:T_SL_CT = ''
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethodWithTls {
                    $env:T_SL_URI = [string]$Uri
                    $env:T_SL_BODY = [string]$Body
                    $env:T_SL_CT = [string]$ContentType
                    $env:T_SL_AUTH = if ($Headers.Contains('Authorization')) { [string]$Headers['Authorization'] } else { '' }
                    return $null
                }
            }
        }

        It 'targets /dataCollectionRules/{immutableId}/streams/{stream}?api-version=2023-01-01' {
            InModuleScope ArcRemediator {
                $r = Send-LogAnalytics `
                    -LogIngestionEndpoint 'https://fake-dcr.eastus-1.ingest.monitor.azure.com' `
                    -DcrImmutableId 'dcr-imm-1' `
                    -AccessToken 'monitor-bearer-token' `
                    -Rows @([PSCustomObject]@{ EventTimeUtc = '2026-05-12T00:00:00Z'; Outcome = 'Healthy' })
                $r.Success | Should -BeTrue
                $r.RowCount | Should -Be 1
            }
            $env:T_SL_URI | Should -Be 'https://fake-dcr.eastus-1.ingest.monitor.azure.com/dataCollectionRules/dcr-imm-1/streams/Custom-ArcRemediation?api-version=2023-01-01'
            $env:T_SL_AUTH | Should -Be 'Bearer monitor-bearer-token'
            $env:T_SL_CT | Should -Be 'application/json'
            $env:T_SL_BODY | Should -Match '^\[.*\]$'
            $env:T_SL_BODY | Should -Match '"EventTimeUtc":\s*"2026-05-12T00:00:00Z"'
            $env:T_SL_BODY | Should -Match '"Outcome":\s*"Healthy"'
        }

        It 'wraps a single row as a JSON array' {
            InModuleScope ArcRemediator {
                $null = Send-LogAnalytics `
                    -LogIngestionEndpoint 'https://x.ingest.monitor.azure.us' `
                    -DcrImmutableId 'dcr-imm-gov' `
                    -AccessToken 'tok' `
                    -Rows @([PSCustomObject]@{ Outcome = 'Healthy' })
            }
            $env:T_SL_BODY.Substring(0,1) | Should -Be '['
            $env:T_SL_BODY.Substring($env:T_SL_BODY.Length - 1, 1) | Should -Be ']'
        }

        It 'trims a trailing slash from LogIngestionEndpoint' {
            InModuleScope ArcRemediator {
                $null = Send-LogAnalytics `
                    -LogIngestionEndpoint 'https://x.ingest.monitor.azure.com/' `
                    -DcrImmutableId 'dcr-imm-x' `
                    -AccessToken 'tok' `
                    -Rows @([PSCustomObject]@{ Outcome = 'Healthy' })
            }
            $env:T_SL_URI | Should -Not -Match '//dataCollectionRules'
        }

        It 'allows StreamName override (other clouds, future-proofing)' {
            InModuleScope ArcRemediator {
                $null = Send-LogAnalytics `
                    -LogIngestionEndpoint 'https://x.ingest.monitor.azure.com' `
                    -DcrImmutableId 'dcr-imm-x' `
                    -AccessToken 'tok' `
                    -StreamName 'Custom-OtherStream' `
                    -Rows @([PSCustomObject]@{ Outcome = 'Healthy' })
            }
            $env:T_SL_URI | Should -Match '/streams/Custom-OtherStream\?api-version=2023-01-01$'
        }
    }

    Context 'Secondary-failure semantics' {
        It 'does NOT throw when the POST fails - returns Success=$false with status' {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethodWithTls {
                    $resp = [PSCustomObject]@{ StatusCode = 403 }
                    $exc = [System.Net.WebException]::new('forbidden by Monitor token scope')
                    $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                    throw $exc
                }
                $r = Send-LogAnalytics `
                    -LogIngestionEndpoint 'https://x.ingest.monitor.azure.com' `
                    -DcrImmutableId 'dcr-x' -AccessToken 'tok' `
                    -Rows @([PSCustomObject]@{ Outcome = 'Healthy' })
                $r.Success | Should -BeFalse
                $r.StatusCode | Should -Be 403
                $r.ErrorMessage | Should -Match 'forbidden'
                $r.RowCount | Should -Be 1
            }
        }

        It 'does NOT throw on network/transport error' {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethodWithTls { throw 'connection reset' }
                $r = Send-LogAnalytics `
                    -LogIngestionEndpoint 'https://x.ingest.monitor.azure.com' `
                    -DcrImmutableId 'dcr-x' -AccessToken 'tok' `
                    -Rows @([PSCustomObject]@{ Outcome = 'Healthy' })
                $r.Success | Should -BeFalse
                $r.StatusCode | Should -BeNullOrEmpty
            }
        }

        It 'returns failure (no POST) when Rows is empty' {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethodWithTls { throw 'should not be called' }
                $r = Send-LogAnalytics `
                    -LogIngestionEndpoint 'https://x.ingest.monitor.azure.com' `
                    -DcrImmutableId 'dcr-x' -AccessToken 'tok' -Rows @()
                $r.Success | Should -BeFalse
                $r.RowCount | Should -Be 0
                Should -Invoke Invoke-RestMethodWithTls -Times 0 -Exactly
            }
        }
    }
}
