#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:PrivateDir = Join-Path $script:RepoRoot 'azure-setup/private'
    $script:TestsDir = Join-Path $script:RepoRoot 'azure-setup/tests'

    . (Join-Path $script:TestsDir 'AzStubs.ps1')
    . (Join-Path $script:PrivateDir 'New-ScopedServicePrincipal.ps1')
    . (Join-Path $script:PrivateDir 'Set-ArcRgRoleAssignment.ps1')
}

Describe 'New-ScopedServicePrincipal' {

    BeforeEach {
        Mock -CommandName Get-AzContext -MockWith {
            [PSCustomObject]@{
                Tenant = [PSCustomObject]@{ Id = '99999999-9999-9999-9999-999999999999' }
                Environment = [PSCustomObject]@{ Name = 'AzureCloud' }
            }
        }
    }

    Context 'Idempotency: reuse existing AAD app and SP' {
        It 'does not call New-AzADApplication when an app with the same DisplayName exists' {
            Mock -CommandName Get-AzADApplication -MockWith {
                [PSCustomObject]@{ AppId = 'aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa' }
            }
            Mock -CommandName Get-AzADServicePrincipal -MockWith {
                [PSCustomObject]@{ Id = 'sp-existing-object-id' }
            }
            Mock -CommandName New-AzADApplication {}
            Mock -CommandName New-AzADServicePrincipal {}
            # New-SelfSignedCertificate output normally has GetRawCertData();
            # we add it on the fake so the helper's call site does not blow up.
            Mock -CommandName New-SelfSignedCertificate -MockWith {
                $obj = [PSCustomObject]@{
                    Thumbprint = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
                    NotAfter = (Get-Date).AddDays(365)
                }
                $obj | Add-Member -MemberType ScriptMethod -Name GetRawCertData -Value { [byte[]](1..32) }
                $obj
            }
            Mock -CommandName New-AzADAppCredential {}

            $null = New-ScopedServicePrincipal -DisplayName 'sp-existing'

            Assert-MockCalled New-AzADApplication -Times 0 -Scope It
            Assert-MockCalled New-AzADServicePrincipal -Times 0 -Scope It
        }

        It 'creates a new app and SP when neither exists' {
            Mock -CommandName Get-AzADApplication -MockWith { $null }
            Mock -CommandName Get-AzADServicePrincipal -MockWith { $null }
            Mock -CommandName New-AzADApplication -MockWith {
                [PSCustomObject]@{ AppId = 'bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb' }
            }
            Mock -CommandName New-AzADServicePrincipal -MockWith {
                [PSCustomObject]@{ Id = 'sp-new-object-id' }
            }
            Mock -CommandName New-SelfSignedCertificate -MockWith {
                $obj = [PSCustomObject]@{
                    Thumbprint = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
                    NotAfter = (Get-Date).AddDays(365)
                }
                $obj | Add-Member -MemberType ScriptMethod -Name GetRawCertData -Value { [byte[]](1..32) }
                $obj
            }
            Mock -CommandName New-AzADAppCredential {}

            $result = New-ScopedServicePrincipal -DisplayName 'sp-fresh'

            Assert-MockCalled New-AzADApplication -Times 1 -Scope It
            Assert-MockCalled New-AzADServicePrincipal -Times 1 -Scope It
            $result.ApplicationId | Should -Be 'bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb'
            $result.ObjectId | Should -Be 'sp-new-object-id'
        }
    }

    Context 'Default credential path (certificate)' {
        BeforeEach {
            Mock -CommandName Get-AzADApplication -MockWith {
                [PSCustomObject]@{ AppId = 'cccccccc-3333-3333-3333-cccccccccccc' }
            }
            Mock -CommandName Get-AzADServicePrincipal -MockWith {
                [PSCustomObject]@{ Id = 'sp-cert-test-id' }
            }
            Mock -CommandName New-SelfSignedCertificate -MockWith {
                $obj = [PSCustomObject]@{
                    Thumbprint = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
                    NotAfter = (Get-Date).AddDays(365)
                }
                $obj | Add-Member -MemberType ScriptMethod -Name GetRawCertData -Value { [byte[]](1..32) }
                $obj
            }
            Mock -CommandName New-AzADAppCredential {}
        }

        It 'returns CredentialType = Certificate and a thumbprint' {
            $result = New-ScopedServicePrincipal -DisplayName 'sp-cert'
            $result.CredentialType | Should -Be 'Certificate'
            $result.CertificateThumbprint | Should -Be 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
            $result.ClientSecret | Should -BeNullOrEmpty
        }

        It 'uploads the cert public bytes (base64) to AAD as a credential' {
            $null = New-ScopedServicePrincipal -DisplayName 'sp-cert-upload'
            Assert-MockCalled New-AzADAppCredential -Scope It -ParameterFilter {
                $CertValue -and ($CertValue.Length -gt 0)
            }
        }

        It 'passes the TenantId from the current Az context' {
            $result = New-ScopedServicePrincipal -DisplayName 'sp-cert-tenant'
            $result.TenantId | Should -Be '99999999-9999-9999-9999-999999999999'
        }
    }

    Context 'Lab/canary path (-UseClientSecret)' {
        BeforeEach {
            Mock -CommandName Get-AzADApplication -MockWith {
                [PSCustomObject]@{ AppId = 'dddddddd-4444-4444-4444-dddddddddddd' }
            }
            Mock -CommandName Get-AzADServicePrincipal -MockWith {
                [PSCustomObject]@{ Id = 'sp-secret-test-id' }
            }
            Mock -CommandName New-AzADAppCredential -MockWith {
                [PSCustomObject]@{ SecretText = 'fake-secret-payload-12345' }
            }
            Mock -CommandName New-SelfSignedCertificate {
                throw 'New-SelfSignedCertificate should not be called on the -UseClientSecret path'
            }
        }

        It 'returns CredentialType = ClientSecret and the secret value' {
            $result = New-ScopedServicePrincipal -DisplayName 'sp-secret' -UseClientSecret
            $result.CredentialType | Should -Be 'ClientSecret'
            $result.ClientSecret | Should -Be 'fake-secret-payload-12345'
            $result.CertificateThumbprint | Should -BeNullOrEmpty
        }

        It 'does NOT generate a self-signed certificate' {
            $null = New-ScopedServicePrincipal -DisplayName 'sp-secret-nocert' -UseClientSecret
            Assert-MockCalled New-SelfSignedCertificate -Times 0 -Scope It
        }

        It 'defaults secret validity to 90 days' {
            $result = New-ScopedServicePrincipal -DisplayName 'sp-secret-default-ttl' -UseClientSecret
            $delta = ($result.CredentialExpiry - (Get-Date)).TotalDays
            $delta | Should -BeGreaterThan 89
            $delta | Should -BeLessThan 91
        }
    }
}

