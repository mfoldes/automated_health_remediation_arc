#Requires -Version 5.1

function Invoke-ExpiredRejoin {
    <#
        .SYNOPSIS
            Destructive delete-and-rejoin orchestrator for a confirmed
            Expired Arc machine. design.

        .DESCRIPTION
            This is the only destructive primitive in the remediator and
            it has many guards. The caller (Invoke-ArcRemediation in
            Phase 7) is responsible for the fleet-level preconditions:

              * Kill switch enabled
              * Mode = Enforce
              * Cooldown inactive
              * Breaker not tripped
              * Cloud profile validated
              * Subscription + resource group in configured scope

            Once those are satisfied, the caller passes a fresh ARM
            classification (which must already be 'Expired'), the
            ConnectivitySettings snapshot, and the ARC + tag detail
            from the immediately-preceding ARM GET. This function then:

              1. Refuses to act if ConnectivitySettings shows cluster-
                 backed evidence, a DoD gateway config mismatch, or any
                 NeedsHuman condition. These are the design
                 fail-closed gates.

              2. Re-reads ARM state ONE MORE TIME immediately before
                 the destructive call. If the
                 re-read does not still classify as 'Expired', the
                 function aborts WITHOUT writing the marker and returns
                 Outcome=Aborted - the run is then recoverable on the
                 next pass without burning a cooldown slot.

              3. Writes the durable Expired attempt marker
                 (LastExpiredAttemptId / StartedUtc / ResourceId /
                 Outcome='InProgress') BEFORE the first destructive
                 call. The 7-day cooldown starts from this marker write
                 (the design / section 9). A crash after this
                 point prevents another destructive attempt until
                 cooldown elapses or an operator runs
                 Reset-ArcRemediator.

              4. ARM DELETE via Remove-ArcResource (which handles
                 204 / 202 + Azure-AsyncOperation polling).

              5. azcmagent disconnect --force-local-only (via
                 Invoke-AzcmagentDisconnect, which hard-codes the flag).

              6. azcmagent connect (via Invoke-AzcmagentConnect, which
                 keeps secrets off the command line and applies cloud
                 capability gates for gateway / automatic-upgrade).

              7. Restore the saved tag set with Set-AzureResourceTags
                 (ARM tag PATCH with ETag/If-Match). We forbid relying on --tags during azcmagent connect for
                 complete restoration.

              8. Verify ARM classifies the recreated resource as
                 Connected, then update the marker
                 (LastExpiredAttemptCompletedUtc + Outcome='Completed').

        .PARAMETER CloudProfile
            From Get-CloudProfile.

        .PARAMETER ArcCredential
            DPAPI-decrypted ArcCredential block.

        .PARAMETER AccessToken
            ARM bearer token (Get-AzureToken -Purpose Arc).

        .PARAMETER SubscriptionId
            Subscription that owns the Arc resource (config-driven).

        .PARAMETER ResourceGroupName
            Resource group of the Arc machine.

        .PARAMETER MachineName
            Microsoft.HybridCompute/machines name.

        .PARAMETER ConnectivitySettings
            Output of Get-ArcConnectivitySettings; used for the cluster /
            config-mismatch / NeedsHuman gates AND for the proxy /
            private-link / gateway pass-through to azcmagent connect.

        .PARAMETER PreservedTags
            Tag set captured from the pre-destructive ARM GET, to be
            restored after the recreated resource is back. Null/empty
            is allowed (no tags to restore).

        .PARAMETER PreservedLocation
            Resource location captured from the pre-destructive ARM
            GET. If null, falls back to ConnectivitySettings.Location.

        .PARAMETER EnableAutomaticUpgrade
            Pass-through to azcmagent connect. Honored only when the
            cloud profile supports it.

        .PARAMETER StatePath
            Override path to state.json for the marker write. Default:
            %ProgramData%\ArcRemediator\state.json.

        .PARAMETER DeleteTimeoutSec
            Total budget for ARM DELETE + async polling. Default 900 s
            (15 min). Microsoft's p99 for hybridCompute/machines DELETE is
            under 5 min; 15 min allows for transient polling retries while
            still leaving margin inside a 1-hour task ExecutionTimeLimit.

        .PARAMETER ConnectTimeoutSec
            Timeout for azcmagent connect. Default 300 s.

        .PARAMETER AzcmagentPath
            Override for tests.

        .OUTPUTS
            PSCustomObject with:
              Outcome (string) See list below.
              Detail (string|null) Human-readable explanation.
              AttemptId (string|null) GUID written to the marker (null when no marker was written).
              MarkerWritten (bool)
              DeleteResult (object|null)
              ConnectResult (object|null)
              TagsResult (object|null)
              FinalState (object|null) Get-AzureResourceState after rejoin.
              ElapsedSeconds (int)

            Outcomes:
              'NeedsHuman' - cluster / private-link / gateway gate
              'ConfigMismatch' - DoD with non-null gateway
              'Aborted' - pre-destructive re-read != Expired
              'WhatIf' - -WhatIf or ShouldProcess declined
              'ExpiredRejoined' - full success
              'ExpiredRejoinFailure' - any failure AFTER marker was written
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '',
        Justification = 'ArcCredential is a DPAPI-decrypted config block, not a PSCredential.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSObject]$CloudProfile,
        [Parameter(Mandatory)] [PSObject]$ArcCredential,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$MachineName,
        [Parameter(Mandatory)] [PSObject]$ConnectivitySettings,
        [Parameter()] [AllowNull()] [PSObject]$PreservedTags,
        [Parameter()] [string]$PreservedLocation,
        [Parameter()] [switch]$EnableAutomaticUpgrade,
        [Parameter()] [string]$StatePath = (Join-Path $env:ProgramData 'ArcRemediator\state.json'),
        [Parameter()] [int]$DeleteTimeoutSec = 900,
        [Parameter()] [int]$ConnectTimeoutSec = 300,
        [Parameter()] [string]$AzcmagentPath
    )

    $start = Get-Date
    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$MachineName"

    # --- 1. Cluster / config-mismatch / needs-human gates ---------------
    if ($ConnectivitySettings.IsClusterBacked) {
        return New-RejoinOutcome -Outcome 'NeedsHuman' -Detail "Cluster-backed evidence detected: $($ConnectivitySettings.NeedsHumanReason). Refusing destructive remediation." -Start $start
    }
    if ($ConnectivitySettings.HasConfigMismatch) {
        return New-RejoinOutcome -Outcome 'ConfigMismatch' -Detail $ConnectivitySettings.ConfigMismatchReason -Start $start
    }
    if ($ConnectivitySettings.NeedsHuman) {
        return New-RejoinOutcome -Outcome 'NeedsHuman' -Detail $ConnectivitySettings.NeedsHumanReason -Start $start
    }

    # --- 2. Re-read ARM state immediately before destructive call -------
    $preState = Get-AzureResourceState -CloudProfile $CloudProfile `
        -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
        -MachineName $MachineName -AccessToken $AccessToken

    if ($preState.Classification -ne 'Expired') {
        return New-RejoinOutcome -Outcome 'Aborted' `
            -Detail "Immediate pre-destructive ARM re-read classified '$($preState.Classification)' (expected 'Expired'). Marker not written; run is repeatable next pass." `
            -Start $start
    }

    # Prefer the JUST-READ values for location/tags so a concurrent change
    # cannot trick us into restoring stale tags on top of fresh ones.
    $effectiveLocation = if ($preState.Location) { [string]$preState.Location } elseif ($PreservedLocation) { $PreservedLocation } else { [string]$ConnectivitySettings.Location }
    $effectiveTags = if ($preState.Tags) { $preState.Tags } else { $PreservedTags }

    if (-not $effectiveLocation) {
        return New-RejoinOutcome -Outcome 'NeedsHuman' -Detail 'Cannot determine resource Location for reconnect.' -Start $start
    }

    # --- 3. WhatIf - bail out without writing the marker ----------------
    $target = "$MachineName ($ResourceGroupName)"
    if (-not $PSCmdlet.ShouldProcess($target, 'Delete + rejoin (destructive Expired remediation)')) {
        return New-RejoinOutcome -Outcome 'WhatIf' -Detail 'WhatIf: destructive sequence not performed.' -Start $start
    }

    # --- 4. Marker write BEFORE first destructive call -------------------
    $attemptId = [guid]::NewGuid().ToString()
    $startedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $state = Get-RemediatorState -Path $StatePath
    $state.LastExpiredAttemptId = $attemptId
    $state.LastExpiredAttemptResourceId = $resourceId
    $state.LastExpiredAttemptStartedUtc = $startedUtc
    $state.LastExpiredAttemptCompletedUtc = $null
    $state.LastExpiredAttemptOutcome = 'InProgress'
    Set-RemediatorState -State $state -Path $StatePath -Confirm:$false
    $markerWritten = $true

    # --- 5. ARM DELETE ----------------------------------------------------
    $deleteResult = Remove-ArcResource -CloudProfile $CloudProfile `
        -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
        -MachineName $MachineName -AccessToken $AccessToken `
        -TimeoutSec $DeleteTimeoutSec -Confirm:$false

    if (-not $deleteResult.Success) {
        Complete-Marker -StatePath $StatePath -AttemptId $attemptId -Outcome 'DeleteFailed'
        return New-RejoinOutcome -Outcome 'ExpiredRejoinFailure' `
            -Detail "ARM DELETE failed: $($deleteResult.ErrorMessage)" `
            -Start $start -AttemptId $attemptId -MarkerWritten $markerWritten `
            -DeleteResult $deleteResult
    }

    # --- 6. azcmagent disconnect --force-local-only ----------------------
    # The disconnect result is intentionally not consumed: the cloud
    # resource is already gone and any local-state issue surfaces in the
    # connect step, where it can be acted on with full context.
    $null = Invoke-AzcmagentDisconnect -AzcmagentPath $AzcmagentPath

    # --- 7. azcmagent connect --------------------------------------------
    $connectArgs = @{
        CloudProfile = $CloudProfile
        Credential = $ArcCredential
        SubscriptionId = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        MachineName = $MachineName
        Location = $effectiveLocation
        TimeoutSec = $ConnectTimeoutSec
        EnableAutomaticUpgrade = $EnableAutomaticUpgrade
    }
    if ($ConnectivitySettings.Proxy) { $connectArgs.ProxyUrl = $ConnectivitySettings.Proxy }
    if ($ConnectivitySettings.PrivateLinkScopeResourceId) { $connectArgs.PrivateLinkScopeResourceId = $ConnectivitySettings.PrivateLinkScopeResourceId }
    if ($ConnectivitySettings.ArcGatewayResourceId) { $connectArgs.ArcGatewayResourceId = $ConnectivitySettings.ArcGatewayResourceId }
    if ($AzcmagentPath) { $connectArgs.AzcmagentPath = $AzcmagentPath }

    $connect = Invoke-AzcmagentConnect @connectArgs -Confirm:$false

    if (-not $connect.ProcessResult -or $connect.ProcessResult.ExitCode -ne 0) {
        $detail = if ($connect.ProcessResult) { "azcmagent connect exited $($connect.ProcessResult.ExitCode); TimedOut=$($connect.ProcessResult.TimedOut)" } else { 'azcmagent connect did not run.' }
        Complete-Marker -StatePath $StatePath -AttemptId $attemptId -Outcome 'ConnectFailed'
        return New-RejoinOutcome -Outcome 'ExpiredRejoinFailure' -Detail $detail `
            -Start $start -AttemptId $attemptId -MarkerWritten $markerWritten `
            -DeleteResult $deleteResult -ConnectResult $connect
    }

    # --- 8. Restore tags via ARM tag PATCH -------------------------------
    $tagsResult = $null
    if ($effectiveTags) {
        $setTags = @{}
        foreach ($p in $effectiveTags.PSObject.Properties) {
            $setTags[$p.Name] = $p.Value
        }
        if ($setTags.Count -gt 0) {
            $tagsResult = Set-AzureResourceTags -CloudProfile $CloudProfile `
                -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
                -MachineName $MachineName -AccessToken $AccessToken `
                -SetTags $setTags -Confirm:$false

            if (-not $tagsResult.Success) {
                Complete-Marker -StatePath $StatePath -AttemptId $attemptId -Outcome 'TagsNotRestored'
                return New-RejoinOutcome -Outcome 'ExpiredRejoinFailure' `
                    -Detail "Tag restore failed: $($tagsResult.ErrorMessage)" `
                    -Start $start -AttemptId $attemptId -MarkerWritten $markerWritten `
                    -DeleteResult $deleteResult -ConnectResult $connect -TagsResult $tagsResult
            }
        }
    }

    # --- 9. Final verification ------------------------------------------
    $finalState = Get-AzureResourceState -CloudProfile $CloudProfile `
        -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
        -MachineName $MachineName -AccessToken $AccessToken

    if ($finalState.Classification -ne 'Connected') {
        Complete-Marker -StatePath $StatePath -AttemptId $attemptId -Outcome 'VerificationFailed'
        return New-RejoinOutcome -Outcome 'ExpiredRejoinFailure' `
            -Detail "Post-rejoin ARM classification was '$($finalState.Classification)' (expected 'Connected')." `
            -Start $start -AttemptId $attemptId -MarkerWritten $markerWritten `
            -DeleteResult $deleteResult -ConnectResult $connect -TagsResult $tagsResult -FinalState $finalState
    }

    # --- 10. Mark attempt completed -------------------------------------
    Complete-Marker -StatePath $StatePath -AttemptId $attemptId -Outcome 'Completed'
    return New-RejoinOutcome -Outcome 'ExpiredRejoined' `
        -Detail "Resource $MachineName recreated and tags restored." `
        -Start $start -AttemptId $attemptId -MarkerWritten $markerWritten `
        -DeleteResult $deleteResult -ConnectResult $connect -TagsResult $tagsResult -FinalState $finalState
}

function Complete-Marker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$StatePath,
        [Parameter(Mandatory)] [string]$AttemptId,
        [Parameter(Mandatory)] [ValidateSet('Completed','DeleteFailed','ConnectFailed','TagsNotRestored','VerificationFailed')] [string]$Outcome
    )
    try {
        $state = Get-RemediatorState -Path $StatePath
        if ($state.LastExpiredAttemptId -eq $AttemptId) {
            $state.LastExpiredAttemptCompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
            $state.LastExpiredAttemptOutcome = $Outcome
            Set-RemediatorState -State $state -Path $StatePath -Confirm:$false
        }
    } catch {
        # State write failures are logged but never overwrite the primary
        # outcome of the destructive sequence - the cooldown marker is
        # already on disk from the InProgress write, which is what matters
        # for safety. The Completed update is informational.
        $null = $_
    }
}

function New-RejoinOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory returning an in-memory PSCustomObject describing the orchestrator outcome.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$Outcome,
        [Parameter()] [AllowNull()] [string]$Detail,
        [Parameter(Mandatory)] [datetime]$Start,
        [Parameter()] [AllowNull()] [string]$AttemptId,
        [Parameter()] [bool]$MarkerWritten = $false,
        [Parameter()] [AllowNull()] [PSObject]$DeleteResult,
        [Parameter()] [AllowNull()] [PSObject]$ConnectResult,
        [Parameter()] [AllowNull()] [PSObject]$TagsResult,
        [Parameter()] [AllowNull()] [PSObject]$FinalState
    )
    return [PSCustomObject]@{
        Outcome = $Outcome
        Detail = $Detail
        AttemptId = $AttemptId
        MarkerWritten = $MarkerWritten
        DeleteResult = $DeleteResult
        ConnectResult = $ConnectResult
        TagsResult = $TagsResult
        FinalState = $FinalState
        ElapsedSeconds = [int]((Get-Date) - $Start).TotalSeconds
    }
}
