#Requires -Version 5.1

function Send-LogAnalytics {
    <#
        .SYNOPSIS
            POST one or more remediator rows to the Logs Ingestion API
            via the direct-ingestion DCR.

        .DESCRIPTION
             section 10, and the design, telemetry
            is sent to a kind:Direct DCR's logs ingestion endpoint:

              POST {LogIngestionEndpoint}/dataCollectionRules/{DcrImmutableId}/streams/{StreamName}?api-version=2023-01-01

            Authorization uses a Monitor-audience token (acquired via
            Get-AzureToken -Purpose Monitor) - never the ARM token. The DCR
            transformKql projects TimeGenerated from each row's EventTimeUtc, so callers populate EventTimeUtc in the
            rows; TimeGenerated does not need to be set by hand.

            Telemetry is best-effort. and the requirement, a POST failure must:
              * NOT throw out of this function;
              * NOT cause the scheduled task to exit non-zero when the
                primary remediation outcome succeeded;
              * be recorded locally as LogIngestionFailure (caller's job).

            This function therefore catches all HTTP / transport errors and
            returns a structured result the orchestrator translates into a
            local log line + outcome.

        .PARAMETER LogIngestionEndpoint
            The logs ingestion URL from the DCR (preferred) or DCE.

        .PARAMETER DcrImmutableId
            Immutable ID of the DCR.

        .PARAMETER StreamName
            Stream declaration name. Defaults to Custom-ArcRemediation.

        .PARAMETER AccessToken
            Bearer token for Monitor (Get-AzureToken -Purpose Monitor).
            Never logged.

        .PARAMETER Rows
            One or more row objects to ingest. Will be wrapped in a JSON
            array at the wire level.

        .PARAMETER TimeoutSec
            HTTP timeout. Default 30.

        .OUTPUTS
            PSCustomObject with:
              Success (bool)
              StatusCode (int|null)
              RowCount (int)
              ErrorMessage (string|null)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Analytics is a service name (Logs Ingestion / Log Analytics), not a plural noun. ps1.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$LogIngestionEndpoint,

        [Parameter(Mandatory)]
        [string]$DcrImmutableId,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter()]
        [string]$StreamName = 'Custom-ArcRemediation',

        [Parameter()]
        [int]$TimeoutSec = 30
    )

    $rowList = @($Rows)
    if ($rowList.Count -eq 0) {
        return [PSCustomObject]@{
            Success = $false
            StatusCode = $null
            RowCount = 0
            ErrorMessage = 'Send-LogAnalytics: no rows provided.'
        }
    }

    $endpoint = ([string]$LogIngestionEndpoint).TrimEnd('/')
    $uri = "$endpoint/dataCollectionRules/$DcrImmutableId/streams/$StreamName" + '?api-version=2023-01-01'

    $body = $rowList | ConvertTo-Json -Depth 10 -Compress
    # ConvertTo-Json on a single-element array drops the array wrapper in
    # PS5.1; force the wire format to a JSON array as the Logs Ingestion
    # API requires.
    if (-not $body.StartsWith('[')) { $body = '[' + $body + ']' }

    $headers = @{ Authorization = "Bearer $AccessToken" }

    try {
        $null = Invoke-RestMethodWithTls `
            -Uri $uri `
            -Method 'POST' `
            -Headers $headers `
            -Body $body `
            -ContentType 'application/json' `
            -TimeoutSec $TimeoutSec

        return [PSCustomObject]@{
            Success = $true
            StatusCode = 204
            RowCount = $rowList.Count
            ErrorMessage = $null
        }
    } catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $r = $_.Exception.Response
            if ($r.PSObject.Properties.Name -contains 'StatusCode' -and $r.StatusCode) {
                $statusCode = [int]$r.StatusCode
            }
        }
        return [PSCustomObject]@{
            Success = $false
            StatusCode = $statusCode
            RowCount = $rowList.Count
            ErrorMessage = $_.Exception.Message
        }
    }
}
