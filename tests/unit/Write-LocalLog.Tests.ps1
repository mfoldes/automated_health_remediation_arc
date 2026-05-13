#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ManifestPath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
}

Describe 'Write-LocalLog' {

    Context 'Directory handling' {
        It 'creates the log directory when it does not exist' {
            $dir = Join-Path $TestDrive ('logs-new-{0}' -f ([guid]::NewGuid()))
            (Test-Path $dir) | Should -BeFalse

            InModuleScope ArcRemediator -Parameters @{ d = $dir } {
                param($d)
                Write-LocalLog -Message 'hello' -Directory $d
            }

            (Test-Path $dir) | Should -BeTrue
            @(Get-ChildItem $dir -Filter 'arc-remediator-*.log').Count | Should -Be 1
        }

        It 'uses %ProgramData%\ArcRemediator\logs when -Directory is omitted' {
            $oldProgramData = $env:ProgramData
            $env:ProgramData = "$TestDrive"
            try {
                InModuleScope ArcRemediator {
                    Write-LocalLog -Message 'default-dir test'
                }
                $expected = Join-Path "$TestDrive" 'ArcRemediator\logs'
                (Test-Path $expected) | Should -BeTrue
                @(Get-ChildItem $expected -Filter 'arc-remediator-*.log').Count | Should -Be 1
            } finally {
                $env:ProgramData = $oldProgramData
            }
        }
    }

    Context 'Line format' {
        It 'writes an ISO-8601 UTC timestamp, level, and message' {
            $dir = Join-Path $TestDrive ('logs-fmt-{0}' -f ([guid]::NewGuid()))
            InModuleScope ArcRemediator -Parameters @{ d = $dir } {
                param($d)
                Write-LocalLog -Message 'payload-marker' -Level 'Warn' -Directory $d
            }
            $file = Get-ChildItem $dir -Filter 'arc-remediator-*.log' | Select-Object -First 1
            $line = Get-Content -LiteralPath $file.FullName -Tail 1
            $line | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
            $line | Should -Match '\[Warn\]'
            $line | Should -Match 'payload-marker'
        }

        It 'defaults Level to Info when not provided' {
            $dir = Join-Path $TestDrive ('logs-info-{0}' -f ([guid]::NewGuid()))
            InModuleScope ArcRemediator -Parameters @{ d = $dir } {
                param($d)
                Write-LocalLog -Message 'no-level' -Directory $d
            }
            $file = Get-ChildItem $dir -Filter 'arc-remediator-*.log' | Select-Object -First 1
            $line = Get-Content -LiteralPath $file.FullName -Tail 1
            $line | Should -Match '\[Info\]'
        }
    }

    Context 'Rotation' {
        It 'rotates the current day file when it exceeds MaxFileBytes' {
            $dir = Join-Path $TestDrive ('logs-rot-{0}' -f ([guid]::NewGuid()))
            New-Item -Path $dir -ItemType Directory -Force | Out-Null

            $today = (Get-Date).ToString('yyyyMMdd')
            $todayFile = Join-Path $dir ('arc-remediator-{0}.log' -f $today)
            Set-Content -LiteralPath $todayFile -Value ('x' * 1024) -NoNewline

            InModuleScope ArcRemediator -Parameters @{ d = $dir } {
                param($d)
                Write-LocalLog -Message 'after-rotate' -Directory $d -MaxFileBytes 100
            }

            $rotated = @(Get-ChildItem $dir -Filter "arc-remediator-${today}-*.log")
            $rotated.Count | Should -BeGreaterOrEqual 1
            $rotated[0].Length | Should -BeGreaterOrEqual 1024

            $current = Get-Content -LiteralPath $todayFile -Tail 1
            $current | Should -Match 'after-rotate'
        }
    }

    Context 'Retention' {
        It 'deletes arc-remediator-*.log files older than RetentionDays' {
            $dir = Join-Path $TestDrive ('logs-ret-{0}' -f ([guid]::NewGuid()))
            New-Item -Path $dir -ItemType Directory -Force | Out-Null

            $stale = Join-Path $dir 'arc-remediator-20200101.log'
            Set-Content -LiteralPath $stale -Value 'old' -NoNewline
            (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-30)

            InModuleScope ArcRemediator -Parameters @{ d = $dir } {
                param($d)
                Write-LocalLog -Message 'fresh entry' -Directory $d -RetentionDays 14
            }

            (Test-Path $stale) | Should -BeFalse
        }

        It 'does not delete files inside RetentionDays window' {
            $dir = Join-Path $TestDrive ('logs-ret2-{0}' -f ([guid]::NewGuid()))
            New-Item -Path $dir -ItemType Directory -Force | Out-Null

            $recent = Join-Path $dir 'arc-remediator-20260510.log'
            Set-Content -LiteralPath $recent -Value 'recent' -NoNewline
            (Get-Item -LiteralPath $recent).LastWriteTime = (Get-Date).AddDays(-2)

            InModuleScope ArcRemediator -Parameters @{ d = $dir } {
                param($d)
                Write-LocalLog -Message 'fresh entry' -Directory $d -RetentionDays 14
            }

            (Test-Path $recent) | Should -BeTrue
        }
    }
}
