#Requires -Version 5.1

function Remove-ArcResource {
    <#
        .SYNOPSIS
            ARM DELETE the Arc machine resource with 204/202 handling per
            the design.

        .DESCRIPTION
            This is the cloud-side destructive primitive used by
            Invoke-ExpiredRejoin. It does NOT touch the local agent --
            that is azcmagent disconnect's job, after the ARM resource
            is confirmed gone.

            Flow:
              1. PATCH-precondition: caller must have:
                 * Confirmed Expired evidence (Get-AzureResourceState)
                 * Wrote the durable Expired attempt marker
                 BEFORE calling this function. This function does not
                 verify those preconditions itself; the design
                 puts them on the orchestrator.
              2. ARM DELETE Microsoft.HybridCompute/machines/{name}.
              3. 204 No Content -> terminal success. Verify via GET 404.
              4. 202 Accepted -> read Azure-AsyncOperation (preferred) or
                 Location header; hand off to Wait-ArmAsyncOperation
                 with honored Retry-After + bounded exponential backoff
                 (default 30 min budget, configurable).
              5. After async Succeeded, verify ARM GET returns 404.
              6. 404 on DELETE -> idempotent success; verification skipped.
              7. Any other 4xx/5xx -> typed failure with status + body
                 excerpt (no secrets).

        .PARAMETER CloudProfile
            From Get-CloudProfile.

        .PARAMETER SubscriptionId
            Subscription that owns the Arc resource.

        .PARAMETER ResourceGroupName
            RG that owns the Arc resource.

        .PARAMETER MachineName
            Microsoft.HybridCompute/machines name.

        .PARAMETER AccessToken
            ARM bearer token (Get-AzureToken -Purpose Arc).

        .PARAMETER TimeoutSec
            Total budget for the destructive flow including async polling.
            Default 1800 (30 min). Configurable.

        .PARAMETER ApiVersion
            Microsoft.HybridCompute/machines API version. Default
            '2025-01-13'.

        .OUTPUTS
            PSCustomObject with:
              Success (bool)
              InitialStatusCode (int|null)
              AsyncOperationUrl (string|null)
              AsyncResult (object|null) from Wait-ArmAsyncOperation
              Verified404 (bool|null)
              ElapsedSeconds (int)
              ErrorMessage (string|null)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSObject]$CloudProfile,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$MachineName,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter()] [int]$TimeoutSec = 1800,
        [Parameter()] [string]$ApiVersion = '2025-01-13'
    )

    $start = Get-Date
    $armBase = ([string]$CloudProfile.ArmEndpoint).TrimEnd('/')
    $resourceUri = "$armBase/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$MachineName" + "?api-version=$ApiVersion"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    $target = "$MachineName in $ResourceGroupName"
    if (-not $PSCmdlet.ShouldProcess($target, 'ARM DELETE (destructive)')) {
        return [PSCustomObject]@{
            Success = $false
            InitialStatusCode = $null
            AsyncOperationUrl = $null
            AsyncResult = $null
            Verified404 = $null
            ElapsedSeconds = 0
            ErrorMessage = 'WhatIf: DELETE not performed.'
        }
    }

    $resp = $null
    $initial = $null
    try {
        $resp = Invoke-WebRequestWithTls -Uri $resourceUri -Method 'DELETE' -Headers $headers -TimeoutSec 60
        $initial = [int]$resp.StatusCode
    } catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $r = $_.Exception.Response
            if ($r.PSObject.Properties.Name -contains 'StatusCode' -and $r.StatusCode) {
                $statusCode = [int]$r.StatusCode
            }
        }
        # 404 on DELETE is idempotent success.
        if ($statusCode -eq 404) {
            return [PSCustomObject]@{
                Success = $true
                InitialStatusCode = 404
                AsyncOperationUrl = $null
                AsyncResult = $null
                Verified404 = $true
                ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
                ErrorMessage = $null
            }
        }
        return [PSCustomObject]@{
            Success = $false
            InitialStatusCode = $statusCode
            AsyncOperationUrl = $null
            AsyncResult = $null
            Verified404 = $null
            ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
            ErrorMessage = "DELETE failed: $($_.Exception.Message)"
        }
    }

    if ($initial -eq 204 -or $initial -eq 200) {
        # The design: 204 No Content is terminal success; no async wait
        # or GET verification is required. We still run the GET informationally
        # so the orchestrator can record Verified404 in the LAW row, but a
        # transient consistency lag on the GET must not falsify a spec-defined
        # terminal success.
        $verify = Test-ArcResource404 -CloudProfile $CloudProfile `
            -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
            -MachineName $MachineName -AccessToken $AccessToken -ApiVersion $ApiVersion
        return [PSCustomObject]@{
            Success = $true
            InitialStatusCode = $initial
            AsyncOperationUrl = $null
            AsyncResult = $null
            Verified404 = $verify
            ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
            ErrorMessage = $null
        }
    }

    if ($initial -eq 202) {
        $opUrl = Get-AsyncOperationUrl -Response $resp
        if (-not $opUrl) {
            return [PSCustomObject]@{
                Success = $false
                InitialStatusCode = 202
                AsyncOperationUrl = $null
                AsyncResult = $null
                Verified404 = $null
                ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
                ErrorMessage = '202 Accepted but neither Azure-AsyncOperation nor Location header was returned.'
            }
        }

        $remaining = [int]([Math]::Max(60, $TimeoutSec - ((Get-Date) - $start).TotalSeconds))
        $asyncResult = Wait-ArmAsyncOperation -OperationUrl $opUrl -AccessToken $AccessToken -TimeoutSec $remaining

        if (-not $asyncResult.Success) {
            return [PSCustomObject]@{
                Success = $false
                InitialStatusCode = 202
                AsyncOperationUrl = $opUrl
                AsyncResult = $asyncResult
                Verified404 = $null
                ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
                ErrorMessage = $asyncResult.ErrorMessage
            }
        }

        $verify = Test-ArcResource404 -CloudProfile $CloudProfile `
            -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
            -MachineName $MachineName -AccessToken $AccessToken -ApiVersion $ApiVersion
        return [PSCustomObject]@{
            Success = $verify
            InitialStatusCode = 202
            AsyncOperationUrl = $opUrl
            AsyncResult = $asyncResult
            Verified404 = $verify
            ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
            ErrorMessage = if (-not $verify) { 'Async operation reported Succeeded but GET did not return 404.' } else { $null }
        }
    }

    return [PSCustomObject]@{
        Success = $false
        InitialStatusCode = $initial
        AsyncOperationUrl = $null
        AsyncResult = $null
        Verified404 = $null
        ElapsedSeconds = [int]((Get-Date) - $start).TotalSeconds
        ErrorMessage = "Unexpected DELETE response status: $initial."
    }
}

