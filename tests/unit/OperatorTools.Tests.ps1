#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force

    function script:New-StatePath {
        Join-Path ([System.IO.Path]::GetTempPath()) ("arc-reset-state-$([guid]::NewGuid().ToString('N')).json")
    }
}

Describe 'Test-ArcRemediator' {
    It 'forwards to Invoke-ArcRemediation with -OverrideMode Observe' {
        InModuleScope ArcRemediator {
            $env:T_OT_MODE = ''
            Mock Invoke-ArcRemediation -MockWith {
                param($ConfigPath, $StatePath, $LogDirectory, $OverrideMode, $AzcmagentPath)
                $env:T_OT_MODE = [string]$OverrideMode
                [PSCustomObject]@{ Outcome='Healthy'; OutcomeDetail=''; ExitCode=0; Row=$null; LogIngestionFailed=$false; ErrorMessage=$null; ElapsedMs=1 }
            }
            $r = Test-ArcRemediator -ConfigPath 'x' -StatePath 'y' -LogDirectory 'z'
            $r.Outcome | Should -Be 'Healthy'
        }
        $env:T_OT_MODE | Should -Be 'Observe'
    }

    It 'returns whatever the orchestrator returned without re-shaping' {
        InModuleScope ArcRemediator {
            Mock Invoke-ArcRemediation -MockWith {
                [PSCustomObject]@{ Outcome='ConfigMismatch'; OutcomeDetail='cloud mismatch'; ExitCode=2; Row=$null; LogIngestionFailed=$false; ErrorMessage=$null; ElapsedMs=1 }
            }
            $r = Test-ArcRemediator -ConfigPath 'x' -StatePath 'y' -LogDirectory 'z'
            $r.Outcome | Should -Be 'ConfigMismatch'
            $r.ExitCode | Should -Be 2
            $r.OutcomeDetail | Should -Be 'cloud mismatch'
        }
    }
}

Describe 'Reset-ArcRemediator' {

    Context 'Default reset: breaker + counter, marker preserved' {
        It 'clears BreakerTripped and ConsecutiveFailures but leaves the Expired cooldown intact' {
            $sp = script:New-StatePath
            try {
                $seeded = [PSCustomObject]@{
                    LastSuccessfulRunUtc=$null; ConsecutiveFailures=5; BreakerTripped=$true; BreakerLastResetUtc=$null
                    LastExpiredAttemptId='attempt-1'; LastExpiredAttemptResourceId='r'
                    LastExpiredAttemptStartedUtc='2026-05-10T00:00:00Z'; LastExpiredAttemptCompletedUtc=$null
                    LastExpiredAttemptOutcome='DeleteFailed'; ResetByUser=$null
                }
                ($seeded | ConvertTo-Json) | Set-Content -LiteralPath $sp -Encoding UTF8

                $r = Reset-ArcRemediator -StatePath $sp -Confirm:$false

                $r.Reset | Should -BeTrue
                $r.ExpiredCleared | Should -BeFalse
                $r.ResetByUser | Should -Match '^local:'
                $r.BeforeState.BreakerTripped | Should -BeTrue
                $r.BeforeState.ConsecutiveFailures | Should -Be 5
                $r.AfterState.BreakerTripped | Should -BeFalse
                $r.AfterState.ConsecutiveFailures | Should -Be 0
                $r.AfterState.BreakerLastResetUtc | Should -Not -BeNullOrEmpty
                # Cooldown marker MUST survive a default reset.
                $r.AfterState.LastExpiredAttemptId | Should -Be 'attempt-1'
                $r.AfterState.LastExpiredAttemptOutcome | Should -Be 'DeleteFailed'

                # And the on-disk state matches.
                $persisted = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json
                $persisted.BreakerTripped | Should -BeFalse
                $persisted.ConsecutiveFailures | Should -Be 0
                $persisted.LastExpiredAttemptId | Should -Be 'attempt-1'
                $persisted.ResetByUser | Should -Match '^local:'
            } finally {
                Remove-Item -LiteralPath $sp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context '-AlsoClearExpiredAttempt clears the cooldown marker' {
        It 'wipes the LastExpiredAttempt* fields and reports ExpiredCleared=$true' {
            $sp = script:New-StatePath
            try {
                $seeded = [PSCustomObject]@{
                    LastSuccessfulRunUtc=$null; ConsecutiveFailures=0; BreakerTripped=$false; BreakerLastResetUtc=$null
                    LastExpiredAttemptId='attempt-2'; LastExpiredAttemptResourceId='r'
                    LastExpiredAttemptStartedUtc='2026-05-10T00:00:00Z'; LastExpiredAttemptCompletedUtc=$null
                    LastExpiredAttemptOutcome='DeleteFailed'; ResetByUser=$null
                }
                ($seeded | ConvertTo-Json) | Set-Content -LiteralPath $sp -Encoding UTF8

                $r = Reset-ArcRemediator -StatePath $sp -AlsoClearExpiredAttempt -Confirm:$false

                $r.Reset | Should -BeTrue
                $r.ExpiredCleared | Should -BeTrue
                $r.AfterState.LastExpiredAttemptId | Should -BeNullOrEmpty
                $r.AfterState.LastExpiredAttemptStartedUtc | Should -BeNullOrEmpty
                $r.AfterState.LastExpiredAttemptOutcome | Should -BeNullOrEmpty
            } finally {
                Remove-Item -LiteralPath $sp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'WhatIf does not mutate state' {
        It 'returns Reset=$false and leaves the state file untouched' {
            $sp = script:New-StatePath
            try {
                $seeded = [PSCustomObject]@{
                    LastSuccessfulRunUtc=$null; ConsecutiveFailures=5; BreakerTripped=$true; BreakerLastResetUtc=$null
                    LastExpiredAttemptId=$null; LastExpiredAttemptResourceId=$null
                    LastExpiredAttemptStartedUtc=$null; LastExpiredAttemptCompletedUtc=$null
                    LastExpiredAttemptOutcome=$null; ResetByUser=$null
                }
                ($seeded | ConvertTo-Json) | Set-Content -LiteralPath $sp -Encoding UTF8

                $r = Reset-ArcRemediator -StatePath $sp -WhatIf

                $r.Reset | Should -BeFalse

                $persisted = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json
                $persisted.BreakerTripped | Should -BeTrue -Because 'WhatIf must not mutate'
                $persisted.ConsecutiveFailures | Should -Be 5 -Because 'WhatIf must not mutate'
            } finally {
                Remove-Item -LiteralPath $sp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Audit (ResetByUser captured as a local-prefixed identity)' {
        It 'sets ResetByUser to a string starting with local:' {
            $sp = script:New-StatePath
            try {
                ([PSCustomObject]@{
                    LastSuccessfulRunUtc=$null; ConsecutiveFailures=0; BreakerTripped=$true; BreakerLastResetUtc=$null
                    LastExpiredAttemptId=$null; LastExpiredAttemptResourceId=$null
                    LastExpiredAttemptStartedUtc=$null; LastExpiredAttemptCompletedUtc=$null
                    LastExpiredAttemptOutcome=$null; ResetByUser=$null
                } | ConvertTo-Json) | Set-Content -LiteralPath $sp -Encoding UTF8

                $r = Reset-ArcRemediator -StatePath $sp -Confirm:$false
                $r.ResetByUser | Should -Match '^local:'
                $r.AfterState.ResetByUser | Should -Match '^local:'
            } finally {
                Remove-Item -LiteralPath $sp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
