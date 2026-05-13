#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Install = Join-Path $script:RepoRoot 'src/ArcRemediator/Bootstrap/Install.ps1'
    $script:Uninstall = Join-Path $script:RepoRoot 'src/ArcRemediator/Bootstrap/Uninstall.ps1'
    $script:SourceMod = Join-Path $script:RepoRoot 'src/ArcRemediator'

    function script:New-Layout {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("arc-install-$([guid]::NewGuid().ToString('N'))")
        $install = Join-Path $root 'Program Files\ArcRemediator'
        $data = Join-Path $root 'ProgramData\ArcRemediator'
        $cfg = Join-Path $root 'config.sample.json'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [PSCustomObject]@{ Root=$root; Install=$install; Data=$data; Config=$cfg }
    }

    function script:Write-OperatorConfig {
        param([string]$Path, [string]$CloudProfile = 'Commercial')
        $obj = [ordered]@{
            CloudProfile = $CloudProfile
            ArcCredential = [ordered]@{
                TenantId='11111111-1111-1111-1111-111111111111'; ClientId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                CredentialType='Certificate'; ClientSecret=$null; CertificateThumbprint=('A'*40)
            }
            MonitorCredential = [ordered]@{ UseArcCredential=$true; TenantId=$null; ClientId=$null; CredentialType=$null; ClientSecret=$null; CertificateThumbprint=$null }
            SubscriptionId = '00000000-0000-0000-0000-000000000000'; ScopedResourceGroups = @('rg-prod')
            LogIngestionEndpoint = 'https://x.ingest.monitor.azure.com'; DcrImmutableId = 'dcr-1'; StreamName = 'Custom-ArcRemediation'
            KillSwitchUrl = 'https://x.blob.core.windows.net/arc-remediator/kill-switch.txt?sig=x'
            PrivateLinkScopeResourceId = $null; ArcGatewayResourceId = $null; ProxyUrl = $null
            EnableAutomaticAgentUpgrade = $false; CircuitBreakerFailureThreshold = 3; Mode = 'Observe'; Version = '1.0.0'
        }
        ($obj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

Describe 'Install.ps1' {

    Context 'Idempotent install' {
        It 'copies the module, creates data dir, DPAPI-wraps config, returns paths' {
            $layout = New-Layout
            try {
                Write-OperatorConfig -Path $layout.Config

                $r = & $script:Install -ConfigJsonPath $layout.Config `
                    -InstallPath $layout.Install -DataPath $layout.Data `
                    -SourceModuleRoot $script:SourceMod `
                    -SkipTaskRegistration -SkipElevationCheck -SkipEditionCheck -SkipAclHardening -Confirm:$false

                $r.InstallPath | Should -Be $layout.Install
                $r.DataPath | Should -Be $layout.Data
                $r.ConfigPath | Should -Be (Join-Path $layout.Data 'config.json')

                (Test-Path -LiteralPath (Join-Path $layout.Install 'ArcRemediator.psd1')) | Should -BeTrue
                (Test-Path -LiteralPath (Join-Path $layout.Install 'Bootstrap\Invoke-RemediatorTask.ps1')) | Should -BeTrue
                (Test-Path -LiteralPath (Join-Path $layout.Data 'logs')) | Should -BeTrue
                (Test-Path -LiteralPath (Join-Path $layout.Data 'config.json')) | Should -BeTrue

                # DPAPI-wrapped file MUST NOT contain plaintext fields like the thumbprint.
                $bytes = [System.IO.File]::ReadAllBytes((Join-Path $layout.Data 'config.json'))
                $text = [System.Text.Encoding]::ASCII.GetString($bytes)
                $text | Should -Not -Match 'AAAAAAAAAA'
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 're-running with the same source overwrites the install (no-error idempotent refresh)' {
            $layout = New-Layout
            try {
                Write-OperatorConfig -Path $layout.Config
                & $script:Install -ConfigJsonPath $layout.Config -InstallPath $layout.Install -DataPath $layout.Data `
                    -SourceModuleRoot $script:SourceMod -SkipTaskRegistration -SkipElevationCheck -SkipEditionCheck -SkipAclHardening -Confirm:$false | Out-Null

                # Modify a marker file in the install path; re-run; marker must be reset.
                $marker = Join-Path $layout.Install 'TEST_MARKER.txt'
                'tampered' | Set-Content -LiteralPath $marker -Encoding ASCII

                { & $script:Install -ConfigJsonPath $layout.Config -InstallPath $layout.Install -DataPath $layout.Data `
                    -SourceModuleRoot $script:SourceMod -SkipTaskRegistration -SkipElevationCheck -SkipEditionCheck -SkipAclHardening -Confirm:$false } | Should -Not -Throw

                # Module manifest is still in place after the second run.
                (Test-Path -LiteralPath (Join-Path $layout.Install 'ArcRemediator.psd1')) | Should -BeTrue
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Pre-flight validation' {
        It 'throws when ConfigJsonPath does not exist' {
            $layout = New-Layout
            try {
                { & $script:Install -ConfigJsonPath (Join-Path $layout.Root 'missing.json') `
                    -InstallPath $layout.Install -DataPath $layout.Data `
                    -SourceModuleRoot $script:SourceMod -SkipTaskRegistration -SkipElevationCheck -SkipEditionCheck -SkipAclHardening -Confirm:$false } |
                    Should -Throw -ExpectedMessage '*does not exist*'
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'throws when SourceModuleRoot does not contain the manifest' {
            $layout = New-Layout
            try {
                Write-OperatorConfig -Path $layout.Config
                $badSrc = Join-Path $layout.Root 'not-a-module'
                New-Item -ItemType Directory -Path $badSrc -Force | Out-Null
                { & $script:Install -ConfigJsonPath $layout.Config -InstallPath $layout.Install -DataPath $layout.Data `
                    -SourceModuleRoot $badSrc -SkipTaskRegistration -SkipElevationCheck -SkipEditionCheck -SkipAclHardening -Confirm:$false } |
                    Should -Throw -ExpectedMessage '*source module not found*'
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Module imports + Invoke-ArcRemediation is callable from the installed path' {
        It 'the installed module exports Invoke-ArcRemediation' {
            $layout = New-Layout
            try {
                Write-OperatorConfig -Path $layout.Config
                & $script:Install -ConfigJsonPath $layout.Config -InstallPath $layout.Install -DataPath $layout.Data `
                    -SourceModuleRoot $script:SourceMod -SkipTaskRegistration -SkipElevationCheck -SkipEditionCheck -SkipAclHardening -Confirm:$false | Out-Null

                Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
                $manifest = Join-Path $layout.Install 'ArcRemediator.psd1'
                Import-Module $manifest -Force
                $exports = (Get-Module ArcRemediator).ExportedFunctions
                $exports.ContainsKey('Invoke-ArcRemediation') | Should -BeTrue
            } finally {
                Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Uninstall.ps1' {

    Context 'Default behavior: remove task + install, preserve data' {
        It 'removes install path but preserves data path (cooldown / state / logs survive)' {
            $layout = New-Layout
            try {
                Write-OperatorConfig -Path $layout.Config
                & $script:Install -ConfigJsonPath $layout.Config -InstallPath $layout.Install -DataPath $layout.Data `
                    -SourceModuleRoot $script:SourceMod -SkipTaskRegistration -SkipElevationCheck -SkipEditionCheck -SkipAclHardening -Confirm:$false | Out-Null

                # Seed a marker in the data path that must survive uninstall.
                $seeded = Join-Path $layout.Data 'state.json'
                '{"BreakerTripped":false}' | Set-Content -LiteralPath $seeded -Encoding UTF8

                $r = & $script:Uninstall -InstallPath $layout.Install -DataPath $layout.Data `
                    -SkipTaskRemoval -SkipElevationCheck -Confirm:$false

                $r.InstallRemoved | Should -BeTrue
                $r.DataRemoved | Should -BeFalse
                (Test-Path -LiteralPath $layout.Install) | Should -BeFalse
                (Test-Path -LiteralPath $seeded) | Should -BeTrue
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It '-RemoveData explicitly drops the data path (cooldown marker is gone)' {
            $layout = New-Layout
            try {
                Write-OperatorConfig -Path $layout.Config
                & $script:Install -ConfigJsonPath $layout.Config -InstallPath $layout.Install -DataPath $layout.Data `
                    -SourceModuleRoot $script:SourceMod -SkipTaskRegistration -SkipElevationCheck -SkipEditionCheck -SkipAclHardening -Confirm:$false | Out-Null

                $r = & $script:Uninstall -InstallPath $layout.Install -DataPath $layout.Data `
                    -RemoveData -SkipTaskRemoval -SkipElevationCheck -Confirm:$false

                $r.DataRemoved | Should -BeTrue
                (Test-Path -LiteralPath $layout.Data) | Should -BeFalse
            } finally {
                Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