function Get-AsyncOperationUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [PSObject]$Response)

    if (-not ($Response.PSObject.Properties.Name -contains 'Headers')) { return $null }
    $hdrs = $Response.Headers
    if (-not $hdrs) { return $null }

    foreach ($name in 'Azure-AsyncOperation', 'Location') {
        $val = $null
        if ($hdrs -is [System.Collections.IDictionary]) {
            if ($hdrs.Contains($name)) { $val = $hdrs[$name] }
        } else {
            $p = $hdrs.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
            if ($p) { $val = $p.Value }
        }
        if ($val) {
            $first = ($val | Select-Object -First 1)
            $s = [string]$first
            if (-not [string]::IsNullOrWhiteSpace($s)) { return $s }
        }
    }
    return $null
}

function Test-ArcResource404 {
    <#
        .SYNOPSIS
            Confirm ARM GET on the deleted resource returns 404. Returns
            $true only on a confirmed 404; any other response (200,
            transient failure) is treated as not-verified.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [PSObject]$CloudProfile,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$MachineName,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter()] [string]$ApiVersion = '2025-01-13'
    )

    $state = Get-AzureResourceState -CloudProfile $CloudProfile `
        -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
        -MachineName $MachineName -AccessToken $AccessToken -ApiVersion $ApiVersion -TimeoutSec 30

    return ($state.Classification -eq 'ResourceNotFound')
}
