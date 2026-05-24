#Requires -Version 5.1

function New-LawAndTable {
    <#
        .SYNOPSIS
            Create or reuse the Log Analytics workspace and the
            ArcRemediation_CL custom table.

        .DESCRIPTION
            steps 7-8 the remediator
            writes one row per completed scheduled run into a custom table
            named ArcRemediation_CL in a dedicated workspace. The custom table
            schema is fixed by the design.

            Workspace create/reuse uses Az.OperationalInsights cmdlets. Custom
            table creation uses the Logs management API directly via
            Invoke-AzRestMethod because Az.OperationalInsights does not yet
            cover the full custom-table surface across all PS 5.1-compatible
            module versions, and the PUT shape we need here is stable:
            https://learn.microsoft.com/azure/azure-monitor/logs/create-custom-table

            The column set matches the design exactly. TimeGenerated
            is populated by the DCR transform from EventTimeUtc; both are
            declared as datetime columns so the table accepts the
            transformed shape.

        .PARAMETER ResourceGroupName
            Resource group for the workspace.

        .PARAMETER WorkspaceName
            Workspace name.

        .PARAMETER Location
            Azure region. Must be a region that supports Logs Ingestion +
            DCR routing. The DCE / Logs Ingestion endpoint regionality
            follows the workspace.

        .PARAMETER TableName
            Custom table name. Defaults to 'ArcRemediation_CL'.

        .PARAMETER SubscriptionId
            Optional. Defaults to (Get-AzContext).Subscription.Id.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$WorkspaceName,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter()]
        [string]$TableName = 'ArcRemediation_CL',

        [Parameter()]
        [string]$SubscriptionId
    )

    # ---- Workspace create/reuse ----
    $ws = Get-AzOperationalInsightsWorkspace `
        -ResourceGroupName $ResourceGroupName `
        -Name $WorkspaceName `
        -ErrorAction SilentlyContinue

    if (-not $ws) {
        if (-not $PSCmdlet.ShouldProcess($WorkspaceName, 'New-AzOperationalInsightsWorkspace')) {
            return
        }
        $ws = New-AzOperationalInsightsWorkspace `
            -ResourceGroupName $ResourceGroupName `
            -Name $WorkspaceName `
            -Location $Location `
            -Sku 'PerGB2018' `
            -ErrorAction Stop
    }

    if (-not $SubscriptionId) {
        $SubscriptionId = (Get-AzContext).Subscription.Id
    }

    # ---- Custom table schema, fixed by the design ----
    $columns = @(
        @{ name = 'TimeGenerated'; type = 'datetime' },
        @{ name = 'EventTimeUtc'; type = 'datetime' },
        @{ name = 'SchemaVersion'; type = 'string' },
        @{ name = 'Hostname'; type = 'string' },
        @{ name = 'Fqdn'; type = 'string' },
        @{ name = 'CloudProfile'; type = 'string' },
        @{ name = 'SubscriptionId'; type = 'string' },
        @{ name = 'ResourceGroup'; type = 'string' },
        @{ name = 'Region'; type = 'string' },
        @{ name = 'AzureResourceId'; type = 'string' },
        @{ name = 'AgentVersion'; type = 'string' },
        @{ name = 'ScriptVersion'; type = 'string' },
        @{ name = 'ScriptMode'; type = 'string' },
        @{ name = 'RunDurationMs'; type = 'int' },
        @{ name = 'Outcome'; type = 'string' },
        @{ name = 'OutcomeDetail'; type = 'string' },
        @{ name = 'AzureSideState'; type = 'string' },
        @{ name = 'AgentReportedState'; type = 'string' },
        @{ name = 'ActionsAttempted'; type = 'dynamic' },
        @{ name = 'ActionsSuccessful'; type = 'dynamic' },
        @{ name = 'ProbeAzcmagentCheck'; type = 'dynamic' },
        @{ name = 'ProbeServices'; type = 'dynamic' },
        @{ name = 'ProbeCertificate'; type = 'dynamic' },
        @{ name = 'ProbeTimeSync'; type = 'dynamic' },
        @{ name = 'ProbeAgentVersion'; type = 'dynamic' },
        @{ name = 'ConsecutiveFailures'; type = 'int' },
        @{ name = 'BreakerTripped'; type = 'boolean' },
        @{ name = 'LastRemediationUtc'; type = 'datetime' },
        @{ name = 'ErrorMessage'; type = 'string' },
        @{ name = 'ErrorType'; type = 'string' },
        @{ name = 'StackTraceHash'; type = 'string' },
        @{ name = 'ResetByUser'; type = 'string' }
    )

    $payload = @{
        properties = @{
            schema = @{
                name = $TableName
                columns = $columns
            }
        }
    } | ConvertTo-Json -Depth 10

    $tablePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/tables/$($TableName)?api-version=2023-09-01"

    if (-not $PSCmdlet.ShouldProcess($TableName, "PUT $tablePath")) {
        return
    }

    $response = Invoke-AzRestMethod -Path $tablePath -Method 'PUT' -Payload $payload -ErrorAction Stop
    if ($response.StatusCode -ge 400) {
        throw "Failed to create custom table '$TableName': HTTP $($response.StatusCode) - $($response.Content)"
    }

    return [PSCustomObject]@{
        WorkspaceResourceId = $ws.ResourceId
        WorkspaceName = $WorkspaceName
        TableName = $TableName
        Location = $Location
    }
}
