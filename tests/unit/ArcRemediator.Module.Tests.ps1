#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    $script:VersionFile = Join-Path $script:RepoRoot 'src/ArcRemediator/Data/version.txt'
}

Describe 'ArcRemediator module scaffolding' {

    AfterEach {
        Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
    }


    Context 'Manifest' {
        It 'exists at src/ArcRemediator/ArcRemediator.psd1' {
            Test-Path $script:ManifestPath | Should -BeTrue
        }

        It 'parses as a valid PowerShell data file' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath -ErrorAction Stop
            $manifest | Should -Not -BeNullOrEmpty
        }

        It 'declares ModuleVersion 1.0.0' {
            (Import-PowerShellDataFile -Path $script:ManifestPath).ModuleVersion | Should -Be '1.0.0'
        }

        It 'declares RootModule ArcRemediator.psm1' {
            (Import-PowerShellDataFile -Path $script:ManifestPath).RootModule | Should -Be 'ArcRemediator.psm1'
        }

        It 'declares PowerShellVersion 5.1 (no PS7-only floor)' {
            (Import-PowerShellDataFile -Path $script:ManifestPath).PowerShellVersion | Should -Be '5.1'
        }

        It 'targets Desktop edition' {
            (Import-PowerShellDataFile -Path $script:ManifestPath).CompatiblePSEditions | Should -Contain 'Desktop'
        }
    }

    Context 'Import behavior' {
        It 'imports without throwing' {
            { Import-Module $script:ManifestPath -Force -ErrorAction Stop } | Should -Not -Throw
        }

        It 'exports the four public entry points' {
            Import-Module $script:ManifestPath -Force -ErrorAction Stop
            $exports = (Get-Module ArcRemediator).ExportedFunctions
            $exports.Count | Should -Be 4
            $exports.ContainsKey('Invoke-ArcRemediation') | Should -BeTrue
            $exports.ContainsKey('Test-ArcRemediator') | Should -BeTrue
            $exports.ContainsKey('Reset-ArcRemediator') | Should -BeTrue
            $exports.ContainsKey('Test-ArcInstallation') | Should -BeTrue
        }

        It 'does not mutate global [Net.ServicePointManager]::SecurityProtocol on load' {
            $before = [Net.ServicePointManager]::SecurityProtocol
            try {
                Import-Module $script:ManifestPath -Force -ErrorAction Stop
                $after = [Net.ServicePointManager]::SecurityProtocol
                $after | Should -Be $before
            } finally {
                [Net.ServicePointManager]::SecurityProtocol = $before
            }
        }
    }

    Context 'Version file' {
        It 'matches the manifest ModuleVersion' {
            $manifestVersion = (Import-PowerShellDataFile -Path $script:ManifestPath).ModuleVersion
            $fileVersion = (Get-Content -Path $script:VersionFile -Raw).Trim()
            $fileVersion | Should -Be $manifestVersion
        }
    }
}
