#Requires -Version 5.1

function Get-StateHmacKey {
    <#
        .SYNOPSIS
            Get (or create) the HMAC-SHA256 key used to sign state.json.

        .DESCRIPTION
            On first call, generates a 32-byte cryptographically random key,
            wraps it with DPAPI LocalMachine scope, and persists it to -KeyPath.
            On subsequent calls, reads and unwraps the existing key.

            Returns $null if:
            - The key file does not exist (pre-upgrade machine; no key yet).
              Callers treat this as "no HMAC enforcement until next write."
            - DPAPI unwrap fails (machine key rotated, file tampered).
              Callers treat this as a soft failure; tamper is only detectable
              when the key is absent but a StateHmac field IS present in state.

        .PARAMETER KeyPath
            Path to the DPAPI-wrapped key file.
            Defaults to %ProgramData%\ArcRemediator\state.key.

        .PARAMETER Create
            When specified, generate a new key and persist it if the key file
            does not already exist. Without -Create, this function is read-only.

        .OUTPUTS
            Byte[] (32 bytes) on success, or $null on missing/unreadable key.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter()]
        [string]$KeyPath = (Join-Path $env:ProgramData 'ArcRemediator\state.key'),

        [Parameter()]
        [switch]$Create
    )

    Add-Type -AssemblyName System.Security

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        if (-not $Create) {
            return $null
        }
        # Generate a fresh 32-byte key, DPAPI-wrap it, and persist atomically.
        $rawKey = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $rng.GetBytes($rawKey)
        } finally {
            $rng.Dispose()
        }
        try {
            $wrapped = [System.Security.Cryptography.ProtectedData]::Protect(
                $rawKey,
                $null,
                [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
            $dir = Split-Path -Parent $KeyPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            $tmp = "$KeyPath.tmp"
            [System.IO.File]::WriteAllBytes($tmp, $wrapped)
            Move-Item -LiteralPath $tmp -Destination $KeyPath -Force
        } finally {
            for ($i = 0; $i -lt $rawKey.Length; $i++) { $rawKey[$i] = 0 }
        }
        # Re-read so the caller gets the key via the normal unwrap path.
    }

    try {
        $wrapped = [System.IO.File]::ReadAllBytes($KeyPath)
        $key = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $wrapped,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return $key
    } catch {
        return $null
    }
}

function Get-StateHmac {
    <#
        .SYNOPSIS
            Compute HMAC-SHA256 over the state JSON and return as Base64.

        .PARAMETER Json
            The serialized state JSON string (without the StateHmac field).

        .PARAMETER Key
            32-byte HMAC key from Get-StateHmacKey.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Json,
        [Parameter(Mandatory)] [byte[]]$Key
    )

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $Key
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $hash = $hmac.ComputeHash($bytes)
        return [System.Convert]::ToBase64String($hash)
    } finally {
        $hmac.Dispose()
    }
}
