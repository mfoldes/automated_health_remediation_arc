#Requires -Version 5.1

function New-DirectDcr {
    <#
        .SYNOPSIS
            PUT a new direct-ingestion Data Collection Rule routing
            Custom-ArcRemediation -> ArcRemediation_CL.

        .DESCRIPTION
            (and the F2-F4 corrections in
            commit 1efca8f), new DCRs MUST be created with kind:"Direct"
            so the response includes properties.endpoints.logsIngestion.
            The transform projects TimeGenerated from EventTimeUtc so
            the table accepts the rehydrated shape:

                streamDeclarations.Custom-ArcRemediation -> columns
                destinations.logAnalytics[0] -> the LAW
                dataFlows[0].streams -> Custom-ArcRemediation
                dataFlows[0].outputStream -> Custom-ArcRemediation_CL
                dataFlows[0].transformKql -> source | extend TimeGenerated = EventTimeUtc

            After the PUT, the response is validated: if
            properties.endpoints.logsIngestion is missing the function
            throws - this means kind:Direct was not honored, or the
            api-version is wrong, or the region does not support direct
            ingestion. Spec is explicit that this must fail closed.

            -DataCollectionEndpointId is optional and reserved for the
            private-link / DCE-backed code path; New-OptionalDce
            provisions it when needed.

        .PARAMETER ResourceGroupName
            Resource group for the DCR.

        .PARAMETER DcrName
            DCR resource name.

        .PARAMETER Location
            Azure region. Must be a region that supports kind:Direct
            DCRs + Logs Ingestion routing. DCR
            regionality follows the destination workspace.

        .PARAMETER WorkspaceResourceId
            Full ARM resource ID of the destination Log Analytics
            workspace.

        .PARAMETER StreamName
            Input stream name. Defaults to 'Custom-ArcRemediation'.

        .PARAMETER OutputStream
            Destination output stream. Defaults to
            'Custom-ArcRemediation_CL' and MUST match the custom table
            name + '_CL' suffix.

        .PARAMETER DataCollectionEndpointId
            Optional. ARM resource ID of an associated DCE. Use this
            only when private-link / network policy requires it.

        .PARAMETER SubscriptionId
            Optional. Defaults to (Get-AzContext).Subscription.Id.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$DcrName,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter(Mandatory)]
        [string]$WorkspaceResourceId,

        [Parameter()]
        [string]$StreamName = 'Custom-ArcRemediation',

        [Parameter()]
        [string]$OutputStream = 'Custom-ArcRemediation_CL',

        [Parameter()]
        [string]$DataCollectionEndpointId,

        [Parameter()]
        [string]$SubscriptionId
    )

    if (-not $SubscriptionId) {
        $SubscriptionId = (Get-AzContext).Subscription.Id
    }

    $dcrPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$DcrName"

    $columns = @(
        @{ name = 'EventTimeUtc'; type = 'datetime' },
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

    $properties = [ordered]@{
        streamDeclarations = @{
            $StreamName = @{ columns = $columns }
        }
        destinations = @{
            logAnalytics = @(
                @{
                    name = 'arcLaw'
                    workspaceResourceId = $WorkspaceResourceId
                }
            )
        }
        dataFlows = @(
            [ordered]@{
                streams = @($StreamName)
                destinations = @('arcLaw')
                outputStream = $OutputStream
                transformKql = 'source | extend TimeGenerated = EventTimeUtc'
            }
        )
    }

    if ($DataCollectionEndpointId) {
        $properties.dataCollectionEndpointId = $DataCollectionEndpointId
    }

    $body = [ordered]@{
        location = $Location
        kind = 'Direct'
        properties = $properties
    }
    $payload = $body | ConvertTo-Json -Depth 20

    if (-not $PSCmdlet.ShouldProcess($DcrName, "PUT $dcrPath (kind=Direct)")) {
        return
    }

    $response = Invoke-AzRestMethod -Path "${dcrPath}?api-version=2023-03-11" -Method 'PUT' -Payload $payload -ErrorAction Stop
    if ($response.StatusCode -ge 400) {
        throw "Failed to PUT DCR '$DcrName': HTTP $($response.StatusCode) - $($response.Content)"
    }

    $dcr = $response.Content | ConvertFrom-Json

    $logsIngestion = $null
    if ($dcr.properties.PSObject.Properties.Name -contains 'endpoints' -and
        $dcr.properties.endpoints -and
        $dcr.properties.endpoints.PSObject.Properties.Name -contains 'logsIngestion' -and
        $dcr.properties.endpoints.logsIngestion) {
        $logsIngestion = $dcr.properties.endpoints.logsIngestion
    }

    if (-not $logsIngestion) {
        throw ("DCR '$DcrName' was created but the response is missing " +
            "properties.endpoints.logsIngestion. New DCRs MUST be kind:Direct " +
            "and the response MUST include the logs ingestion endpoint per " +
            "the design. Check the api-version and region support.")
    }

    return [PSCustomObject]@{
        DcrResourceId = $dcrPath
        ImmutableId = $dcr.properties.immutableId
        LogsIngestion = $logsIngestion
        StreamName = $StreamName
        OutputStream = $OutputStream
    }
}
