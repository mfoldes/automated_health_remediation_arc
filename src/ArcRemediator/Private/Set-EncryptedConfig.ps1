#Requires -Version 5.1

function Set-EncryptedConfig {
    <#
        .SYNOPSIS
            Serialize, encrypt, and persist the remediator config.

        .DESCRIPTION
            Serializes -Config to JSON, wraps it with DPAPI LocalMachine
            scope, then writes to <Path>.tmp and atomically renames to
            <Path>. Creates the parent directory if absent. Zeroes the
            plaintext byte buffer in a finally block before returning.

            Calling code must not pass an object whose values are SecureString
            or anything that ConvertTo-Json cannot round-trip; secrets should
            already be plain strings inside -Config by the time they reach
            this function so the DPAPI wrap is the security boundary.

        .PARAMETER Config
            Config object. Typically built from a config.sample.json or from
            a prior Get-DecryptedConfig result.

        .PARAMETER Path
            Destination path. Defaults to %ProgramData%\ArcRemediator\config.json.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [PSObject]$Config,

        [Parameter()]
        [string]$Path = (Join-Path $env:ProgramData 'ArcRemediator\config.json')
    )

    Add-Type -AssemblyName System.Security

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $json = $Config | ConvertTo-Json -Depth 10
    $plain = [System.Text.Encoding]::UTF8.GetBytes($json)

    try {
        $protected = [System.Security.Cryptography.ProtectedData]::Protect(
            $plain,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine)

        if (-not $PSCmdlet.ShouldProcess($Path, 'Write encrypted config')) {
            return
        }

        $temp = "$Path.tmp"
        [System.IO.File]::WriteAllBytes($temp, $protected)
        Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop
    } finally {
        for ($i = 0; $i -lt $plain.Length; $i++) { $plain[$i] = 0 }
    }
}
