#Requires -Version 5.1

function Resolve-AzAccessToken {
    <#
        .SYNOPSIS
            Return the bearer string from a Get-AzAccessToken result, handling
            both the pre-Az-14 String shape and the Az 14+ SecureString shape.

        .DESCRIPTION
            Starting with Az.Accounts 5.0.0 / Az 14.0.0, Get-AzAccessToken
            returns a SecureString in .Token by default (see
            learn.microsoft.com/powershell/azure/protect-secrets). Older Az
            versions return a plain String. This helper accepts either shape
            and returns a plain bearer string suitable for an Authorization
            header.

            When the input is SecureString, the BSTR copy is allocated, read
            into a managed string, and the unmanaged buffer is zeroed via
            Marshal.ZeroFreeBSTR in a finally block. The managed string
            returned still holds the secret in process memory - callers
            must continue to treat it as sensitive and never log it.

        .PARAMETER TokenObject
            The PSObject returned by Get-AzAccessToken. Must have a .Token
            property whose value is either a String or a SecureString.

        .EXAMPLE
            $arm = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
            $bearer = Resolve-AzAccessToken -TokenObject $arm
            Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $bearer" }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$TokenObject
    )

    $value = $TokenObject.Token

    if ($value -is [System.Security.SecureString]) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($value)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    return [string]$value
}
