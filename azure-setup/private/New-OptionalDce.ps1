#Requires -Version 5.1

function New-OptionalDce {
    <#
        .SYNOPSIS
            Create or reuse a Data Collection Endpoint, returning its
            logs ingestion URL.

        .DESCRIPTION
             a DCE is created only when:

              * the operator explicitly requested one (the driver passes
                -UseDataCollectionEndpoint), OR
              * an existing DCR is already DCE-backed and the driver is
                reusing it.

            By default the new DCR carries its own
            properties.endpoints.logsIngestion (kind:Direct) and no DCE
            is needed. DCE regionality follows the destination Log
            Analytics workspace. not the Arc machine
            region.

            Idempotent: an existing DCE at the same resource path is
            reused; only its existing endpoint is read.

        .PARAMETER ResourceGroupName
            Resource group for the DCE.

        .PARAMETER DceName
            DCE resource name.

        .PARAMETER Location
            Azure region. Must match the destination workspace region.

        .PARAMETER SubscriptionId
            Optional. Defaults to (Get-AzContext).Subscription.Id.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$DceName,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter()]
        [string]$SubscriptionId
    )

    if (-not $SubscriptionId) {
        $SubscriptionId = (Get-AzContext).Subscription.Id
    }

    $dcePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$DceName"
    $apiVersion = '2022-06-01'

    $existing = Invoke-AzRestMethod -Path "${dcePath}?api-version=$apiVersion" -Method 'GET' -ErrorAction SilentlyContinue
    if ($existing -and $existing.StatusCode -eq 200) {
        $dce = $existing.Content | ConvertFrom-Json
        return [PSCustomObject]@{
            DceResourceId = $dcePath
            LogsIngestionUrl = $dce.properties.logsIngestion.endpoint
        }
    }

    $body = [ordered]@{
        location = $Location
        properties = @{
            networkAcls = @{
                publicNetworkAccess = 'Enabled'
            }
        }
    }
    $payload = $body | ConvertTo-Json -Depth 10

    if (-not $PSCmdlet.ShouldProcess($DceName, "PUT $dcePath")) {
        return
    }

    $response = Invoke-AzRestMethod -Path "${dcePath}?api-version=$apiVersion" -Method 'PUT' -Payload $payload -ErrorAction Stop
    if ($response.StatusCode -ge 400) {
        throw "Failed to PUT DCE '$DceName': HTTP $($response.StatusCode) - $($response.Content)"
    }

    $dce = $response.Content | ConvertFrom-Json
    return [PSCustomObject]@{
        DceResourceId = $dcePath
        LogsIngestionUrl = $dce.properties.logsIngestion.endpoint
    }
}
