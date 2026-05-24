#Requires -Version 5.1

function Set-AzureResourceTags {
    <#
        .SYNOPSIS
            Apply a tag set/remove intent to the Arc machine resource with
            ETag/If-Match concurrency control and a single retry on 412.

        .DESCRIPTION
             tag writes must:
              1. Read current tags + ETag immediately before action.
              2. Apply the caller's set/remove intent on top of the read
                 result (so unrelated tags survive Remediation=ResetBreaker
                 removal).
              3. PATCH back with If-Match on the read ETag when ARM gave us
                 one.
              4. On HTTP 412 (ETag conflict), re-read once and retry. A
                 second 412 returns a typed conflict result rather than
                 overwriting blindly.

            Observe mode must NOT call this function - enforcement of that
            policy is the caller's responsibility (see the design).

        .PARAMETER CloudProfile
            From Get-CloudProfile. Must expose ArmEndpoint.

        .PARAMETER SubscriptionId
            Subscription that owns the Arc resource.

        .PARAMETER ResourceGroupName
            RG that owns the Arc resource.

        .PARAMETER MachineName
            Microsoft.HybridCompute/machines name.

        .PARAMETER AccessToken
            ARM bearer token (Get-AzureToken -Purpose Arc).

        .PARAMETER SetTags
            Keys to set or overwrite. Empty hashtable is allowed when the
            caller only wants to remove keys.

        .PARAMETER RemoveTagKeys
            Tag keys to remove. Unknown keys are silently ignored (the
            merge result is what matters).

        .PARAMETER TimeoutSec
            HTTP timeout. Default 30.

        .PARAMETER ApiVersion
            Microsoft.HybridCompute/machines API version. Default
            '2025-01-13'.

        .OUTPUTS
            PSCustomObject with:
              Success (bool)
              Classification (string) ARM-state classification from the
                                       read immediately before PATCH.
              Conflict (bool) $true only if the second 412 fired.
              ETag (string) the ETag passed as If-Match
              AppliedTags (hashtable|null) merged tag set actually PATCHed
              ErrorMessage (string|null)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Tag PATCH operates on an arbitrary set of keys in one call (set N + remove M); naming the function Set-AzureResourceTag would mislead callers. ps1.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSObject]$CloudProfile,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$MachineName,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter()] [hashtable]$SetTags = @{},
        [Parameter()] [string[]]$RemoveTagKeys = @(),
        [Parameter()] [int]$TimeoutSec = 30,
        [Parameter()] [string]$ApiVersion = '2025-01-13'
    )

    $armBase = ([string]$CloudProfile.ArmEndpoint).TrimEnd('/')
    $uri = "$armBase/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$MachineName" + "?api-version=$ApiVersion"

    $maxAttempts = 2
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {

        $state = Get-AzureResourceState `
            -CloudProfile $CloudProfile `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -MachineName $MachineName `
            -AccessToken $AccessToken `
            -TimeoutSec $TimeoutSec `
            -ApiVersion $ApiVersion

        if ($state.Classification -notin @('Connected', 'Disconnected', 'Expired', 'AzureMachineError', 'Unknown')) {
            return [PSCustomObject]@{
                Success = $false
                Classification = $state.Classification
                Conflict = $false
                ETag = $null
                AppliedTags = $null
                ErrorMessage = "Cannot PATCH tags: pre-write ARM GET returned $($state.Classification)."
            }
        }

        $merged = @{}
        if ($state.Tags) {
            foreach ($p in $state.Tags.PSObject.Properties) {
                $merged[$p.Name] = $p.Value
            }
        }
        foreach ($k in $SetTags.Keys) { $merged[$k] = $SetTags[$k] }
        foreach ($rk in $RemoveTagKeys) {
            if ($merged.ContainsKey($rk)) { $merged.Remove($rk) }
        }

        $body = (@{ tags = $merged } | ConvertTo-Json -Depth 5 -Compress)

        $headers = @{ Authorization = "Bearer $AccessToken" }
        if ($state.ETag) { $headers['If-Match'] = $state.ETag }

        $target = "$MachineName tags"
        if (-not $PSCmdlet.ShouldProcess($target, 'PATCH tags')) {
            return [PSCustomObject]@{
                Success = $false
                Classification = $state.Classification
                Conflict = $false
                ETag = $state.ETag
                AppliedTags = $merged
                ErrorMessage = 'WhatIf: PATCH not performed.'
            }
        }

        try {
            $null = Invoke-RestMethodWithTls `
                -Uri $uri `
                -Method 'PATCH' `
                -Headers $headers `
                -Body $body `
                -ContentType 'application/json' `
                -TimeoutSec $TimeoutSec

            return [PSCustomObject]@{
                Success = $true
                Classification = $state.Classification
                Conflict = $false
                ETag = $state.ETag
                AppliedTags = $merged
                ErrorMessage = $null
            }
        } catch {
            $code = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $r = $_.Exception.Response
                if ($r.PSObject.Properties.Name -contains 'StatusCode' -and $r.StatusCode) {
                    $code = [int]$r.StatusCode
                }
            }

            if ($code -eq 412 -and $attempt -lt $maxAttempts) {
                continue
            }

            $isConflict = ($code -eq 412)
            return [PSCustomObject]@{
                Success = $false
                Classification = $state.Classification
                Conflict = $isConflict
                ETag = $state.ETag
                AppliedTags = $null
                ErrorMessage = $_.Exception.Message
            }
        }
    }
}
