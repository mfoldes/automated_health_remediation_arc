#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/ArcRemediator/ArcRemediator.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module ArcRemediator -Force -ErrorAction SilentlyContinue
}

Describe 'Get-StateHmacKey' {

    Context 'Key file absent without -Create' {
        It 'returns null when file does not exist and -Create is not set' {
            InModuleScope ArcRemediator {
                $missing = Join-Path $TestDrive ("state-{0}.key" -f [guid]::NewGuid())
                $result = Get-StateHmacKey -KeyPath $missing
                $result | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Key creation with -Create' {
        It 'creates the key file and returns a 32-byte key' {
            InModuleScope ArcRemediator {
                $keyPath = Join-Path $TestDrive ("state-{0}.key" -f [guid]::NewGuid())
                $key = Get-StateHmacKey -KeyPath $keyPath -Create
                (Test-Path -LiteralPath $keyPath) | Should -BeTrue
                $key | Should -Not -BeNullOrEmpty
                $key.Length | Should -Be 32
            }
        }

        It 'returns the same key on subsequent reads' {
            InModuleScope ArcRemediator {
                $keyPath = Join-Path $TestDrive ("state-{0}.key" -f [guid]::NewGuid())
                $key1 = Get-StateHmacKey -KeyPath $keyPath -Create
                $key2 = Get-StateHmacKey -KeyPath $keyPath
                ([System.Convert]::ToBase64String($key1)) | Should -Be ([System.Convert]::ToBase64String($key2))
            }
        }

        It 'does not overwrite an existing key file when -Create is specified again' {
            InModuleScope ArcRemediator {
                $keyPath = Join-Path $TestDrive ("state-{0}.key" -f [guid]::NewGuid())
                $key1 = Get-StateHmacKey -KeyPath $keyPath -Create
                $key2 = Get-StateHmacKey -KeyPath $keyPath -Create
                ([System.Convert]::ToBase64String($key1)) | Should -Be ([System.Convert]::ToBase64String($key2))
            }
        }
    }
}

Describe 'Get-StateHmac' {
    It 'produces consistent HMAC for the same input' {
        InModuleScope ArcRemediator {
            $key = [byte[]](1..32)
            $h1 = Get-StateHmac -Json '{"BreakerTripped":false}' -Key $key
            $h2 = Get-StateHmac -Json '{"BreakerTripped":false}' -Key $key
            $h1 | Should -Be $h2
        }
    }

    It 'produces different HMAC for different JSON input' {
        InModuleScope ArcRemediator {
            $key = [byte[]](1..32)
            $h1 = Get-StateHmac -Json '{"BreakerTripped":false}' -Key $key
            $h2 = Get-StateHmac -Json '{"BreakerTripped":true}' -Key $key
            $h1 | Should -Not -Be $h2
        }
    }

    It 'produces different HMAC for the same input with different keys' {
        InModuleScope ArcRemediator {
            $key1 = [byte[]](1..32)
            $key2 = [byte[]](32..1)
            $h1 = Get-StateHmac -Json '{"BreakerTripped":false}' -Key $key1
            $h2 = Get-StateHmac -Json '{"BreakerTripped":false}' -Key $key2
            $h1 | Should -Not -Be $h2
        }
    }
}

Describe 'Get-RemediatorState HMAC verification' {

    Context 'Backward compatibility: no key, no HMAC in file' {
        It 'reads pre-upgrade state file (no HMAC, no key) without tampering' {
            InModuleScope ArcRemediator {
                $path = Join-Path $TestDrive ("state-legacy-{0}.json" -f [guid]::NewGuid())
                '{"SchemaVersion":1,"BreakerTripped":false,"ConsecutiveFailures":0}' |
                    Set-Content -LiteralPath $path -Encoding UTF8
                # Stub key to return null (no key file)
                Mock Get-StateHmacKey { return $null }
                $s = Get-RemediatorState -Path $path
                $s.BreakerTripped | Should -BeFalse
            }
        }
    }

    Context 'Key present, no HMAC in file (pre-upgrade state + new key)' {
        It 'passes through without treating as tamper' {
            InModuleScope ArcRemediator {
                $path = Join-Path $TestDrive ("state-preupgrade-{0}.json" -f [guid]::NewGuid())
                '{"SchemaVersion":1,"BreakerTripped":false,"ConsecutiveFailures":0}' |
                    Set-Content -LiteralPath $path -Encoding UTF8
                Mock Get-StateHmacKey { return [byte[]](1..32) }
                $s = Get-RemediatorState -Path $path
                $s.BreakerTripped | Should -BeFalse
            }
        }
    }

    Context 'Key absent, HMAC present in file' {
        It 'returns fail-closed defaults (BreakerTripped=true) and fires event 1006' {
            InModuleScope ArcRemediator {
                $path = Join-Path $TestDrive ("state-tamper-{0}.json" -f [guid]::NewGuid())
                '{"SchemaVersion":1,"BreakerTripped":false,"ConsecutiveFailures":0,"StateHmac":"abc="}' |
                    Set-Content -LiteralPath $path -Encoding UTF8
                Mock Get-StateHmacKey { return $null }
                Mock Write-SecurityEventLog { }
                $s = Get-RemediatorState -Path $path
                $s.BreakerTripped | Should -BeTrue
                Assert-MockCalled Write-SecurityEventLog -Exactly 1 -ParameterFilter { $EventId -eq 1006 }
            }
        }
    }

    Context 'HMAC mismatch (tampered file)' {
        It 'returns fail-closed defaults and fires event 1006' {
            InModuleScope ArcRemediator {
                $path = Join-Path $TestDrive ("state-hmacbad-{0}.json" -f [guid]::NewGuid())
                '{"SchemaVersion":1,"BreakerTripped":false,"ConsecutiveFailures":0,"StateHmac":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}' |
                    Set-Content -LiteralPath $path -Encoding UTF8
                Mock Get-StateHmacKey { return [byte[]](1..32) }
                Mock Write-SecurityEventLog { }
                $s = Get-RemediatorState -Path $path
                $s.BreakerTripped | Should -BeTrue
                Assert-MockCalled Write-SecurityEventLog -Exactly 1 -ParameterFilter { $EventId -eq 1006 }
            }
        }
    }

    Context 'HMAC valid — state trusted' {
        It 'returns the state as-is when HMAC verifies' {
            InModuleScope ArcRemediator {
                $key = [byte[]](1..32)
                $inner = [PSCustomObject]@{
                    SchemaVersion       = 1
                    BreakerTripped      = $false
                    ConsecutiveFailures = 7
                }
                $jsonForHmac = $inner | ConvertTo-Json -Depth 10
                $hmac = Get-StateHmac -Json $jsonForHmac -Key $key

                $withHmac = [PSCustomObject]@{
                    SchemaVersion       = 1
                    BreakerTripped      = $false
                    ConsecutiveFailures = 7
                    StateHmac           = $hmac
                }
                $path = Join-Path $TestDrive ("state-good-{0}.json" -f [guid]::NewGuid())
                ($withHmac | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $path -Encoding UTF8
                Mock Get-StateHmacKey { return [byte[]](1..32) }
                $s = Get-RemediatorState -Path $path
                $s.BreakerTripped | Should -BeFalse
                $s.ConsecutiveFailures | Should -Be 7
            }
        }
    }
}

Describe 'Set-RemediatorState HMAC signing' {

    Context 'Key available' {
        It 'writes a StateHmac field to the JSON when a key exists' {
            InModuleScope ArcRemediator {
                Mock Get-StateHmacKey { return [byte[]](1..32) }
                $path = Join-Path $TestDrive ("state-sign-{0}.json" -f [guid]::NewGuid())
                $state = [PSCustomObject]@{ SchemaVersion=1; BreakerTripped=$false; ConsecutiveFailures=0 }
                Set-RemediatorState -State $state -Path $path -Confirm:$false
                $written = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                $written.StateHmac | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'No key available' {
        It 'writes state without StateHmac when key returns null' {
            InModuleScope ArcRemediator {
                Mock Get-StateHmacKey { return $null }
                $path = Join-Path $TestDrive ("state-nosign-{0}.json" -f [guid]::NewGuid())
                $state = [PSCustomObject]@{ SchemaVersion=1; BreakerTripped=$false; ConsecutiveFailures=0 }
                Set-RemediatorState -State $state -Path $path -Confirm:$false
                $written = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                $written.PSObject.Properties['StateHmac'] | Should -BeNullOrEmpty
            }
        }
    }
}
