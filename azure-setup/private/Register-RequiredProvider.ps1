#Requires -Version 5.1

function Register-RequiredProvider {
    <#
        .SYNOPSIS
            Ensure every required Azure resource provider is registered in the
            current subscription. Fails closed if registration is needed but
            the setup identity cannot perform it.

        .DESCRIPTION
             Setup-AzureSide.ps1 must register
            the providers Azure Arc and the remediator depend on. The
            mandatory set is:

                Microsoft.HybridCompute Arc machine resource type
                Microsoft.HybridConnectivity SSH Arc / endpoints
                Microsoft.GuestConfiguration Machine configuration / policy
                Microsoft.Insights DCR + Logs Ingestion
                Microsoft.OperationalInsights Log Analytics workspace
                Microsoft.Storage Kill-switch storage account

            When -IncludeSqlArc is set, Microsoft.AzureArcData is also
            registered for SQL Server enabled by Azure Arc.

            For each provider, Get-AzResourceProvider is called. If the
            provider is already 'Registered', it is skipped. Otherwise
            Register-AzResourceProvider is attempted. If any provider
            cannot be registered (typically because the setup identity
            lacks subscription-level Microsoft.Authorization permission),
            the function throws and lists which providers failed - by design, the operator pre-registers and re-runs.

        .PARAMETER ProviderNamespace
            Override list of provider namespaces. Defaults to the spec set
            above.

        .PARAMETER IncludeSqlArc
            Add Microsoft.AzureArcData to the required set. Used when the
            target deployment includes SQL Server enabled by Azure Arc.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter()]
        [string[]]$ProviderNamespace = @(
            'Microsoft.HybridCompute',
            'Microsoft.HybridConnectivity',
            'Microsoft.GuestConfiguration',
            'Microsoft.Insights',
            'Microsoft.OperationalInsights',
            'Microsoft.Storage'
        ),

        [Parameter()]
        [switch]$IncludeSqlArc
    )

    $targets = @($ProviderNamespace)
    if ($IncludeSqlArc) {
        $targets = $targets + 'Microsoft.AzureArcData'
    }

    $failed = New-Object 'System.Collections.Generic.List[string]'

    foreach ($ns in $targets) {
        $rp = Get-AzResourceProvider -ProviderNamespace $ns -ErrorAction Stop
        if ($rp -and $rp.RegistrationState -eq 'Registered') {
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($ns, 'Register-AzResourceProvider')) {
            continue
        }

        try {
            $null = Register-AzResourceProvider -ProviderNamespace $ns -ErrorAction Stop
        } catch {
            $failed.Add($ns)
        }
    }

    if ($failed.Count -gt 0) {
        throw ("Failed to register required resource providers: " +
            ($failed -join ', ') +
            ". The setup identity likely lacks subscription-level " +
            "Microsoft.Authorization permission. Pre-register these " +
            "providers with an operator that has the permission, then " +
            "re-run setup.")
    }
}
