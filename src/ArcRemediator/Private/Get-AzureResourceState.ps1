#Requires -Version 5.1

function Get-AzureResourceState {
    <#
        .SYNOPSIS
            ARM GET the local Arc machine resource and return a typed
            classification plus the fields needed for downstream action
            (tags, ETag, location, name).

        .DESCRIPTION
             this classifier returns
            exactly one of:

              Connected, Disconnected, Expired, AzureMachineError,
              ResourceNotFound, ArmForbidden, ArmThrottled,
              ArmTransientFailure, Unknown

            Status-to-classification map:
              200 + properties.status == 'Connected' -> Connected
              200 + properties.status == 'Disconnected' -> Disconnected
              200 + properties.status == 'Expired' -> Expired *
              200 + properties.status == 'Error' -> AzureMachineError
              200 + other / parse failure -> Unknown
              404 -> ResourceNotFound
              403 -> ArmForbidden
              429 -> ArmThrottled
              5xx / network / timeout -> ArmTransientFailure

            * and the requirement, the
              exact ARM JSON shape for an Expired machine is not pinned in
              the public REST reference. The bare 'properties.status ==
              Expired' branch exists here because that is the shape the
              Microsoft Learn agent release notes describe, but Enforce is
              not allowed for Expired until a lab-captured response from a
              real Expired machine validates the classifier per MVP cloud.
              Unit tests intentionally do not mock the Expired case --
              lab-captured fixtures are the source of truth.

            ETag is read from the HTTP response header rather than from the
            JSON body so we get the value the next PATCH must echo via
            If-Match. If the header is absent, we fall back to body 'etag'
            for clouds/proxies that strip the header.

        .PARAMETER CloudProfile
            From Get-CloudProfile. Must expose ArmEndpoint.

        .PARAMETER SubscriptionId
            Subscription that owns the Arc resource.

        .PARAMETER ResourceGroupName
            RG that owns the Arc resource.

        .PARAMETER MachineName
            Microsoft.HybridCompute/machines name.

        .PARAMETER AccessToken
            ARM bearer token (acquired via Get-AzureToken -Purpose Arc).
            Sent in the Authorization header; never logged.

        .PARAMETER TimeoutSec
            HTTP timeout. Default 30.

        .PARAMETER ApiVersion
            Microsoft.HybridCompute/machines API version. Default
            '2024-07-10', the GA version at spec time.

        .OUTPUTS
            PSCustomObject with:
              Classification (string)
              StatusCode (int?)
              ETag (string|null) suitable for an If-Match header
              Tags (object|null) the .tags subobject from ARM
              Location (string|null)
              Name (string)
              Raw (object|null) parsed body for diagnostic use
              ErrorMessage (string|null)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSObject]$CloudProfile,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$MachineName,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter()] [int]$TimeoutSec = 30,
        [Parameter()] [string]$ApiVersion = '2024-07-10'
    )

    $armBase = ([string]$CloudProfile.ArmEndpoint).TrimEnd('/')
    $uri = "$armBase/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$MachineName" + "?api-version=$ApiVersion"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    try {
        $resp = Invoke-WebRequestWithTls `
            -Uri $uri `
            -Method 'GET' `
            -Headers $headers `
            -TimeoutSec $TimeoutSec
    } catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $r = $_.Exception.Response
            if ($r.PSObject.Properties.Name -contains 'StatusCode' -and $r.StatusCode) {
                $statusCode = [int]$r.StatusCode
            }
        }

        $cls = if ($null -eq $statusCode) {
            'ArmTransientFailure'
        } elseif ($statusCode -eq 404) {
            'ResourceNotFound'
        } elseif ($statusCode -eq 403) {
            'ArmForbidden'
        } elseif ($statusCode -eq 429) {
            'ArmThrottled'
        } elseif ($statusCode -ge 500 -and $statusCode -le 599) {
            'ArmTransientFailure'
        } else {
            'Unknown'
        }

        return [PSCustomObject]@{
            Classification = $cls
            StatusCode = $statusCode
            ETag = $null
            Tags = $null
            Location = $null
            Name = $MachineName
            Raw = $null
            ErrorMessage = $_.Exception.Message
        }
    }

    $obj = $null
    try {
        $obj = $resp.Content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{
            Classification = 'Unknown'
            StatusCode = 200
            ETag = $null
            Tags = $null
            Location = $null
            Name = $MachineName
            Raw = $resp.Content
            ErrorMessage = 'ARM 200 body could not be parsed as JSON.'
        }
    }

    $status = $null
    $objProps = @($obj.PSObject.Properties.Name)
    if ($objProps -contains 'properties') {
        $propsProps = @($obj.properties.PSObject.Properties.Name)
        if ($propsProps -contains 'status') {
            $status = [string]$obj.properties.status
        }
    }

    $cls = switch ($status) {
        'Connected' { 'Connected' }
        'Disconnected' { 'Disconnected' }
        'Expired' { 'Expired' }
        'Error' { 'AzureMachineError' }
        default { 'Unknown' }
    }

    $etag = $null
    if ($resp.PSObject.Properties.Name -contains 'Headers' -and $resp.Headers) {
        $hdrs = $resp.Headers
        if ($hdrs -is [System.Collections.IDictionary]) {
            if ($hdrs.Contains('ETag')) { $etag = [string]($hdrs['ETag'] | Select-Object -First 1) }
        } else {
            $etagProp = $hdrs.PSObject.Properties | Where-Object { $_.Name -ieq 'ETag' } | Select-Object -First 1
            if ($etagProp) { $etag = [string]($etagProp.Value | Select-Object -First 1) }
        }
    }
    if (-not $etag -and ($objProps -contains 'etag')) {
        $etag = [string]$obj.etag
    }

    $tags = $null
    if ($objProps -contains 'tags') { $tags = $obj.tags }

    $location = $null
    if ($objProps -contains 'location') { $location = [string]$obj.location }

    return [PSCustomObject]@{
        Classification = $cls
        StatusCode = 200
        ETag = $etag
        Tags = $tags
        Location = $location
        Name = $MachineName
        Raw = $obj
        ErrorMessage = $null
    }
}
