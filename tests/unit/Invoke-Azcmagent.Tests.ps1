#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force

    # cmd.exe is exercised as a stand-in for azcmagent.exe so the wrapper
    # itself is tested end-to-end (Start-Process -> WaitForExit -> capture).
    $script:Cmd = "$env:WINDIR\System32\cmd.exe"
    $script:Powershell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
}

Describe 'Invoke-Azcmagent' -Skip:(-not (Test-Path -LiteralPath "$env:WINDIR\System32\cmd.exe")) {

    Context 'Exit code propagation' {
        It 'returns ExitCode=0 on a clean run' {
            InModuleScope ArcRemediator -Parameters @{ cmd = $script:Cmd } {
                param($cmd)
                $r = Invoke-Azcmagent -AzcmagentPath $cmd -Arguments @('/c','exit','0') -TimeoutSec 10
                $r.ExitCode | Should -Be 0
                $r.TimedOut | Should -BeFalse
            }
        }

        It 'returns the actual nonzero exit code' {
            InModuleScope ArcRemediator -Parameters @{ cmd = $script:Cmd } {
                param($cmd)
                $r = Invoke-Azcmagent -AzcmagentPath $cmd -Arguments @('/c','exit','7') -TimeoutSec 10
                $r.ExitCode | Should -Be 7
                $r.TimedOut | Should -BeFalse
            }
        }
    }

    Context 'Stream capture' {
        It 'captures stdout' {
            InModuleScope ArcRemediator -Parameters @{ cmd = $script:Cmd } {
                param($cmd)
                $r = Invoke-Azcmagent -AzcmagentPath $cmd -Arguments @('/c','echo','hello') -TimeoutSec 10
                $r.Stdout.Trim() | Should -Be 'hello'
                $r.Stderr | Should -BeNullOrEmpty
            }
        }

        It 'captures stderr separately from stdout' {
            InModuleScope ArcRemediator -Parameters @{ cmd = $script:Cmd } {
                param($cmd)
                $r = Invoke-Azcmagent -AzcmagentPath $cmd `
                    -Arguments @('/c','echo oops 1>&2 & echo good') -TimeoutSec 10
                $r.ExitCode | Should -Be 0
                $r.Stdout.Trim() | Should -Be 'good'
                $r.Stderr.Trim() | Should -Be 'oops'
            }
        }
    }

    Context 'Timeout' {
        It 'kills the child and reports TimedOut=$true' {
            InModuleScope ArcRemediator -Parameters @{ ps = $script:Powershell } {
                param($ps)
                $r = Invoke-Azcmagent -AzcmagentPath $ps `
                    -Arguments @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30') `
                    -TimeoutSec 2
                $r.TimedOut | Should -BeTrue
                $r.Duration.TotalSeconds | Should -BeLessThan 10
            }
        }
    }

    Context 'Discovery + error hygiene' {
        It "throws a clean message (no argv) when azcmagent.exe is not found" {
            InModuleScope ArcRemediator {
                try {
                    Invoke-Azcmagent -AzcmagentPath 'C:\does\not\exist\azcmagent.exe' `
                        -Arguments @('connect','--service-principal-secret','S3CRET-VALUE') `
                        -TimeoutSec 5
                    throw 'expected throw'
                } catch {
                    $_.Exception.Message | Should -Match 'azcmagent\.exe not found'
                    $_.Exception.Message | Should -Not -Match 'S3CRET-VALUE'
                    $_.Exception.Message | Should -Not -Match 'service-principal-secret'
                }
            }
        }
    }
}
