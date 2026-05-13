#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Get-AzureToken' {

    Context 'Audience routing' {
        BeforeEach {
            $script:CaptureUri = $null
            $script:CaptureBody = $null
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethodWithTls {
                    $env:T_AT_URI = $Uri
                    $env:T_AT_BODY = $Body
                    return [PSCustomObject]@{
                        access_token = 'fake-jwt'
                        expires_in = 3600
                        token_type = 'Bearer'
                    }
                }
            }
        }

        It 'Arc purpose hits v1 /oauth2/token with resource= in body (Commercial)' {
            InModuleScope ArcRemediator {
                $profile = Get-CloudProfile -Name 'Commercial'
                $cred = [PSCustomObject]@{
                    TenantId = '11111111-1111-1111-1111-111111111111'
                    ClientId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    CredentialType = 'ClientSecret'
                    ClientSecret = 'super-secret'
                    CertificateThumbprint = $null
                }
                $tok = Get-AzureToken -CloudProfile $profile -Credential $cred -Purpose 'Arc'
                $tok.Purpose | Should -Be 'Arc'
                $tok.AccessToken | Should -Be 'fake-jwt'
                $tok.TokenType | Should -Be 'Bearer'
                $tok.ExpiresOnUtc | Should -BeOfType ([datetime])
            }
            $env:T_AT_URI | Should -Match 'login\.microsoftonline\.com/.+/oauth2/token$'
            $env:T_AT_BODY | Should -Match 'grant_type=client_credentials'
            $env:T_AT_BODY | Should -Match 'resource=https%3A%2F%2Fmanagement\.azure\.com%2F'
            $env:T_AT_BODY | Should -Not -Match 'scope='
        }

        It 'Monitor purpose hits v2 /oauth2/v2.0/token with scope= in body (Commercial)' {
            InModuleScope ArcRemediator {
                $profile = Get-CloudProfile -Name 'Commercial'
                $cred = [PSCustomObject]@{
                    TenantId = '11111111-1111-1111-1111-111111111111'
                    ClientId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    CredentialType = 'ClientSecret'
                    ClientSecret = 'super-secret'
                    CertificateThumbprint = $null
                }
                $null = Get-AzureToken -CloudProfile $profile -Credential $cred -Purpose 'Monitor'
            }
            $env:T_AT_URI | Should -Match '/oauth2/v2\.0/token$'
            $env:T_AT_BODY | Should -Match 'scope=https%3A%2F%2Fmonitor\.azure\.com%2F\.default'
            $env:T_AT_BODY | Should -Not -Match 'resource='
        }

        It 'Arc purpose for DoD hits usgovcloudapi resource' {
            InModuleScope ArcRemediator {
                $profile = Get-CloudProfile -Name 'AzureGovernmentDoD'
                $cred = [PSCustomObject]@{
                    TenantId = '22222222-2222-2222-2222-222222222222'
                    ClientId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                    CredentialType = 'ClientSecret'
                    ClientSecret = 'gov-secret'
                    CertificateThumbprint = $null
                }
                $null = Get-AzureToken -CloudProfile $profile -Credential $cred -Purpose 'Arc'
            }
            $env:T_AT_URI | Should -Match 'login\.microsoftonline\.us/.+/oauth2/token$'
            $env:T_AT_BODY | Should -Match 'resource=https%3A%2F%2Fmanagement\.usgovcloudapi\.net%2F'
        }

        It 'Monitor purpose for DoD hits monitor.azure.us /.default' {
            InModuleScope ArcRemediator {
                $profile = Get-CloudProfile -Name 'AzureGovernmentDoD'
                $cred = [PSCustomObject]@{
                    TenantId = '22222222-2222-2222-2222-222222222222'
                    ClientId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                    CredentialType = 'ClientSecret'
                    ClientSecret = 'gov-secret'
                    CertificateThumbprint = $null
                }
                $null = Get-AzureToken -CloudProfile $profile -Credential $cred -Purpose 'Monitor'
            }
            $env:T_AT_URI | Should -Match 'login\.microsoftonline\.us/.+/oauth2/v2\.0/token$'
            $env:T_AT_BODY | Should -Match 'scope=https%3A%2F%2Fmonitor\.azure\.us%2F\.default'
        }
    }

    Context 'Credential validation' {
        BeforeEach {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethodWithTls { return [PSCustomObject]@{ access_token = 'x'; expires_in = 3600 } }
            }
        }

        It 'throws when CredentialType=ClientSecret but ClientSecret is empty' {
            InModuleScope ArcRemediator {
                $profile = Get-CloudProfile -Name 'Commercial'
                $cred = [PSCustomObject]@{
                    TenantId = 't'; ClientId = 'c'; CredentialType = 'ClientSecret'
                    ClientSecret = $null; CertificateThumbprint = $null
                }
                { Get-AzureToken -CloudProfile $profile -Credential $cred -Purpose 'Arc' } |
                    Should -Throw -ExpectedMessage '*ClientSecret is empty*'
            }
        }

        It 'throws when CredentialType=Certificate but thumbprint is empty' {
            InModuleScope ArcRemediator {
                $profile = Get-CloudProfile -Name 'Commercial'
                $cred = [PSCustomObject]@{
                    TenantId = 't'; ClientId = 'c'; CredentialType = 'Certificate'
                    ClientSecret = $null; CertificateThumbprint = $null
                }
                { Get-AzureToken -CloudProfile $profile -Credential $cred -Purpose 'Arc' } |
                    Should -Throw -ExpectedMessage '*CertificateThumbprint is empty*'
            }
        }

        It 'throws for unsupported CredentialType' {
            InModuleScope ArcRemediator {
                $profile = Get-CloudProfile -Name 'Commercial'
                $cred = [PSCustomObject]@{
                    TenantId = 't'; ClientId = 'c'; CredentialType = 'ManagedIdentity'
                    ClientSecret = $null; CertificateThumbprint = $null
                }
                { Get-AzureToken -CloudProfile $profile -Credential $cred -Purpose 'Arc' } |
                    Should -Throw -ExpectedMessage "*Unsupported CredentialType 'ManagedIdentity'*"
            }
        }

        It 'throws when response is missing access_token' {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethodWithTls { return [PSCustomObject]@{ expires_in = 3600 } }
                $profile = Get-CloudProfile -Name 'Commercial'
                $cred = [PSCustomObject]@{
                    TenantId = 't'; ClientId = 'c'; CredentialType = 'ClientSecret'
                    ClientSecret = 's'; CertificateThumbprint = $null
                }
                { Get-AzureToken -CloudProfile $profile -Credential $cred -Purpose 'Arc' } |
                    Should -Throw -ExpectedMessage '*missing access_token*'
            }
        }
    }

    Context 'Credential leakage redaction' {
        It 'scrubs client_secret from re-thrown exception when token endpoint fails' {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethodWithTls {
                    throw 'AADSTS7000215: Invalid client_secret=super-secret-value-leaked is provided.'
                }
                $profile = Get-CloudProfile -Name 'Commercial'
                $cred = [PSCustomObject]@{
                    TenantId = 't'; ClientId = 'c'; CredentialType = 'ClientSecret'
                    ClientSecret = 'super-secret-value-leaked'; CertificateThumbprint = $null
                }
                try {
                    Get-AzureToken -CloudProfile $profile -Credential $cred -Purpose 'Arc'
                    throw 'expected throw'
                } catch {
                    $_.Exception.Message | Should -Not -Match 'super-secret-value-leaked'
                    $_.Exception.Message | Should -Match 'client_secret=<redacted>'
                }
            }
        }

        It 'scrubs client_assertion from re-thrown exception' {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethodWithTls {
                    throw 'AADSTS error: client_assertion=eyJhbGciOiJSUzI1NiJ9.payload-that-must-not-leak.sig was rejected.'
                }
                $profile = Get-CloudProfile -Name 'Commercial'
                $cred = [PSCustomObject]@{
                    TenantId = 't'; ClientId = 'c'; CredentialType = 'ClientSecret'
                    ClientSecret = 's'; CertificateThumbprint = $null
                }
                try {
                    Get-AzureToken -CloudProfile $profile -Credential $cred -Purpose 'Arc'
                    throw 'expected throw'
                } catch {
                    $_.Exception.Message | Should -Not -Match 'payload-that-must-not-leak'
                    $_.Exception.Message | Should -Match 'client_assertion=<redacted>'
                }
            }
        }
    }
}
