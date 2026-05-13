#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1'
    Import-Module $script:ManifestPath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-RestMethodWithTls' {

    BeforeEach {
        $script:originalProtocol = [Net.ServicePointManager]::SecurityProtocol
    }

    AfterEach {
        [Net.ServicePointManager]::SecurityProtocol = $script:originalProtocol
    }

    Context 'TLS enforcement' {
        It 'ensures Tls12 is set after the call when starting from SystemDefault' {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethod { @{ ok = $true } }

                # Modern Windows .NET refuses to set deprecated protocols
                # (NotSupportedException on Ssl3/Tls10/Tls11), so we start
                # from SystemDefault (value 0) which represents "no explicit
                # floor". After the call, Tls12 must be set in the bitmask.
                [Net.ServicePointManager]::SecurityProtocol =
                    [Net.SecurityProtocolType]::SystemDefault

                $null = Invoke-RestMethodWithTls -Uri 'https://example.invalid/'

                $tls12Bits = [int][Net.SecurityProtocolType]::Tls12
                $currentBits = [int][Net.ServicePointManager]::SecurityProtocol
                ($currentBits -band $tls12Bits) | Should -Be $tls12Bits
            }
        }

        It 'is idempotent: two consecutive calls do not throw and leave Tls12 set' {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethod { @{ ok = $true } }

                { Invoke-RestMethodWithTls -Uri 'https://example.invalid/' } | Should -Not -Throw
                { Invoke-RestMethodWithTls -Uri 'https://example.invalid/' } | Should -Not -Throw

                ([Net.ServicePointManager]::SecurityProtocol.HasFlag(
                    [Net.SecurityProtocolType]::Tls12)) | Should -BeTrue
            }
        }

        It 'never downgrades a protocol set that already includes Tls13' {
            $tls13 = [enum]::GetValues([Net.SecurityProtocolType]) |
                Where-Object { $_.ToString() -eq 'Tls13' } |
                Select-Object -First 1

            if ($null -eq $tls13) {
                Set-ItResult -Skipped -Because 'host enum has no Tls13'
                return
            }

            InModuleScope ArcRemediator {
                Mock Invoke-RestMethod { @{ ok = $true } }

                $tls13 = [enum]::GetValues([Net.SecurityProtocolType]) |
                    Where-Object { $_.ToString() -eq 'Tls13' } |
                    Select-Object -First 1
                [Net.ServicePointManager]::SecurityProtocol =
                    [Net.SecurityProtocolType]::Tls12 -bor $tls13

                $null = Invoke-RestMethodWithTls -Uri 'https://example.invalid/'

                ([Net.ServicePointManager]::SecurityProtocol.HasFlag($tls13)) | Should -BeTrue
            }
        }
    }

    Context 'Forwarding' {
        It 'forwards Uri/Method/Headers/Body/ContentType/TimeoutSec to Invoke-RestMethod' {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethod {
                    [PSCustomObject]@{
                        ReceivedUri = $Uri
                        ReceivedMethod = $Method
                        ReceivedHeaders = $Headers
                        ReceivedBody = $Body
                        ReceivedContentType = $ContentType
                        ReceivedTimeoutSec = $TimeoutSec
                    }
                }

                $result = Invoke-RestMethodWithTls `
                    -Uri 'https://example.invalid/foo' `
                    -Method 'POST' `
                    -Headers @{ 'X-Test' = '1' } `
                    -Body 'payload' `
                    -ContentType 'application/json' `
                    -TimeoutSec 15

                $result.ReceivedUri | Should -Be 'https://example.invalid/foo'
                $result.ReceivedMethod | Should -Be 'POST'
                $result.ReceivedHeaders['X-Test'] | Should -Be '1'
                $result.ReceivedBody | Should -Be 'payload'
                $result.ReceivedContentType | Should -Be 'application/json'
                $result.ReceivedTimeoutSec | Should -Be 15
            }
        }

        It 'omits optional parameters when not specified' {
            InModuleScope ArcRemediator {
                Mock Invoke-RestMethod {
                    [PSCustomObject]@{
                        BodyBound = $PSBoundParameters.ContainsKey('Body')
                        HeadersBound = $PSBoundParameters.ContainsKey('Headers')
                        ContentTypeBound = $PSBoundParameters.ContainsKey('ContentType')
                        TimeoutSecBound = $PSBoundParameters.ContainsKey('TimeoutSec')
                    }
                }

                $result = Invoke-RestMethodWithTls -Uri 'https://example.invalid/foo'

                $result.BodyBound | Should -BeFalse
                $result.HeadersBound | Should -BeFalse
                $result.ContentTypeBound | Should -BeFalse
                $result.TimeoutSecBound | Should -BeFalse
            }
        }
    }
}
