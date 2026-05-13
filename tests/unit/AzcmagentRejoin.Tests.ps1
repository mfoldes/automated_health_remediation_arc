#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Invoke-AzcmagentDisconnect' {
    It 'always passes --force-local-only' {
        InModuleScope ArcRemediator {
            $env:T_DC_ARGS = ''
            Mock Invoke-Azcmagent -MockWith {
                $env:T_DC_ARGS = ($Arguments -join ' ')
                [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
            }
            $null = Invoke-AzcmagentDisconnect
        }
        $env:T_DC_ARGS | Should -Match '^disconnect --force-local-only$'
    }
}

Describe 'Invoke-AzcmagentConnect' {

    Context 'Certificate credential keeps the secret off the command line' {
        It 'uses --service-principal-cert-thumbprint and does NOT pass --service-principal-secret' {
            InModuleScope ArcRemediator {
                $env:T_CN_ARGS = ''
                Mock Invoke-Azcmagent -MockWith {
                    $env:T_CN_ARGS = ($Arguments -join ' ')
                    [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $cred = [PSCustomObject]@{
                    TenantId = 't'; ClientId = 'c'; CredentialType = 'Certificate'
                    CertificateThumbprint = ('A' * 40); ClientSecret = $null
                }
                $r = Invoke-AzcmagentConnect -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -Credential $cred -SubscriptionId 's' -ResourceGroupName 'rg' `
                    -MachineName 'm' -Location 'eastus' -Confirm:$false
                $r.UsedConfigFile | Should -BeFalse
            }
            $env:T_CN_ARGS | Should -Match '--service-principal-cert-thumbprint AAAAAAAAAA'
            $env:T_CN_ARGS | Should -Not -Match 'service-principal-secret'
            $env:T_CN_ARGS | Should -Not -Match '--config'
        }
    }

    Context 'ClientSecret credential keeps the secret off the command line via --config' {
        It 'writes a temp config file, passes --config, secret NOT in argv, and cleans up file' {
            InModuleScope ArcRemediator {
                $env:T_CN_ARGS = ''
                $env:T_CN_CONFIG_PATH = ''
                $env:T_CN_CONFIG_BODY = ''
                $env:T_CN_FILE_EXISTED = ''
                Mock Invoke-Azcmagent -MockWith {
                    param($Arguments, $TimeoutSec, $AzcmagentPath)
                    $env:T_CN_ARGS = ($Arguments -join ' ')
                    # Find --config and capture the path it points to, while the
                    # file still exists (Invoke-AzcmagentConnect deletes it in
                    # finally after this mock returns).
                    for ($i = 0; $i -lt @($Arguments).Count - 1; $i++) {
                        if ($Arguments[$i] -eq '--config') {
                            $cfg = [string]$Arguments[$i + 1]
                            $env:T_CN_CONFIG_PATH = $cfg
                            if ($cfg -and (Test-Path -LiteralPath $cfg)) {
                                $env:T_CN_FILE_EXISTED = 'yes'
                                $env:T_CN_CONFIG_BODY = (Get-Content -LiteralPath $cfg -Raw)
                            }
                            break
                        }
                    }
                    [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $cred = [PSCustomObject]@{
                    TenantId = 't'; ClientId = 'c'; CredentialType = 'ClientSecret'
                    ClientSecret = 'AbsolutelyMustNotLeak123!'; CertificateThumbprint = $null
                }
                $r = Invoke-AzcmagentConnect -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -Credential $cred -SubscriptionId 's' -ResourceGroupName 'rg' `
                    -MachineName 'm' -Location 'eastus' -Confirm:$false
                $r.UsedConfigFile | Should -BeTrue
            }
            # Argv contract: --config IS there, secret is NOT.
            $env:T_CN_ARGS | Should -Match '--config '
            $env:T_CN_ARGS | Should -Not -Match 'AbsolutelyMustNotLeak123'
            # The function MUST clean up the file in its finally block.
            (Test-Path -LiteralPath $env:T_CN_CONFIG_PATH) | Should -BeFalse
            # When the file was reachable to the mock, its body must contain
            # the secret (that is where the secret legitimately goes - in a
            # restricted-ACL file, never on the command line). When the mock
            # cannot read the file (ACL prevents the running test user),
            # T_CN_FILE_EXISTED stays empty and we skip this assertion.
            if ($env:T_CN_FILE_EXISTED -eq 'yes') {
                $env:T_CN_CONFIG_BODY | Should -Match 'AbsolutelyMustNotLeak123'
            }
        }
    }

    Context 'DoD profile forbids --gateway-id even when caller passes one' {
        It 'silently drops -ArcGatewayResourceId for AzureGovernmentDoD' {
            InModuleScope ArcRemediator {
                $env:T_CN_ARGS = ''
                Mock Invoke-Azcmagent -MockWith {
                    $env:T_CN_ARGS = ($Arguments -join ' ')
                    [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $cred = [PSCustomObject]@{
                    TenantId='t'; ClientId='c'; CredentialType='Certificate'
                    CertificateThumbprint=('A'*40); ClientSecret=$null
                }
                $r = Invoke-AzcmagentConnect -CloudProfile (Get-CloudProfile -Name 'AzureGovernmentDoD') `
                    -Credential $cred -SubscriptionId 's' -ResourceGroupName 'rg' `
                    -MachineName 'm' -Location 'usgovvirginia' `
                    -ArcGatewayResourceId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.HybridCompute/gateways/gw1' `
                    -Confirm:$false
                $r.GatewayHonored | Should -BeFalse
            }
            $env:T_CN_ARGS | Should -Not -Match '--gateway-id'
        }

        It 'silently drops -EnableAutomaticUpgrade for AzureGovernmentDoD' {
            InModuleScope ArcRemediator {
                $env:T_CN_ARGS = ''
                Mock Invoke-Azcmagent -MockWith {
                    $env:T_CN_ARGS = ($Arguments -join ' ')
                    [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $cred = [PSCustomObject]@{
                    TenantId='t'; ClientId='c'; CredentialType='Certificate'
                    CertificateThumbprint=('A'*40); ClientSecret=$null
                }
                $r = Invoke-AzcmagentConnect -CloudProfile (Get-CloudProfile -Name 'AzureGovernmentDoD') `
                    -Credential $cred -SubscriptionId 's' -ResourceGroupName 'rg' `
                    -MachineName 'm' -Location 'usgovvirginia' -EnableAutomaticUpgrade -Confirm:$false
                $r.AutomaticUpgradeHonored | Should -BeFalse
            }
            $env:T_CN_ARGS | Should -Not -Match '--enable-automatic-upgrade'
        }
    }

    Context 'Commercial profile forwards gateway + automatic-upgrade when supported and requested' {
        It 'forwards --gateway-id and --enable-automatic-upgrade for Commercial' {
            InModuleScope ArcRemediator {
                $env:T_CN_ARGS = ''
                Mock Invoke-Azcmagent -MockWith {
                    $env:T_CN_ARGS = ($Arguments -join ' ')
                    [PSCustomObject]@{ ExitCode=0; Stdout=''; Stderr=''; TimedOut=$false; Duration=[timespan]::FromSeconds(1) }
                }
                $cred = [PSCustomObject]@{
                    TenantId='t'; ClientId='c'; CredentialType='Certificate'
                    CertificateThumbprint=('A'*40); ClientSecret=$null
                }
                $r = Invoke-AzcmagentConnect -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                    -Credential $cred -SubscriptionId 's' -ResourceGroupName 'rg' `
                    -MachineName 'm' -Location 'eastus' `
                    -ArcGatewayResourceId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.HybridCompute/gateways/gw1' `
                    -EnableAutomaticUpgrade -Confirm:$false
                $r.GatewayHonored | Should -BeTrue
                $r.AutomaticUpgradeHonored | Should -BeTrue
            }
            $env:T_CN_ARGS | Should -Match '--gateway-id '
            $env:T_CN_ARGS | Should -Match '--enable-automatic-upgrade'
        }
    }

    Context 'Credential validation' {
        It 'throws when CertificateThumbprint is empty for a Certificate credential' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent {}
                $cred = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='Certificate'; CertificateThumbprint=$null; ClientSecret=$null }
                {
                    Invoke-AzcmagentConnect -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                        -Credential $cred -SubscriptionId 's' -ResourceGroupName 'rg' `
                        -MachineName 'm' -Location 'eastus' -Confirm:$false
                } | Should -Throw -ExpectedMessage '*CertificateThumbprint is empty*'
            }
        }

        It 'throws for an unsupported CredentialType' {
            InModuleScope ArcRemediator {
                Mock Invoke-Azcmagent {}
                $cred = [PSCustomObject]@{ TenantId='t'; ClientId='c'; CredentialType='ManagedIdentity'; CertificateThumbprint=$null; ClientSecret=$null }
                {
                    Invoke-AzcmagentConnect -CloudProfile (Get-CloudProfile -Name 'Commercial') `
                        -Credential $cred -SubscriptionId 's' -ResourceGroupName 'rg' `
                        -MachineName 'm' -Location 'eastus' -Confirm:$false
                } | Should -Throw -ExpectedMessage "*Unsupported CredentialType 'ManagedIdentity'*"
            }
        }
    }
}
