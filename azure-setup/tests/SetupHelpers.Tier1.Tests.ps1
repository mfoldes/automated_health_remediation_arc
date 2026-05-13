#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:PrivateDir = Join-Path $script:RepoRoot 'azure-setup/private'

    . (Join-Path $script:PrivateDir 'Resolve-AzAccessToken.ps1')
    . (Join-Path $script:PrivateDir 'Assert-AzEnvironment.ps1')
    . (Join-Path $script:PrivateDir 'Register-RequiredProvider.ps1')

    # Stub Az cmdlets so Pester 5 Mock has a real command to redirect.
    # Az.Resources may not be imported in the test environment.
    if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue)) {
        function Get-AzContext { }
    }
    if (-not (Get-Command Get-AzResourceProvider -ErrorAction SilentlyContinue)) {
        function Get-AzResourceProvider { param([string]$ProviderNamespace) }
    }
    if (-not (Get-Command Register-AzResourceProvider -ErrorAction SilentlyContinue)) {
        function Register-AzResourceProvider { param([string]$ProviderNamespace) }
    }
}

Describe 'Resolve-AzAccessToken' {

    It 'returns the bearer string when Token is a plain String (pre-Az 14)' {
        $tokenObj = [PSCustomObject]@{ Token = 'plain-string-token' }
        Resolve-AzAccessToken -TokenObject $tokenObj | Should -Be 'plain-string-token'
    }

    It 'returns the bearer string when Token is a SecureString (Az 14+)' {
        $secure = ConvertTo-SecureString 'secure-string-token' -AsPlainText -Force
        $tokenObj = [PSCustomObject]@{ Token = $secure }
        Resolve-AzAccessToken -TokenObject $tokenObj | Should -Be 'secure-string-token'
    }

    It 'both Az shapes produce identical output for the same payload' {
        $payload = 'cross-shape-token-99'
        $oldShape = [PSCustomObject]@{ Token = $payload }
        $newShape = [PSCustomObject]@{ Token = (ConvertTo-SecureString $payload -AsPlainText -Force) }

        $a = Resolve-AzAccessToken -TokenObject $oldShape
        $b = Resolve-AzAccessToken -TokenObject $newShape

        $a | Should -Be $b
        $a | Should -Be $payload
    }
}

Describe 'Assert-AzEnvironment' {

    Context 'Commercial' {
        It 'returns the context when Environment.Name is AzureCloud' {
            Mock -CommandName Get-AzContext -MockWith {
                [PSCustomObject]@{
                    Subscription = [PSCustomObject]@{ Id = 'sub' }
                    Environment = [PSCustomObject]@{ Name = 'AzureCloud' }
                }
            }
            $ctx = Assert-AzEnvironment -CloudProfile 'Commercial'
            $ctx.Environment.Name | Should -Be 'AzureCloud'
        }

        It 'throws when context is AzureUSGovernment' {
            Mock -CommandName Get-AzContext -MockWith {
                [PSCustomObject]@{
                    Subscription = [PSCustomObject]@{ Id = 'sub' }
                    Environment = [PSCustomObject]@{ Name = 'AzureUSGovernment' }
                }
            }
            { Assert-AzEnvironment -CloudProfile 'Commercial' } |
                Should -Throw -ExpectedMessage '*AzureUSGovernment*does not match*Commercial*'
        }
    }

    Context 'AzureGovernmentDoD' {
        It 'returns the context when Environment.Name is AzureUSGovernment' {
            Mock -CommandName Get-AzContext -MockWith {
                [PSCustomObject]@{
                    Subscription = [PSCustomObject]@{ Id = 'sub' }
                    Environment = [PSCustomObject]@{ Name = 'AzureUSGovernment' }
                }
            }
            $ctx = Assert-AzEnvironment -CloudProfile 'AzureGovernmentDoD'
            $ctx.Environment.Name | Should -Be 'AzureUSGovernment'
        }

        It 'throws when context is AzureCloud' {
            Mock -CommandName Get-AzContext -MockWith {
                [PSCustomObject]@{
                    Subscription = [PSCustomObject]@{ Id = 'sub' }
                    Environment = [PSCustomObject]@{ Name = 'AzureCloud' }
                }
            }
            { Assert-AzEnvironment -CloudProfile 'AzureGovernmentDoD' } |
                Should -Throw -ExpectedMessage '*AzureCloud*does not match*AzureGovernmentDoD*'
        }
    }

    Context 'No context' {
        It 'throws when Get-AzContext returns nothing' {
            Mock -CommandName Get-AzContext -MockWith { $null }
            { Assert-AzEnvironment -CloudProfile 'Commercial' } |
                Should -Throw -ExpectedMessage '*No Az context*Connect-AzAccount*'
        }
    }

    Context 'Unknown profile' {
        It 'rejects profile names outside the MVP ValidateSet' {
            { Assert-AzEnvironment -CloudProfile 'AzureChinaCloud' } | Should -Throw
            { Assert-AzEnvironment -CloudProfile 'AirGapped' } | Should -Throw
        }
    }
}

Describe 'Register-RequiredProvider' {

    Context 'Default provider set (Arc baseline)' {
        It 'skips providers already in Registered state' {
            Mock -CommandName Get-AzResourceProvider -MockWith {
                param($ProviderNamespace)
                [PSCustomObject]@{
                    ProviderNamespace = $ProviderNamespace
                    RegistrationState = 'Registered'
                }
            }
            Mock -CommandName Register-AzResourceProvider {}

            Register-RequiredProvider

            Assert-MockCalled Register-AzResourceProvider -Times 0 -Scope It
        }

        It 'registers providers that are NotRegistered' {
            Mock -CommandName Get-AzResourceProvider -MockWith {
                param($ProviderNamespace)
                [PSCustomObject]@{
                    ProviderNamespace = $ProviderNamespace
                    RegistrationState = 'NotRegistered'
                }
            }
            Mock -CommandName Register-AzResourceProvider {}

            Register-RequiredProvider

            Assert-MockCalled Register-AzResourceProvider -Times 6 -Scope It
        }
    }

    Context 'SQL Arc opt-in' {
        It 'adds Microsoft.AzureArcData only when -IncludeSqlArc is set' {
            $askedFor = @()
            Mock -CommandName Get-AzResourceProvider -MockWith {
                param($ProviderNamespace)
                $script:askedFor += $ProviderNamespace
                [PSCustomObject]@{
                    ProviderNamespace = $ProviderNamespace
                    RegistrationState = 'Registered'
                }
            }
            Mock -CommandName Register-AzResourceProvider {}

            $script:askedFor = @()
            Register-RequiredProvider
            $script:askedFor | Should -Not -Contain 'Microsoft.AzureArcData'

            $script:askedFor = @()
            Register-RequiredProvider -IncludeSqlArc
            $script:askedFor | Should -Contain 'Microsoft.AzureArcData'
        }
    }

    Context 'Registration failure (fails closed)' {
        It 'throws and lists providers that could not be registered' {
            Mock -CommandName Get-AzResourceProvider -MockWith {
                param($ProviderNamespace)
                [PSCustomObject]@{
                    ProviderNamespace = $ProviderNamespace
                    RegistrationState = 'NotRegistered'
                }
            }
            Mock -CommandName Register-AzResourceProvider -MockWith {
                throw "Forbidden: caller missing Microsoft.Authorization/permissions"
            }

            { Register-RequiredProvider } |
                Should -Throw -ExpectedMessage '*Failed to register*Microsoft.HybridCompute*'
        }
    }
}
