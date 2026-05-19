Set-StrictMode -Version 3.0

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ChangelogPath  = Join-Path $script:RepoRoot 'CHANGELOG.md'
    $script:ManifestPath   = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
}

Describe 'CHANGELOG.md' {

    It 'exists at the repo root' {
        Test-Path -LiteralPath $script:ChangelogPath | Should -BeTrue
    }

    Context 'structure' {

        BeforeAll {
            $script:Content = Get-Content -LiteralPath $script:ChangelogPath -Raw
        }

        It 'declares it follows Keep a Changelog' {
            $script:Content | Should -Match 'Keep a Changelog'
        }

        It 'has an [Unreleased] heading' {
            $script:Content | Should -Match '## \[Unreleased\]'
        }

        It 'has at least one versioned release heading' {
            @($script:Content -split "`n" | Where-Object {
                $_ -match '^## \[\d+\.\d+\.\d+'
            }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'version alignment with module manifest' {

        BeforeAll {
            $script:Manifest  = Import-PowerShellDataFile -Path $script:ManifestPath
            $script:Content   = Get-Content -LiteralPath $script:ChangelogPath -Raw

            # Capture the first versioned heading line, like:
            #   ## [1.0.0-preview] - 2026-05-19
            $script:FirstVersionMatch = [regex]::Match(
                $script:Content,
                '##\s+\[(?<v>\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)\]'
            )
        }

        It 'finds at least one versioned heading' {
            $script:FirstVersionMatch.Success | Should -BeTrue
        }

        It 'the top versioned heading matches the module ModuleVersion (with optional Prerelease tag)' {
            $expected = $script:Manifest.ModuleVersion
            $prerelease = $null
            if ($script:Manifest.ContainsKey('PrivateData') -and
                $script:Manifest.PrivateData.ContainsKey('PSData') -and
                $script:Manifest.PrivateData.PSData.ContainsKey('Prerelease')) {
                $prerelease = $script:Manifest.PrivateData.PSData.Prerelease
            }
            if ($prerelease) {
                $expected = "$expected-$prerelease"
            }
            $script:FirstVersionMatch.Groups['v'].Value | Should -Be $expected
        }
    }
}
