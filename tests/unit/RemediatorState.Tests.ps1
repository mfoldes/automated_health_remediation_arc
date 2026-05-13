#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ManifestPath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
}

Describe 'New-DefaultRemediatorState' {
    It 'returns an object with every documented field at its default' {
        InModuleScope ArcRemediator {
            $s = New-DefaultRemediatorState
            $s.LastSuccessfulRunUtc | Should -BeNullOrEmpty
            $s.ConsecutiveFailures | Should -Be 0
            $s.BreakerTripped | Should -BeFalse
            $s.BreakerLastResetUtc | Should -BeNullOrEmpty
            $s.LastExpiredAttemptId | Should -BeNullOrEmpty
            $s.LastExpiredAttemptResourceId | Should -BeNullOrEmpty
            $s.LastExpiredAttemptStartedUtc | Should -BeNullOrEmpty
            $s.LastExpiredAttemptCompletedUtc | Should -BeNullOrEmpty
            $s.LastExpiredAttemptOutcome | Should -BeNullOrEmpty
            $s.ResetByUser | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-RemediatorState' {

    Context 'Missing file' {
        It 'returns defaults when the state file does not exist' {
            $path = Join-Path $TestDrive ('state-missing-{0}.json' -f ([guid]::NewGuid()))
            InModuleScope ArcRemediator -Parameters @{ p = $path } {
                param($p)
                $s = Get-RemediatorState -Path $p
                $s.ConsecutiveFailures | Should -Be 0
                $s.BreakerTripped | Should -BeFalse
            }
        }
    }

    Context 'Corrupt file (refuses to silently default)' {
        It 'throws on an empty state file' {
            $path = Join-Path $TestDrive ('state-empty-{0}.json' -f ([guid]::NewGuid()))
            Set-Content -LiteralPath $path -Value '' -NoNewline
            InModuleScope ArcRemediator -Parameters @{ p = $path } {
                param($p)
                { Get-RemediatorState -Path $p } | Should -Throw -ExpectedMessage '*empty*'
            }
        }

        It 'throws on a whitespace-only state file' {
            $path = Join-Path $TestDrive ('state-ws-{0}.json' -f ([guid]::NewGuid()))
            Set-Content -LiteralPath $path -Value " `n " -NoNewline
            InModuleScope ArcRemediator -Parameters @{ p = $path } {
                param($p)
                { Get-RemediatorState -Path $p } | Should -Throw -ExpectedMessage '*empty*'
            }
        }

        It 'throws on invalid JSON' {
            $path = Join-Path $TestDrive ('state-bad-{0}.json' -f ([guid]::NewGuid()))
            Set-Content -LiteralPath $path -Value '{not valid json' -NoNewline
            InModuleScope ArcRemediator -Parameters @{ p = $path } {
                param($p)
                { Get-RemediatorState -Path $p } | Should -Throw -ExpectedMessage '*invalid JSON*'
            }
        }
    }
}

Describe 'Set-RemediatorState' {

    Context 'Atomic write' {
        It 'creates the parent directory if absent' {
            $dir = Join-Path $TestDrive ('state-newdir-{0}' -f ([guid]::NewGuid()))
            $path = Join-Path $dir 'state.json'
            (Test-Path $dir) | Should -BeFalse

            InModuleScope ArcRemediator -Parameters @{ p = $path } {
                param($p)
                $s = New-DefaultRemediatorState
                Set-RemediatorState -State $s -Path $p
            }

            (Test-Path $path) | Should -BeTrue
        }

        It 'writes via a .tmp file and renames to the destination' {
            $path = Join-Path $TestDrive ('state-atomic-{0}.json' -f ([guid]::NewGuid()))
            $tempPath = "$path.tmp"

            InModuleScope ArcRemediator -Parameters @{ p = $path } {
                param($p)
                $s = New-DefaultRemediatorState
                Set-RemediatorState -State $s -Path $p
            }

            (Test-Path $tempPath) | Should -BeFalse
            (Test-Path $path) | Should -BeTrue
        }
    }

    Context 'Round-trip' {
        It 'persists and reloads every field including destructive marker fields' {
            $path = Join-Path $TestDrive ('state-rt-{0}.json' -f ([guid]::NewGuid()))

            InModuleScope ArcRemediator -Parameters @{ p = $path } {
                param($p)
                $s = New-DefaultRemediatorState
                $s.ConsecutiveFailures = 2
                $s.BreakerTripped = $true
                # ISO-8601 timestamps are written as strings; ConvertFrom-Json
                # rehydrates them as [DateTime], so we assert on prefix rather
                # than exact string equality (the round-tripped form gains
                # fractional-second precision).
                $s.BreakerLastResetUtc = '2026-05-10T12:00:00Z'
                $s.LastExpiredAttemptId = 'attempt-abc-123'
                $s.LastExpiredAttemptResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-arc/providers/Microsoft.HybridCompute/machines/host01'
                $s.LastExpiredAttemptStartedUtc = '2026-05-12T18:30:00Z'
                $s.LastExpiredAttemptOutcome = 'ExpiredRejoinSuccess'
                $s.ResetByUser = 'tag'

                Set-RemediatorState -State $s -Path $p

                $r = Get-RemediatorState -Path $p
                $r.ConsecutiveFailures | Should -Be 2
                $r.BreakerTripped | Should -BeTrue
                ([datetime]$r.BreakerLastResetUtc).ToString('o') | Should -Match '^2026-05-10'
                $r.LastExpiredAttemptId | Should -Be 'attempt-abc-123'
                $r.LastExpiredAttemptResourceId | Should -Match '/host01$'
                ([datetime]$r.LastExpiredAttemptStartedUtc).ToString('o') | Should -Match '^2026-05-12'
                $r.LastExpiredAttemptOutcome | Should -Be 'ExpiredRejoinSuccess'
                $r.ResetByUser | Should -Be 'tag'
            }
        }

        It 'replaces an existing state file on subsequent writes' {
            $path = Join-Path $TestDrive ('state-replace-{0}.json' -f ([guid]::NewGuid()))

            InModuleScope ArcRemediator -Parameters @{ p = $path } {
                param($p)
                $s = New-DefaultRemediatorState
                $s.ConsecutiveFailures = 1
                Set-RemediatorState -State $s -Path $p

                $s.ConsecutiveFailures = 5
                Set-RemediatorState -State $s -Path $p

                (Get-RemediatorState -Path $p).ConsecutiveFailures | Should -Be 5
            }
        }
    }
}
