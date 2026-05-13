#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force

    function script:New-FakeConnectivity {
        param([string]$AgentVersion, [string]$RawJson = '{}')
        [PSCustomObject]@{ AgentVersion = $AgentVersion; RawJson = $RawJson }
    }
}

Describe 'Get-AgentVersionProbe' {

    It 'reports Status=OK when current version >= floor' {
        InModuleScope ArcRemediator {
            $cs = [PSCustomObject]@{ AgentVersion = '1.45.0'; RawJson = '{}' }
            $r = Get-AgentVersionProbe -ConnectivitySettings $cs -SupportedFloor '1.40.0'
            $r.Status | Should -Be 'OK'
            $r.MeetsFloor | Should -BeTrue
        }
    }

    It 'reports Status=Below when current version < floor' {
        InModuleScope ArcRemediator {
            $cs = [PSCustomObject]@{ AgentVersion = '1.32.0'; RawJson = '{}' }
            $r = Get-AgentVersionProbe -ConnectivitySettings $cs -SupportedFloor '1.40.0'
            $r.Status | Should -Be 'Below'
            $r.MeetsFloor | Should -BeFalse
        }
    }

    It 'reports Status=Unknown with MeetsFloor=$null when AgentVersion is missing' {
        InModuleScope ArcRemediator {
            $cs = [PSCustomObject]@{ AgentVersion = $null; RawJson = '{}' }
            $r = Get-AgentVersionProbe -ConnectivitySettings $cs -SupportedFloor '1.40.0'
            $r.Status | Should -Be 'Unknown'
            $r.MeetsFloor | Should -BeNullOrEmpty
        }
    }

    It 'reports Status=Unknown with MeetsFloor=$null when version is unparseable' {
        InModuleScope ArcRemediator {
            $cs = [PSCustomObject]@{ AgentVersion = 'NOT_A_VERSION'; RawJson = '{}' }
            $r = Get-AgentVersionProbe -ConnectivitySettings $cs -SupportedFloor '1.40.0'
            $r.Status | Should -Be 'Unknown'
            $r.MeetsFloor | Should -BeNullOrEmpty
        }
    }

    It 'compares minor and patch components correctly (1.45.0 < 1.45.10)' {
        InModuleScope ArcRemediator {
            $cs = [PSCustomObject]@{ AgentVersion = '1.45.0'; RawJson = '{}' }
            $r = Get-AgentVersionProbe -ConnectivitySettings $cs -SupportedFloor '1.45.10'
            $r.Status | Should -Be 'Below'
        }
    }
}

Describe 'Get-TimeSyncProbe' {

    Context 'w32tm not present' {
        It 'returns Status=Unknown without throwing' {
            InModuleScope ArcRemediator {
                $r = Get-TimeSyncProbe -W32tmPath 'C:\does\not\exist\w32tm.exe'
                $r.Status | Should -Be 'Unknown'
                $r.OffsetSeconds | Should -BeNullOrEmpty
                $r.IsWithinTolerance | Should -BeNullOrEmpty
            }
        }
    }

    # w32tm is present on every Windows host the tests run on; use it directly.
    Context 'Live w32tm invocation (Windows)' -Skip:(-not (Test-Path -LiteralPath "$env:WINDIR\System32\w32tm.exe")) {
        It 'returns a result without throwing (status may be OK, Drift, or Unknown depending on host config)' {
            InModuleScope ArcRemediator {
                { Get-TimeSyncProbe } | Should -Not -Throw
                $r = Get-TimeSyncProbe
                @('OK','Drift','Unknown') | Should -Contain $r.Status
                # If status is OK / Drift, OffsetSeconds must be numeric; if Unknown, it may be null.
                if ($r.Status -ne 'Unknown') {
                    $r.OffsetSeconds | Should -BeGreaterThan -0.0001 -Because 'absolute offset is non-negative'
                }
            }
        }
    }
}

Describe 'Get-AgentCertificateProbe' {

    Context 'azcmagent show exposes cert metadata' {
        It 'computes DaysUntilExpiry and Status=OK when the cert is healthy' {
            InModuleScope ArcRemediator {
                $cs = [PSCustomObject]@{
                    AgentVersion = '1.45.0'
                    RawJson = '{"certificateNotBefore":"2026-01-01T00:00:00Z","certificateNotAfter":"2027-01-01T00:00:00Z"}'
                }
                $r = Get-AgentCertificateProbe -ConnectivitySettings $cs -Now ([datetime]::Parse('2026-05-12T00:00:00Z')).ToUniversalTime()
                $r.Status | Should -Be 'OK'
                $r.IsExpired | Should -BeFalse
                $r.DaysUntilExpiry | Should -BeGreaterThan 200
                $r.Source | Should -Be 'azcmagent-show'
            }
        }

        It 'flags Status=NearExpiry within 14 days' {
            InModuleScope ArcRemediator {
                $cs = [PSCustomObject]@{
                    AgentVersion = '1.45.0'
                    RawJson = '{"certificateNotAfter":"2026-05-20T00:00:00Z"}'
                }
                $r = Get-AgentCertificateProbe -ConnectivitySettings $cs -Now ([datetime]::Parse('2026-05-12T00:00:00Z')).ToUniversalTime()
                $r.Status | Should -Be 'NearExpiry'
                $r.IsExpired | Should -BeFalse
            }
        }

        It 'flags Status=Expired when NotAfter is in the past' {
            InModuleScope ArcRemediator {
                $cs = [PSCustomObject]@{
                    AgentVersion = '1.45.0'
                    RawJson = '{"certificateNotAfter":"2026-01-01T00:00:00Z"}'
                }
                $r = Get-AgentCertificateProbe -ConnectivitySettings $cs -Now ([datetime]::Parse('2026-05-12T00:00:00Z')).ToUniversalTime()
                $r.Status | Should -Be 'Expired'
                $r.IsExpired | Should -BeTrue
            }
        }
    }

    Context 'azcmagent show does not expose cert metadata' {
        It 'returns Status=Unavailable without inspecting HIMDS internals' {
            InModuleScope ArcRemediator {
                $cs = [PSCustomObject]@{
                    AgentVersion = '1.30.0'
                    RawJson = '{"agentVersion":"1.30.0","cloud":"AzureCloud"}'
                }
                $r = Get-AgentCertificateProbe -ConnectivitySettings $cs
                $r.Status | Should -Be 'Unavailable'
                $r.Source | Should -Be 'unavailable'
            }
        }

        It 'returns Status=Unavailable when RawJson is missing or empty' {
            InModuleScope ArcRemediator {
                $r = Get-AgentCertificateProbe -ConnectivitySettings ([PSCustomObject]@{ RawJson = '' })
                $r.Status | Should -Be 'Unavailable'
            }
        }
    }
}