Describe 'Set-ArcRgRoleAssignment' {

    Context 'Idempotency' {
        It 'skips New-AzRoleAssignment when an assignment already exists' {
            Mock -CommandName Get-AzRoleAssignment -MockWith {
                [PSCustomObject]@{ RoleAssignmentId = 'existing' }
            }
            Mock -CommandName New-AzRoleAssignment {}

            Set-ArcRgRoleAssignment `
                -ServicePrincipalObjectId 'sp-1' `
                -SubscriptionId '00000000-0000-0000-0000-000000000000' `
                -ResourceGroupName 'rg-arc-prod-1'

            Assert-MockCalled New-AzRoleAssignment -Times 0 -Scope It
        }

        It 'creates 2 role assignments per RG when none exist (Resource Admin + Onboarding)' {
            Mock -CommandName Get-AzRoleAssignment -MockWith { $null }
            Mock -CommandName New-AzRoleAssignment {}

            Set-ArcRgRoleAssignment `
                -ServicePrincipalObjectId 'sp-2' `
                -SubscriptionId '00000000-0000-0000-0000-000000000000' `
                -ResourceGroupName @('rg-arc-prod-1', 'rg-arc-prod-2')

            # 2 roles x 2 RGs = 4
            Assert-MockCalled New-AzRoleAssignment -Times 4 -Scope It
        }
    }

    Context 'Default role definitions match Microsoft Learn (built-in role IDs)' {
        It 'uses Azure Connected Machine Resource Administrator (cd570a14-...)' {
            Mock -CommandName Get-AzRoleAssignment -MockWith { $null }
            Mock -CommandName New-AzRoleAssignment {}

            Set-ArcRgRoleAssignment `
                -ServicePrincipalObjectId 'sp-3' `
                -SubscriptionId '00000000-0000-0000-0000-000000000000' `
                -ResourceGroupName 'rg-arc-prod-1'

            Assert-MockCalled New-AzRoleAssignment -Scope It -ParameterFilter {
                $RoleDefinitionId -eq 'cd570a14-e51a-42ad-bac8-bafd67325302'
            }
        }

        It 'uses Azure Connected Machine Onboarding (b64e21ea-...)' {
            Mock -CommandName Get-AzRoleAssignment -MockWith { $null }
            Mock -CommandName New-AzRoleAssignment {}

            Set-ArcRgRoleAssignment `
                -ServicePrincipalObjectId 'sp-4' `
                -SubscriptionId '00000000-0000-0000-0000-000000000000' `
                -ResourceGroupName 'rg-arc-prod-1'

            Assert-MockCalled New-AzRoleAssignment -Scope It -ParameterFilter {
                $RoleDefinitionId -eq 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7'
            }
        }
    }

    Context 'Scope formatting' {
        It 'builds scope = /subscriptions/{sub}/resourceGroups/{rg}' {
            Mock -CommandName Get-AzRoleAssignment -MockWith { $null }
            Mock -CommandName New-AzRoleAssignment {}

            Set-ArcRgRoleAssignment `
                -ServicePrincipalObjectId 'sp-5' `
                -SubscriptionId 'deadbeef-1111-2222-3333-444444444444' `
                -ResourceGroupName 'rg-arc-canary'

            Assert-MockCalled New-AzRoleAssignment -Scope It -ParameterFilter {
                $Scope -eq '/subscriptions/deadbeef-1111-2222-3333-444444444444/resourceGroups/rg-arc-canary'
            }
        }
    }
}
