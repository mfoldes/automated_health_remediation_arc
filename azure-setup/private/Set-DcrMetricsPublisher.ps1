#Requires -Version 5.1

function Set-DcrMetricsPublisher {
    <#
        .SYNOPSIS
            Assign the Monitoring Metrics Publisher role to a service
            principal at the DCR scope so it can POST to Logs Ingestion.

        .DESCRIPTION
             the Logs
            Ingestion service principal must hold the Monitoring Metrics
            Publisher built-in role on the DCR (scope =
            DcrResourceId). Without this role, POSTs to
            /dataCollectionRules/{id}/streams/{stream} return HTTP 403.

            Role definition ID is pinned from Microsoft Learn:
              Monitoring Metrics Publisher:
                3913510d-42f4-4e42-8a64-420c390055eb

            The function is idempotent: an existing assignment for
            (ObjectId, RoleDefinitionId, Scope) is kept; only missing
            assignments are created.

        .PARAMETER DcrResourceId
            Full ARM resource ID of the DCR. Used as the assignment
            scope so the SP can only ingest into this one DCR.

        .PARAMETER LogsIngestionSpObjectId
            AAD object ID of the Logs Ingestion service principal --
            NOT the application ID. This is the value returned in
            ObjectId by New-ScopedServicePrincipal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$DcrResourceId,

        [Parameter(Mandatory)]
        [string]$LogsIngestionSpObjectId
    )

    $roleId = '3913510d-42f4-4e42-8a64-420c390055eb'

    $existing = Get-AzRoleAssignment `
        -ObjectId $LogsIngestionSpObjectId `
        -RoleDefinitionId $roleId `
        -Scope $DcrResourceId `
        -ErrorAction SilentlyContinue
    if ($existing) {
        return
    }

    if (-not $PSCmdlet.ShouldProcess($DcrResourceId, "New-AzRoleAssignment Monitoring Metrics Publisher")) {
        return
    }

    $null = New-AzRoleAssignment `
        -ObjectId $LogsIngestionSpObjectId `
        -RoleDefinitionId $roleId `
        -Scope $DcrResourceId `
        -ErrorAction Stop
}
