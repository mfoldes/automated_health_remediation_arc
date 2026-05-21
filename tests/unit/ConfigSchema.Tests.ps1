#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
}

Describe 'Test-ConfigSchema' {

    Context 'Valid config' {
        It 'returns IsValid=true for a well-formed minimum config' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId    = 'sub-guid'
                    KillSwitchUrl     = 'https://example.com/kill'
                    CloudProfile      = 'Commercial'
                    ArcCredential     = [PSCustomObject]@{
                        TenantId             = 'tenant-guid'
                        ClientId             = 'client-guid'
                        CredentialType       = 'Certificate'
                        CertificateThumbprint = 'AABBCC'
                    }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeTrue
                $r.Failures | Should -BeNullOrEmpty
            }
        }

        It 'accepts AzureGovernmentDoD as CloudProfile' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId = 's'
                    KillSwitchUrl  = 'https://x'
                    CloudProfile   = 'AzureGovernmentDoD'
                    ArcCredential  = [PSCustomObject]@{
                        TenantId      = 't'
                        ClientId      = 'c'
                        CredentialType = 'ClientSecret'
                        ClientSecret  = 'secret'
                    }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeTrue
            }
        }

        It 'passes with CircuitBreakerFailureThreshold=1 (boundary low)' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId                 = 's'
                    KillSwitchUrl                  = 'https://x'
                    CloudProfile                   = 'Commercial'
                    CircuitBreakerFailureThreshold = 1
                    ArcCredential                  = [PSCustomObject]@{
                        TenantId             = 't'
                        ClientId             = 'c'
                        CredentialType       = 'Certificate'
                        CertificateThumbprint = 'AA'
                    }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeTrue
            }
        }

        It 'passes with CircuitBreakerFailureThreshold=100 (boundary high)' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId                 = 's'
                    KillSwitchUrl                  = 'https://x'
                    CloudProfile                   = 'Commercial'
                    CircuitBreakerFailureThreshold = 100
                    ArcCredential                  = [PSCustomObject]@{
                        TenantId             = 't'
                        ClientId             = 'c'
                        CredentialType       = 'Certificate'
                        CertificateThumbprint = 'AA'
                    }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeTrue
            }
        }
    }

    Context 'Missing required top-level fields' {
        It 'fails when SubscriptionId is missing' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    KillSwitchUrl  = 'https://x'
                    CloudProfile   = 'Commercial'
                    ArcCredential  = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s' }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeFalse
                $r.Failures | Should -Contain "Required field 'SubscriptionId' is missing or empty."
            }
        }

        It 'fails when KillSwitchUrl is empty string' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId = 's'
                    KillSwitchUrl  = ''
                    CloudProfile   = 'Commercial'
                    ArcCredential  = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s' }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeFalse
                $r.Failures | Should -Contain "Required field 'KillSwitchUrl' is missing or empty."
            }
        }
    }

    Context 'CloudProfile enum' {
        It 'fails on an unknown CloudProfile value' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId = 's'
                    KillSwitchUrl  = 'https://x'
                    CloudProfile   = 'AzureChina'
                    ArcCredential  = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s' }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeFalse
                ($r.Failures | Where-Object { $_ -match 'CloudProfile' }) | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'CircuitBreakerFailureThreshold range' {
        It 'fails when threshold is 0 (below range)' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId                 = 's'
                    KillSwitchUrl                  = 'https://x'
                    CloudProfile                   = 'Commercial'
                    CircuitBreakerFailureThreshold = 0
                    ArcCredential                  = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s' }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeFalse
                ($r.Failures | Where-Object { $_ -match 'CircuitBreakerFailureThreshold' }) | Should -Not -BeNullOrEmpty
            }
        }

        It 'fails when threshold is 101 (above range)' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId                 = 's'
                    KillSwitchUrl                  = 'https://x'
                    CloudProfile                   = 'Commercial'
                    CircuitBreakerFailureThreshold = 101
                    ArcCredential                  = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s' }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeFalse
            }
        }
    }

    Context 'ArcCredential sub-object' {
        It 'fails when ArcCredential is missing' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId = 's'
                    KillSwitchUrl  = 'https://x'
                    CloudProfile   = 'Commercial'
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeFalse
                ($r.Failures | Where-Object { $_ -match 'ArcCredential' }) | Should -Not -BeNullOrEmpty
            }
        }

        It 'fails when ArcCredential.TenantId is missing' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId = 's'
                    KillSwitchUrl  = 'https://x'
                    CloudProfile   = 'Commercial'
                    ArcCredential  = [PSCustomObject]@{ ClientId='c'; CredentialType='ClientSecret'; ClientSecret='s' }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeFalse
                $r.Failures | Should -Contain "ArcCredential.TenantId is missing or empty."
            }
        }

        It 'fails when CredentialType=Certificate but thumbprint is absent' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId = 's'
                    KillSwitchUrl  = 'https://x'
                    CloudProfile   = 'Commercial'
                    ArcCredential  = [PSCustomObject]@{
                        TenantId       = 't'
                        ClientId       = 'c'
                        CredentialType = 'Certificate'
                    }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeFalse
                ($r.Failures | Where-Object { $_ -match 'CertificateThumbprint' }) | Should -Not -BeNullOrEmpty
            }
        }

        It 'fails when CredentialType=ClientSecret but ClientSecret is empty' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId = 's'
                    KillSwitchUrl  = 'https://x'
                    CloudProfile   = 'Commercial'
                    ArcCredential  = [PSCustomObject]@{
                        TenantId       = 't'
                        ClientId       = 'c'
                        CredentialType = 'ClientSecret'
                        ClientSecret   = ''
                    }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeFalse
                ($r.Failures | Where-Object { $_ -match 'ClientSecret' }) | Should -Not -BeNullOrEmpty
            }
        }

        It 'fails when CredentialType is an invalid value' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId = 's'
                    KillSwitchUrl  = 'https://x'
                    CloudProfile   = 'Commercial'
                    ArcCredential  = [PSCustomObject]@{
                        TenantId       = 't'
                        ClientId       = 'c'
                        CredentialType = 'ManagedIdentity'
                    }
                }
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeFalse
                ($r.Failures | Where-Object { $_ -match 'CredentialType' }) | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Unknown keys' {
        It 'returns IsValid=true (warning only) when an unknown top-level key is present' {
            InModuleScope ArcRemediator {
                $cfg = [PSCustomObject]@{
                    SubscriptionId = 's'
                    KillSwitchUrl  = 'https://x'
                    CloudProfile   = 'Commercial'
                    ArcCredential  = [PSCustomObject]@{
                        TenantId             = 't'
                        ClientId             = 'c'
                        CredentialType       = 'Certificate'
                        CertificateThumbprint = 'AA'
                    }
                    FutureNewField = 'some-value'
                }
                # Should not fail; unknown key is a warning only.
                $r = Test-ConfigSchema -Config $cfg
                $r.IsValid | Should -BeTrue
            }
        }
    }
}
