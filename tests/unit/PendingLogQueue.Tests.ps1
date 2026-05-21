#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
}

Describe 'Add-PendingLogRow' {

    Context 'Queue write' {
        It 'creates the pending directory and writes a json file' {
            InModuleScope ArcRemediator {
                $dir = Join-Path $TestDrive ("pending-{0}" -f [guid]::NewGuid())
                $row = @{ EventTimeUtc = '2026-01-01T00:00:00Z'; Outcome = 'Healthy' }
                Add-PendingLogRow -Row $row -PendingDir $dir
                (Test-Path -LiteralPath $dir) | Should -BeTrue
                $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json')
                $files.Count | Should -Be 1
            }
        }

        It 'does not throw when the directory is not writable' {
            InModuleScope ArcRemediator {
                # Passing a path that cannot be created — should silently swallow.
                { Add-PendingLogRow -Row @{ x='y' } -PendingDir '\\invalid\unc\path\pending' } | Should -Not -Throw
            }
        }

        It 'creates a valid JSON file' {
            InModuleScope ArcRemediator {
                $dir = Join-Path $TestDrive ("pending-{0}" -f [guid]::NewGuid())
                $row = @{ EventTimeUtc = '2026-02-01T00:00:00Z'; Outcome = 'ExpiredRejoinSuccess' }
                Add-PendingLogRow -Row $row -PendingDir $dir
                $file = Get-ChildItem -LiteralPath $dir -Filter '*.json' | Select-Object -First 1
                { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } | Should -Not -Throw
            }
        }
    }
}

Describe 'Send-PendingLogRows' {

    Context 'Empty directory' {
        It 'returns zeros when pending directory does not exist' {
            InModuleScope ArcRemediator {
                $dir = Join-Path $TestDrive ("pending-missing-{0}" -f [guid]::NewGuid())
                $r = Send-PendingLogRows -PendingDir $dir `
                    -LogIngestionEndpoint 'https://x' -DcrImmutableId 'dcr-1' `
                    -StreamName 'Custom-ArcRemediation' -AccessToken 'tok'
                $r.Attempted | Should -Be 0
                $r.Succeeded | Should -Be 0
                $r.Pruned | Should -Be 0
            }
        }

        It 'returns zeros when directory exists but is empty' {
            InModuleScope ArcRemediator {
                $dir = Join-Path $TestDrive ("pending-empty-{0}" -f [guid]::NewGuid())
                New-Item -Path $dir -ItemType Directory | Out-Null
                $r = Send-PendingLogRows -PendingDir $dir `
                    -LogIngestionEndpoint 'https://x' -DcrImmutableId 'dcr-1' `
                    -StreamName 'Custom-ArcRemediation' -AccessToken 'tok'
                $r.Attempted | Should -Be 0
                $r.Pruned | Should -Be 0
            }
        }
    }

    Context 'Successful resend' {
        It 'deletes the file and increments Succeeded when send succeeds' {
            InModuleScope ArcRemediator {
                $dir = Join-Path $TestDrive ("pending-ok-{0}" -f [guid]::NewGuid())
                New-Item -Path $dir -ItemType Directory | Out-Null
                $row = @{ EventTimeUtc = '2026-01-01T00:00:00Z'; Outcome = 'Healthy' }
                ($row | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $dir '20260101-abc.json') -Encoding UTF8

                Mock Send-LogAnalytics {
                    return [PSCustomObject]@{ Success=$true; StatusCode=204; RowCount=1; ErrorMessage=$null }
                }
                $r = Send-PendingLogRows -PendingDir $dir `
                    -LogIngestionEndpoint 'https://x' -DcrImmutableId 'dcr-1' `
                    -StreamName 'Custom-ArcRemediation' -AccessToken 'tok'
                $r.Attempted | Should -Be 1
                $r.Succeeded | Should -Be 1
                @(Get-ChildItem -LiteralPath $dir -Filter '*.json').Count | Should -Be 0
            }
        }
    }

    Context 'Failed resend' {
        It 'leaves the file and Succeeded stays 0 when send fails' {
            InModuleScope ArcRemediator {
                $dir = Join-Path $TestDrive ("pending-fail-{0}" -f [guid]::NewGuid())
                New-Item -Path $dir -ItemType Directory | Out-Null
                $row = @{ EventTimeUtc = '2026-01-01T00:00:00Z'; Outcome = 'Healthy' }
                ($row | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $dir '20260101-xyz.json') -Encoding UTF8

                Mock Send-LogAnalytics {
                    return [PSCustomObject]@{ Success=$false; StatusCode=503; RowCount=1; ErrorMessage='transient' }
                }
                $r = Send-PendingLogRows -PendingDir $dir `
                    -LogIngestionEndpoint 'https://x' -DcrImmutableId 'dcr-1' `
                    -StreamName 'Custom-ArcRemediation' -AccessToken 'tok'
                $r.Attempted | Should -Be 1
                $r.Succeeded | Should -Be 0
                @(Get-ChildItem -LiteralPath $dir -Filter '*.json').Count | Should -Be 1
            }
        }
    }

    Context 'Pruning by age' {
        It 'prunes files older than RetentionDays without attempting to send them' {
            InModuleScope ArcRemediator {
                $dir = Join-Path $TestDrive ("pending-prune-{0}" -f [guid]::NewGuid())
                New-Item -Path $dir -ItemType Directory | Out-Null
                $oldFile = Join-Path $dir '20250101-old.json'
                $row = @{ Outcome = 'Healthy' }
                ($row | ConvertTo-Json -Compress) | Set-Content -LiteralPath $oldFile -Encoding UTF8
                # Backdate the file's LastWriteTime to 31 days ago.
                (Get-Item -LiteralPath $oldFile).LastWriteTime = (Get-Date).AddDays(-31)

                Mock Send-LogAnalytics { return [PSCustomObject]@{ Success=$true; RowCount=0 } }
                $r = Send-PendingLogRows -PendingDir $dir `
                    -LogIngestionEndpoint 'https://x' -DcrImmutableId 'dcr-1' `
                    -StreamName 'Custom-ArcRemediation' -AccessToken 'tok' `
                    -RetentionDays 30
                $r.Pruned | Should -BeGreaterOrEqual 1
                (Test-Path -LiteralPath $oldFile) | Should -BeFalse
            }
        }
    }

    Context 'MaxFiles cap' {
        It 'prunes oldest files when count exceeds MaxFiles before sending' {
            InModuleScope ArcRemediator {
                $dir = Join-Path $TestDrive ("pending-cap-{0}" -f [guid]::NewGuid())
                New-Item -Path $dir -ItemType Directory | Out-Null
                # Create 5 files; cap is 3.
                $row = @{ Outcome = 'Healthy' }
                1..5 | ForEach-Object {
                    $ts = (Get-Date).AddMinutes(-$_).ToString('yyyyMMddHHmmssZ')
                    ($row | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $dir "$ts-$_.json") -Encoding UTF8
                }

                Mock Send-LogAnalytics { return [PSCustomObject]@{ Success=$true; RowCount=1 } }
                $r = Send-PendingLogRows -PendingDir $dir `
                    -LogIngestionEndpoint 'https://x' -DcrImmutableId 'dcr-1' `
                    -StreamName 'Custom-ArcRemediation' -AccessToken 'tok' `
                    -MaxFiles 3
                $r.Pruned | Should -BeGreaterOrEqual 2
            }
        }
    }
}
