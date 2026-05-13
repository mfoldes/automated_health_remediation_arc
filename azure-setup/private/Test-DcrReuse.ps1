#Requires -Version 5.1

function Test-DcrReuse {
    <#
        .SYNOPSIS
            Analyze an existing DCR's endpoint configuration to decide
            whether it can be reused as-is, paired with an existing DCE,
            or must be replaced.

        .DESCRIPTION
            (and the corrections in commit
            1efca8f): when an operator points the setup script at an
            existing DCR by resource ID, the script must decide which
            ingestion endpoint to use:

              1. If properties.endpoints.logsIngestion is present, the
                 DCR was created with kind:Direct. Reuse it; the
                 endpoint goes into the generated config.

              2. Else if properties.dataCollectionEndpointId is set,
                 the DCR is DCE-backed. Reuse it; the DCE's logs
                 ingestion endpoint goes into the generated config.

              3. If neither, the DCR cannot be used. The driver will
                 either create a replacement DCR (default) or fail
                 (when -NoReplace is in effect). By design, the setup
                 must NOT pretend a standalone DCE can fix an unlinked
                 DCR.

            Returns a PSObject with the analysis so the driver can
            decide the next step without re-reading the DCR.

        .PARAMETER DcrResourceId
            Full ARM resource ID of the DCR to inspect.

        .OUTPUTS
            PSCustomObject with:
              Exists $false if HTTP 404, else $true.
              HasLogsIngestion $true if properties.endpoints.logsIngestion is set.
              HasDce $true if properties.dataCollectionEndpointId is set.
              DceResourceId The DCE ARM resource ID (when HasDce).
              Endpoint The logs ingestion URL to use (or $null
                                when neither is configured - caller
                                must replace or fail).
              DcrJson The full parsed DCR body for further use.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$DcrResourceId
    )

    $response = Invoke-AzRestMethod -Path "${DcrResourceId}?api-version=2023-03-11" -Method 'GET' -ErrorAction Stop

    if ($response.StatusCode -eq 404) {
        return [PSCustomObject]@{
            Exists = $false
            HasLogsIngestion = $false
            HasDce = $false
            DceResourceId = $null
            Endpoint = $null
            DcrJson = $null
        }
    }
    if ($response.StatusCode -ge 400) {
        throw "Failed to read DCR '$DcrResourceId': HTTP $($response.StatusCode) - $($response.Content)"
    }

    $body = $response.Content | ConvertFrom-Json

    $hasLogs = $false
    $endpoint = $null
    if ($body.properties.PSObject.Properties.Name -contains 'endpoints' -and
        $body.properties.endpoints -and
        $body.properties.endpoints.PSObject.Properties.Name -contains 'logsIngestion' -and
        $body.properties.endpoints.logsIngestion) {
        $hasLogs = $true
        $endpoint = $body.properties.endpoints.logsIngestion
    }

    $hasDce = $false
    $dceId = $null
    if ($body.properties.PSObject.Properties.Name -contains 'dataCollectionEndpointId' -and
        $body.properties.dataCollectionEndpointId) {
        $hasDce = $true
        $dceId = $body.properties.dataCollectionEndpointId
    }

    # Prefer the DCR-embedded logsIngestion if both are present. Otherwise
    # fall back to the DCE - resolve its endpoint via a second GET.
    if (-not $hasLogs -and $hasDce) {
        $dceResponse = Invoke-AzRestMethod -Path "${dceId}?api-version=2022-06-01" -Method 'GET' -ErrorAction Stop
        if ($dceResponse.StatusCode -lt 400 -and $dceResponse.Content) {
            $dceBody = $dceResponse.Content | ConvertFrom-Json
            if ($dceBody.properties.logsIngestion.endpoint) {
                $endpoint = $dceBody.properties.logsIngestion.endpoint
            }
        }
    }

    return [PSCustomObject]@{
        Exists = $true
        HasLogsIngestion = $hasLogs
        HasDce = $hasDce
        DceResourceId = $dceId
        Endpoint = $endpoint
        DcrJson = $body
    }
}
