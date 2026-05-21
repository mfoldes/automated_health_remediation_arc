#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
}

Describe 'Write-SecurityEventLog' {

    Context 'Source not registered (silent fail)' {
        It 'does not throw when the event source is not registered' {
            InModuleScope ArcRemediator {
                Mock Write-EventLog { throw 'The source ArcRemediator does not exist on the local computer.' }
                # Should complete without error
                { Write-SecurityEventLog -EventId 1001 -Message 'Test' } | Should -Not -Throw
            }
        }
    }

    Context 'Source registered — event written' {
        It 'calls Write-EventLog with the correct EventId' {
            InModuleScope ArcRemediator {
                $script:capturedId = $null
                Mock Write-EventLog {
                    $script:capturedId = $EventId
                }
                Write-SecurityEventLog -EventId 1003 -Message 'Manual reset test'
                $script:capturedId | Should -Be 1003
            }
        }

        It 'passes EntryType=Warning when specified' {
            InModuleScope ArcRemediator {
                $script:capturedEntry = $null
                Mock Write-EventLog {
                    $script:capturedEntry = $EntryType
                }
                Write-SecurityEventLog -EventId 1007 -Message 'Kill switch' -EntryType 'Warning'
                $script:capturedEntry | Should -Be 'Warning'
            }
        }

        It 'defaults EntryType to Information' {
            InModuleScope ArcRemediator {
                $script:capturedEntry = $null
                Mock Write-EventLog {
                    $script:capturedEntry = $EntryType
                }
                Write-SecurityEventLog -EventId 1002 -Message 'Auto reset'
                $script:capturedEntry | Should -Be 'Information'
            }
        }

        It 'uses ArcRemediator as source by default' {
            InModuleScope ArcRemediator {
                $script:capturedSource = $null
                Mock Write-EventLog {
                    $script:capturedSource = $Source
                }
                Write-SecurityEventLog -EventId 1005 -Message 'Rejoin outcome'
                $script:capturedSource | Should -Be 'ArcRemediator'
            }
        }
    }

    Context 'ValidateRange on EventId' {
        It 'rejects an EventId below 1001' {
            InModuleScope ArcRemediator {
                { Write-SecurityEventLog -EventId 1000 -Message 'Out of range' } | Should -Throw
            }
        }

        It 'rejects an EventId above 1007' {
            InModuleScope ArcRemediator {
                { Write-SecurityEventLog -EventId 1008 -Message 'Out of range' } | Should -Throw
            }
        }

        It 'accepts all valid IDs 1001-1007' {
            InModuleScope ArcRemediator {
                Mock Write-EventLog { }
                1001..1007 | ForEach-Object {
                    { Write-SecurityEventLog -EventId $_ -Message "Test $_" } | Should -Not -Throw
                }
            }
        }
    }
}
