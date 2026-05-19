#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ManifestPath -Force -ErrorAction Stop

    $script:SecretMarker = 'sentinel-secret-9c3a2f-do-not-leak'
    $script:SampleConfig = [PSCustomObject]@{
        CloudProfile = 'Commercial'
        ArcCredential = [PSCustomObject]@{
            TenantId = '00000000-0000-0000-0000-000000000000'
            ClientId = '11111111-1111-1111-1111-111111111111'
            CredentialType = 'ClientSecret'
            ClientSecret = $script:SecretMarker
            CertificateThumbprint = $null
        }
        SubscriptionId = '22222222-2222-2222-2222-222222222222'
        Mode = 'Observe'
        Version = '1.0.0'
    }
}

AfterAll {
    Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
}

Describe 'Set-EncryptedConfig + Get-DecryptedConfig (DPAPI LocalMachine)' -Tag 'WindowsOnly' {

    BeforeAll {
        # $IsWindows is only available on PS 6+; use $env:OS on 5.1 Desktop.
        if ($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {
            throw 'DPAPI tests require Windows.'
        }
    }

    Context 'Round-trip' {
        It 'wraps and unwraps a config with sensitive fields preserved' {
            $path = Join-Path $TestDrive ('config-rt-{0}.json' -f ([guid]::NewGuid()))

            InModuleScope ArcRemediator -Parameters @{ p = $path; cfg = $script:SampleConfig; marker = $script:SecretMarker } {
                param($p, $cfg, $marker)
                Set-EncryptedConfig -Config $cfg -Path $p
                $back = Get-DecryptedConfig -Path $p
                $back.CloudProfile | Should -Be 'Commercial'
                $back.SubscriptionId | Should -Be '22222222-2222-2222-2222-222222222222'
                $back.ArcCredential.ClientId | Should -Be '11111111-1111-1111-1111-111111111111'
                $back.ArcCredential.ClientSecret | Should -Be $marker
            }
        }

        It 'never writes the secret as plaintext on disk' {
            $path = Join-Path $TestDrive ('config-cipher-{0}.json' -f ([guid]::NewGuid()))

            InModuleScope ArcRemediator -Parameters @{ p = $path; cfg = $script:SampleConfig } {
                param($p, $cfg)
                Set-EncryptedConfig -Config $cfg -Path $p
            }

            $bytes = [System.IO.File]::ReadAllBytes($path)
            $asString = [System.Text.Encoding]::UTF8.GetString($bytes)
            $asString | Should -Not -Match $script:SecretMarker
            $asString | Should -Not -Match '"ClientSecret"'
        }
    }

    Context 'Failure handling' {
        It 'throws when the config file does not exist' {
            $path = Join-Path $TestDrive ('config-missing-{0}.json' -f ([guid]::NewGuid()))
            InModuleScope ArcRemediator -Parameters @{ p = $path } {
                param($p)
                { Get-DecryptedConfig -Path $p } | Should -Throw -ExpectedMessage '*not found*'
            }
        }

        It 'throws on a tampered ciphertext file' {
            $path = Join-Path $TestDrive ('config-tampered-{0}.json' -f ([guid]::NewGuid()))

            InModuleScope ArcRemediator -Parameters @{ p = $path; cfg = $script:SampleConfig } {
                param($p, $cfg)
                Set-EncryptedConfig -Config $cfg -Path $p
            }

            # Flip a single byte in the middle of the ciphertext.
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $mid = [int]($bytes.Length / 2)
            $bytes[$mid] = $bytes[$mid] -bxor 0xFF
            [System.IO.File]::WriteAllBytes($path, $bytes)

            InModuleScope ArcRemediator -Parameters @{ p = $path } {
                param($p)
                { Get-DecryptedConfig -Path $p } | Should -Throw -ExpectedMessage '*decrypt*'
            }
        }

        It 'creates the parent directory if absent' {
            $dir = Join-Path $TestDrive ('config-newdir-{0}' -f ([guid]::NewGuid()))
            $path = Join-Path $dir 'config.json'

            InModuleScope ArcRemediator -Parameters @{ p = $path; cfg = $script:SampleConfig } {
                param($p, $cfg)
                Set-EncryptedConfig -Config $cfg -Path $p
            }

            (Test-Path $path) | Should -BeTrue
        }
    }
}
