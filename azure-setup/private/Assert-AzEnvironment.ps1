#Requires -Version 5.1

function Assert-AzEnvironment {
    <#
        .SYNOPSIS
            Verify the current Az PowerShell context is connected to the cloud
            environment that matches the requested MVP profile.

        .DESCRIPTION
             Setup-AzureSide.ps1 must fail closed
            if run against the wrong Az environment. This helper compares the
            currently connected Az context's Environment.Name against the
            expected name for the chosen MVP profile and throws if they do not
            match.

            Commercial expects AzureCloud. AzureGovernmentDoD expects
            AzureUSGovernment. No other profiles are valid in MVP; the
            ValidateSet enforces that.

        .PARAMETER CloudProfile
            One of Commercial, AzureGovernmentDoD. Required.

        .OUTPUTS
            The active Az context (as returned by Get-AzContext) on success.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('Commercial', 'AzureGovernmentDoD')]
        [string]$CloudProfile
    )

    $context = Get-AzContext
    if (-not $context) {
        throw "No Az context. Run Connect-AzAccount before invoking Setup-AzureSide.ps1."
    }

    $expectedEnvName = switch ($CloudProfile) {
        'Commercial' { 'AzureCloud' }
        'AzureGovernmentDoD' { 'AzureUSGovernment' }
    }

    $actualEnvName = $context.Environment.Name
    if ($actualEnvName -ne $expectedEnvName) {
        throw ("Az context environment '$actualEnvName' does not match cloud profile '$CloudProfile' " +
            "(expected '$expectedEnvName'). " +
            "Use 'Connect-AzAccount -Environment $expectedEnvName' before re-running setup.")
    }

    return $context
}
