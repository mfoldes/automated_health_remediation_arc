#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force

    $script:SasUrl = 'https://arcmediator.blob.core.windows.net/arc-remediator/kill-switch.txt?sv=2024-01-01&sig=ABCDEFGHIJKLMNOPQRSTUVWXYZ&se=2030-01-01T00:00:00Z&sp=r&sr=b'
    $script:SasSig = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
}

Describe 'Get-KillSwitchState' {

    Context 'Happy path' {
        It "returns CanProceed=true when body is exact 'enabled'" {
            InModuleScope ArcRemediator -Parameters @{ url = $script:SasUrl } {
                param($url)
                Mock Invoke-RestMethodWithTls { return 'enabled' }
                $r = Get-KillSwitchState -KillSwitchUrl $url
                $r.CanProceed | Should -BeTrue
                $r.Reason | Should -Be 'Enabled'
                $r.LastError | Should -BeNullOrEmpty
            }
        }

        It "tolerates trailing whitespace/newlines around 'enabled'" {
            InModuleScope ArcRemediator -Parameters @{ url = $script:SasUrl } {
                param($url)
                Mock Invoke-RestMethodWithTls { return " enabled`r`n" }
                $r = Get-KillSwitchState -KillSwitchUrl $url
                $r.CanProceed | Should -BeTrue
                $r.Reason | Should -Be 'Enabled'
            }
        }

        It "is case-sensitive: 'Enabled' (capital E) does not unlock" {
            InModuleScope ArcRemediator -Parameters @{ url = $script:SasUrl } {
                param($url)
                Mock Invoke-RestMethodWithTls { return 'Enabled' }
                $r = Get-KillSwitchState -KillSwitchUrl $url
                $r.CanProceed | Should -BeFalse
                $r.Reason | Should -Be 'DisabledContent'
            }
        }

        It "any other content pauses with reason DisabledContent" {
            InModuleScope ArcRemediator -Parameters @{ url = $script:SasUrl } {
                param($url)
                Mock Invoke-RestMethodWithTls { return 'paused' }
                $r = Get-KillSwitchState -KillSwitchUrl $url
                $r.CanProceed | Should -BeFalse
                $r.Reason | Should -Be 'DisabledContent'
            }
        }
    }

    Context 'Bad config' {
        It 'returns BadConfig for empty URL' {
            InModuleScope ArcRemediator {
                $r = Get-KillSwitchState -KillSwitchUrl ''
                $r.CanProceed | Should -BeFalse
                $r.Reason | Should -Be 'BadConfig'
            }
        }

        It 'returns BadConfig for non-http(s) URL' {
            InModuleScope ArcRemediator {
                $r = Get-KillSwitchState -KillSwitchUrl 'file:///etc/passwd'
                $r.CanProceed | Should -BeFalse
                $r.Reason | Should -Be 'BadConfig'
            }
        }
    }

    Context 'Error classification and SAS redaction' {
        It 'maps 404 to NotFound and scrubs SAS from LastError' {
            InModuleScope ArcRemediator -Parameters @{ url = $script:SasUrl; sig = $script:SasSig } {
                param($url, $sig)
                Mock Invoke-RestMethodWithTls {
                    $resp = [PSCustomObject]@{ StatusCode = [System.Net.HttpStatusCode]::NotFound }
                    $exc = [System.Net.WebException]::new("The remote server returned an error: 404 Not Found while requesting $url")
                    $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                    throw $exc
                }
                $r = Get-KillSwitchState -KillSwitchUrl $url
                $r.CanProceed | Should -BeFalse
                $r.Reason | Should -Be 'NotFound'
                $r.LastError | Should -Not -Match [regex]::Escape($sig)
                $r.LastError | Should -Not -Match 'sig=[A-Za-z0-9]'
                $r.LastError | Should -Not -Match 'se=2030'
                $r.LastError | Should -Not -Match 'sp=r'
            }
        }

        It 'maps 403 to Forbidden and scrubs SAS' {
            InModuleScope ArcRemediator -Parameters @{ url = $script:SasUrl } {
                param($url)
                Mock Invoke-RestMethodWithTls {
                    $resp = [PSCustomObject]@{ StatusCode = [System.Net.HttpStatusCode]::Forbidden }
                    $exc = [System.Net.WebException]::new("Server returned 403 Forbidden for $url")
                    $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
                    throw $exc
                }
                $r = Get-KillSwitchState -KillSwitchUrl $url
                $r.Reason | Should -Be 'Forbidden'
                $r.LastError | Should -Not -Match 'sig=[A-Za-z0-9]'
            }
        }

        It 'maps timeout/connect failure to Unreachable and scrubs SAS' {
            InModuleScope ArcRemediator -Parameters @{ url = $script:SasUrl; sig = $script:SasSig } {
                param($url, $sig)
                Mock Invoke-RestMethodWithTls {
                    throw "The operation timed out while connecting to $url"
                }
                $r = Get-KillSwitchState -KillSwitchUrl $url
                $r.CanProceed | Should -BeFalse
                $r.Reason | Should -Be 'Unreachable'
                $r.LastError | Should -Not -Match [regex]::Escape($sig)
            }
        }

        It 'redacts SAS query string from a leaked exception message containing the full URL' {
            InModuleScope ArcRemediator -Parameters @{ url = $script:SasUrl; sig = $script:SasSig } {
                param($url, $sig)
                Mock Invoke-RestMethodWithTls {
                    throw "Unhandled error contacting $url - request body and SAS leaked in trace."
                }
                $r = Get-KillSwitchState -KillSwitchUrl $url
                $r.LastError | Should -Not -Match [regex]::Escape($sig)
                $r.LastError | Should -Match 'kill-switch\.txt\?<redacted>'
            }
        }
    }
}
