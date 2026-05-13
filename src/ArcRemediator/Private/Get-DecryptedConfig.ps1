#Requires -Version 5.1

function Get-DecryptedConfig {
    <#
        .SYNOPSIS
            Read and decrypt the remediator config from disk.

        .DESCRIPTION
            Unwraps the DPAPI LocalMachine-scoped ciphertext at -Path and
            returns the deserialized config object. Throws if the file is
            missing, if DPAPI cannot decrypt (wrong scope, tampered, machine
            key rotated), or if the decrypted payload is not valid JSON.

            The plaintext byte buffer is zeroed in a finally block so it is
            not left in process memory after the function returns. The
            decrypted PSObject still holds secrets in managed strings --
            callers must continue to treat those strings as sensitive and
            never log them.

            DPAPI LocalMachine scope is per the design: any process
            running as SYSTEM or a Local Administrator on this machine can
            decrypt the config; the wrap protects against casual disclosure
            to standard users, not against admins.

        .PARAMETER Path
            Config file path. Defaults to %ProgramData%\ArcRemediator\config.json.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string]$Path = (Join-Path $env:ProgramData 'ArcRemediator\config.json')
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found at '$Path'."
    }

    Add-Type -AssemblyName System.Security

    $protected = [System.IO.File]::ReadAllBytes($Path)

    $plain = $null
    try {
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    } catch {
        throw "Failed to decrypt config at '$Path'. DPAPI may be in a different scope, the machine key may have rotated, or the file may be tampered: $($_.Exception.Message)"
    }

    try {
        $json = [System.Text.Encoding]::UTF8.GetString($plain)
        return ($json | ConvertFrom-Json -ErrorAction Stop)
    } finally {
        for ($i = 0; $i -lt $plain.Length; $i++) { $plain[$i] = 0 }
    }
}
