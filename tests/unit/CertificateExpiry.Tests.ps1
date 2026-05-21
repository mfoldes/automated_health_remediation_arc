#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
}

Describe 'Get-CertificateExpiryWarning' {

    Context 'Certificate not found' {
        It 'returns null when thumbprint is not in any store' {
            InModuleScope ArcRemediator {
                # A thumbprint that will never exist in CI stores.
                $r = Get-CertificateExpiryWarning -Thumbprint 'DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEE0'
                $r | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Certificate found — expiry scenarios' {
        BeforeEach {
            InModuleScope ArcRemediator {
                # Stub Get-Item to return a synthetic cert object.
                $script:StubbedNotAfter = $null
                Mock Get-Item {
                    if ($script:StubbedNotAfter) {
                        return [PSCustomObject]@{
                            NotAfter   = $script:StubbedNotAfter
                            Thumbprint = 'AABBCC'
                        }
                    }
                    return $null
                }
            }
        }

        It 'returns null when cert expires 31+ days from now' {
            InModuleScope ArcRemediator {
                $script:StubbedNotAfter = (Get-Date).AddDays(31)
                $r = Get-CertificateExpiryWarning -Thumbprint 'AABBCC'
                $r | Should -BeNullOrEmpty
            }
        }

        It 'returns a warning string when cert expires in exactly 30 days (boundary)' {
            InModuleScope ArcRemediator {
                $script:StubbedNotAfter = (Get-Date).AddDays(30).AddMinutes(-1)
                $r = Get-CertificateExpiryWarning -Thumbprint 'AABBCC'
                $r | Should -Not -BeNullOrEmpty
                $r | Should -Match 'expires in'
            }
        }

        It 'returns a warning string when cert expires in 5 days' {
            InModuleScope ArcRemediator {
                # Add a 2-hour buffer so Floor(TotalDays) reliably yields 5 even with sub-ms execution lag.
                $script:StubbedNotAfter = (Get-Date).AddDays(5).AddHours(2)
                $r = Get-CertificateExpiryWarning -Thumbprint 'AABBCC'
                $r | Should -Not -BeNullOrEmpty
                $r | Should -Match '5 days'
            }
        }

        It 'includes the thumbprint in the warning message' {
            InModuleScope ArcRemediator {
                $script:StubbedNotAfter = (Get-Date).AddDays(10)
                $r = Get-CertificateExpiryWarning -Thumbprint 'AABBCC'
                $r | Should -Match 'AABBCC'
            }
        }

        It 'accepts a custom WarningDays threshold' {
            InModuleScope ArcRemediator {
                # Cert expires in 45 days; with WarningDays=60 should warn
                $script:StubbedNotAfter = (Get-Date).AddDays(45)
                $r = Get-CertificateExpiryWarning -Thumbprint 'AABBCC' -WarningDays 60
                $r | Should -Not -BeNullOrEmpty
            }
        }

        It 'returns null when cert is within WarningDays window only by default 30' {
            InModuleScope ArcRemediator {
                # Cert expires in 45 days; default 30-day threshold should not warn
                $script:StubbedNotAfter = (Get-Date).AddDays(45)
                $r = Get-CertificateExpiryWarning -Thumbprint 'AABBCC'
                $r | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Thumbprint normalisation' {
        It 'strips spaces from thumbprint before store lookup' {
            InModuleScope ArcRemediator {
                # Should not throw; spaces stripped and item not found = null returned
                $r = Get-CertificateExpiryWarning -Thumbprint 'AA BB CC DD'
                $r | Should -BeNullOrEmpty
            }
        }
    }
}
