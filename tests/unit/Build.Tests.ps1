#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Build = Join-Path $script:RepoRoot 'package/build.ps1'
}

Describe 'package/build.ps1' {

    Context 'Produces a versioned ZIP with the documented layout' {
        It 'creates a versioned ZIP containing module + samples + README' {
            $outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("arc-build-$([guid]::NewGuid().ToString('N'))")
            try {
                $r = & $script:Build -OutputDirectory $outDir -Confirm:$false

                $r.ZipPath | Should -Not -BeNullOrEmpty
                $r.Version | Should -Not -BeNullOrEmpty
                (Test-Path -LiteralPath $r.ZipPath) | Should -BeTrue
                $r.SizeBytes | Should -BeGreaterThan 1024

                # Peek inside the ZIP without unzipping the whole thing.
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zip = [System.IO.Compression.ZipFile]::OpenRead($r.ZipPath)
                try {
                    # Normalize path separators: .NET Framework (PS 5.1) may emit
                # backslashes in ZipEntry.FullName; .NET Core (PS 7) always uses '/'.
                $entries = $zip.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }
                    $entries | Should -Contain 'ArcRemediator/ArcRemediator.psd1'
                    $entries | Should -Contain 'ArcRemediator/ArcRemediator.psm1'
                    $entries | Should -Contain 'ArcRemediator/Bootstrap/Install.ps1'
                    $entries | Should -Contain 'ArcRemediator/Bootstrap/Uninstall.ps1'
                    $entries | Should -Contain 'ArcRemediator/Bootstrap/Invoke-RemediatorTask.ps1'
                    $entries | Should -Contain 'ArcRemediator/Public/Test-ArcInstallation.ps1'
                    $entries | Should -Contain 'ArcRemediator/Data/cloud-profiles.psd1'
                    $entries | Should -Contain 'ArcRemediator/Data/version.txt'
                    $entries | Should -Contain 'samples/config.commercial.sample.json'
                    $entries | Should -Contain 'samples/config.usgovdod.sample.json'
                    $entries | Should -Contain 'README.md'
                    $entries | Should -Contain 'azure-setup/Setup-AzureSide.ps1'
                    # Tests/docs MUST NOT be in the package.
                    @($entries | Where-Object { $_ -like 'tests/*' }).Count | Should -Be 0
                    @($entries | Where-Object { $_ -like 'docs/*' }).Count | Should -Be 0
                } finally {
                    $zip.Dispose()
                }
            } finally {
                Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'emits sample configs with the DoD/IL5 forced overrides (ArcGatewayResourceId=null, EnableAutomaticAgentUpgrade=false)' {
            $outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("arc-build-$([guid]::NewGuid().ToString('N'))")
            try {
                $r = & $script:Build -OutputDirectory $outDir -Confirm:$false

                # Extract just the DoD sample.
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zip = [System.IO.Compression.ZipFile]::OpenRead($r.ZipPath)
                try {
                    $entry = $zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq 'samples/config.usgovdod.sample.json' } | Select-Object -First 1
                    $reader = New-Object System.IO.StreamReader($entry.Open())
                    $json = $reader.ReadToEnd()
                    $reader.Dispose()
                    $cfg = $json | ConvertFrom-Json
                    $cfg.CloudProfile | Should -Be 'AzureGovernmentDoD'
                    $cfg.ArcGatewayResourceId | Should -BeNullOrEmpty
                    $cfg.EnableAutomaticAgentUpgrade | Should -BeFalse
                    $cfg.LogIngestionEndpoint | Should -Match 'monitor\.azure\.us'
                    $cfg.KillSwitchUrl | Should -Match 'core\.usgovcloudapi\.net'
                } finally {
                    $zip.Dispose()
                }
            } finally {
                Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
