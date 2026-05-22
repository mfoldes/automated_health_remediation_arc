#Requires -Version 5.1

function Invoke-OrchestratorDispatch {
    <#
        .SYNOPSIS
            Phases 7 and 8 of the remediator run: action dispatch + breaker
            state accounting.

        .DESCRIPTION
            Executes the five diagnostic probes (read-only in all modes), then
            branches on the ARM-side classification to take the appropriate
            remediator action.  Finally, updates the circuit-breaker counters in
            the $State object and persists it (Enforce mode only).

            The function mutates $State in-place (PSCustomObject reference
            semantics) so the caller can read the post-run state without the
            function returning it.  All other outputs are collected in the
            returned result object.

        .PARAMETER Config
            Decrypted config object (Get-DecryptedConfig output).

        .PARAMETER State
            Remediator state object (Get-RemediatorState output). Mutated
            in-place during breaker accounting.

        .PARAMETER Mode
            'Observe' or 'Enforce'.

        .PARAMETER CloudProfile
            Cloud profile object (Get-CloudProfile output).

        .PARAMETER Connectivity
            Local agent connectivity snapshot (Get-ArcConnectivitySettings
            output).

        .PARAMETER ResourceState
            ARM GET classification result (Get-AzureResourceState output).

        .PARAMETER LocalRg
            Effective resource group (from connectivity or COMPUTERNAME fallback).

        .PARAMETER LocalName
            Effective machine name (from connectivity or COMPUTERNAME fallback).

        .PARAMETER ArmAccessToken
            Bearer token for ARM (from Get-AzureToken -Purpose Arc).

        .PARAMETER EventTime
            Run start UTC timestamp; used for breaker state timestamps.

        .PARAMETER StatePath
            Path to state.json; forwarded to Set-RemediatorState.

        .PARAMETER AzcmagentPath
            Optional override for azcmagent.exe; forwarded to
            Invoke-AzcmagentCheck and Invoke-ExpiredRejoin.

        .PARAMETER Sw
            Running stopwatch from the orchestrator start; used for the
            self-deadline guard.

        .OUTPUTS
            [PSCustomObject] with:
              OutcomeString      string  Final Outcome value for the run.
              OutcomeDetail      string  One-line explanation.
              ActionsAttempted   string[] Action names attempted.
              ActionsSuccessful  string[] Subset that succeeded.
              ProbeCheck         object  Invoke-AzcmagentCheck result (may be $null).
              ProbeServices      object  Test-AgentServices result (may be $null).
              ProbeCert          object  Get-AgentCertificateProbe result.
              ProbeTime          object  Get-TimeSyncProbe result.
              ProbeVersion       object  Get-AgentVersionProbe result.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'All parameters forwarded to sub-helpers; analyzer cannot trace the indirection.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSObject]$Config,
        [Parameter(Mandatory)] [PSObject]$State,
        [Parameter(Mandatory)] [string]$Mode,
        [Parameter(Mandatory)] [PSObject]$CloudProfile,
        [Parameter(Mandatory)] [PSObject]$Connectivity,
        [Parameter(Mandatory)] [PSObject]$ResourceState,
        [Parameter(Mandatory)] [string]$LocalRg,
        [Parameter(Mandatory)] [string]$LocalName,
        [Parameter(Mandatory)] [string]$ArmAccessToken,
        [Parameter(Mandatory)] [datetime]$EventTime,
        [Parameter(Mandatory)] [string]$StatePath,
        [Parameter()] [string]$LogDirectory,
        [Parameter()] [string]$AzcmagentPath,
        [Parameter(Mandatory)] [System.Diagnostics.Stopwatch]$Sw
    )

    $actionsAttempted = New-Object System.Collections.Generic.List[string]
    $actionsSuccessful = New-Object System.Collections.Generic.List[string]
    $outcomeString = $null
    $outcomeDetail = $null

    # ---- Per-host pause (checked BEFORE probes and BEFORE any branching) ----
    # Operators set the Arc resource tag 'Remediation=Paused' (case-sensitive)
    # when they want this single host skipped without pausing the whole fleet.
    # Honored in BOTH modes; runs no probes and takes no action. Returns
    # outcome 'MachinePaused' which maps to exit code 0 via
    # ConvertTo-RemediatorExitCode (Task Scheduler last-run = Success).
    #
    # Property enumeration uses an explicit foreach because under
    # Set-StrictMode -Version 3.0 the `.Properties.Name` accessor throws
    # on an empty PSCustomObject (no properties to splat from).
    if ($ResourceState.Tags) {
        foreach ($tagProp in $ResourceState.Tags.PSObject.Properties) {
            if ($tagProp.Name -ceq 'Remediation' -and ([string]$tagProp.Value) -ceq 'Paused') {
                return [PSCustomObject]@{
                    OutcomeString     = 'MachinePaused'
                    OutcomeDetail     = "Arc resource tag 'Remediation=Paused' is set; no probes, no actions."
                    ActionsAttempted  = @()
                    ActionsSuccessful = @()
                    ProbeCheck        = $null
                    ProbeServices     = $null
                    ProbeCert         = $null
                    ProbeTime         = $null
                    ProbeVersion      = $null
                }
            }
        }
    }

    # ---- Probes (read-only in all modes) ------------------------------------
    $probeCheck    = $null
    $probeServices = $null
    $probeCert     = $null
    $probeTime     = $null
    $probeVersion  = $null
    try { $probeCheck    = Invoke-AzcmagentCheck -CloudProfile $CloudProfile -Location $ResourceState.Location -AzcmagentPath $AzcmagentPath } catch { $null = $_ }
    try { $probeServices = Test-AgentServices -GatewayRequired:([bool]($Connectivity.ArcGatewayResourceId)) } catch { $null = $_ }
    try { $probeCert     = Get-AgentCertificateProbe -ConnectivitySettings $Connectivity } catch { $null = $_ }
    try { $probeTime     = Get-TimeSyncProbe } catch { $null = $_ }
    try { $probeVersion  = Get-AgentVersionProbe -ConnectivitySettings $Connectivity -SupportedFloor '1.40.0' } catch { $null = $_ }

    # ---- Phase 7: action dispatch by ARM classification ---------------------
    switch ($ResourceState.Classification) {
        'Connected' {
            $outcomeString = 'Healthy'
            $outcomeDetail = 'ARM and local agent both report Connected.'
            if ($Mode -eq 'Enforce') {
                $State.ConsecutiveFailures = 0
                $State.BreakerTripped = $false
                $State.LastSuccessfulRunUtc = $EventTime.ToString('o')
            }
            break
        }

        'Disconnected' {
            if ($Connectivity.NeedsHuman) {
                $outcomeString = 'NeedsHuman'
                $outcomeDetail = [string]$Connectivity.NeedsHumanReason
                break
            }
            # Arc agent certificate expired or near expiry: a service
            # restart will not heal an expired agent cert. Escalate to
            # NeedsHuman so an operator (or a separate workflow) can
            # decide between an in-place agent reset and a full
            # delete-and-rejoin. Honored in both Observe and Enforce.
            if ($probeCert -and ($probeCert.PSObject.Properties.Name -contains 'Status')) {
                $certStatus = [string]$probeCert.Status
                if ($certStatus -in @('Expired', 'NearExpiry')) {
                    $daysLeft = if ($probeCert.PSObject.Properties.Name -contains 'DaysUntilExpiry') { $probeCert.DaysUntilExpiry } else { $null }
                    $outcomeString = 'NeedsHuman'
                    $outcomeDetail = "Arc agent certificate is $certStatus (DaysUntilExpiry=$daysLeft); service repair cannot heal an expired/near-expiry agent cert."
                    break
                }
            }
            if ($Mode -eq 'Observe') {
                $outcomeString = 'ObserveOnly'
                $outcomeDetail = 'Disconnected; Observe mode means no service repair attempted.'
                break
            }
            # Anti-flapping: skip service restart if last repair was within 48 hours.
            if ($State.PSObject.Properties.Name -contains 'LastServiceRepairUtc' -and $State.LastServiceRepairUtc) {
                $repairStart = [datetime]::MinValue
                if ([datetime]::TryParse([string]$State.LastServiceRepairUtc, [ref]$repairStart)) {
                    $repairAge = ((Get-Date).ToUniversalTime() - $repairStart.ToUniversalTime())
                    if ($repairAge.TotalHours -lt 48) {
                        $outcomeString = 'ServiceRepairCooldown'
                        $outcomeDetail = "Disconnected; service repair within 48-hour cooldown (last repair $($State.LastServiceRepairUtc))."
                        break
                    }
                }
            }
            $actionsAttempted.Add('Repair-AgentServices')
            $repair = Repair-AgentServices -GatewayRequired:([bool]($Connectivity.ArcGatewayResourceId)) -Confirm:$false
            if ($repair.NeedsHuman) {
                $outcomeString = 'NeedsHuman'
                $outcomeDetail = [string]$repair.NeedsHumanReason
                break
            }
            if (@($repair.Restarted).Count -gt 0) {
                $actionsSuccessful.Add('Repair-AgentServices')
                $outcomeString = 'ServicesRepaired'
                $outcomeDetail = "Restarted services: $([string]::Join(', ', $repair.Restarted))."
                $State.LastServiceRepairUtc = (Get-Date).ToUniversalTime().ToString('o')
            } else {
                $outcomeString = 'ConnectivityBlocked'
                $outcomeDetail = 'Disconnected and no stopped services to restart; likely network or proxy issue.'
            }
        }

        'Expired' {
            if ($Mode -eq 'Observe') {
                $outcomeString = 'ObserveOnly'
                $outcomeDetail = 'Expired classification observed; Observe mode means no destructive remediation.'
                break
            }
            if ($Connectivity.IsClusterBacked) {
                $outcomeString = 'NeedsHuman'
                $outcomeDetail = [string]$Connectivity.NeedsHumanReason
                break
            }
            # Self-deadline guard: refuse to enter the destructive path if the
            # run has consumed more than MaxRuntimeMinutes.
            $maxRuntimeMin = 45
            if ($Config.PSObject.Properties.Name -contains 'MaxRuntimeMinutes' -and $null -ne $Config.MaxRuntimeMinutes) {
                $maxRuntimeMin = [int]$Config.MaxRuntimeMinutes
            }
            if ($Sw.Elapsed.TotalMinutes -ge $maxRuntimeMin) {
                $outcomeString = 'Aborted'
                $outcomeDetail = "SelfDeadlineHit: run elapsed $([int]$Sw.Elapsed.TotalMinutes) min >= MaxRuntimeMinutes=$maxRuntimeMin; deferring destructive remediation to next scheduled run."
                break
            }
            # Cooldown: full 7 days for a fresh attempt; shorter window
            # when the last attempt's failure mode means the destructive
            # DELETE already succeeded but a later step (connect / tag
            # restore / final verify) failed. In that case the next
            # attempt skips the DELETE entirely (see Invoke-ExpiredRejoin
            # "ResourceNotFound on pre-destructive re-read"), so burning
            # a full 7-day cooldown leaves the host stranded for no good
            # safety reason. Configurable via Config.ReconnectOnlyCooldownHours
            # (default 24h).
            if ($State.LastExpiredAttemptStartedUtc) {
                $started = [datetime]::MinValue
                if ([datetime]::TryParse([string]$State.LastExpiredAttemptStartedUtc, [ref]$started)) {
                    $reconnectOnlyOutcomes = @('ConnectFailed', 'TagsNotRestored', 'VerificationFailed')
                    $isReconnectOnly = ($State.PSObject.Properties.Name -contains 'LastExpiredAttemptOutcome') -and ([string]$State.LastExpiredAttemptOutcome -in $reconnectOnlyOutcomes)
                    if ($isReconnectOnly) {
                        $reconnectCooldownHours = 24
                        if ($Config.PSObject.Properties.Name -contains 'ReconnectOnlyCooldownHours' -and $null -ne $Config.ReconnectOnlyCooldownHours) {
                            $reconnectCooldownHours = [int]$Config.ReconnectOnlyCooldownHours
                        }
                        $age = ((Get-Date).ToUniversalTime() - $started.ToUniversalTime())
                        if ($age.TotalHours -lt $reconnectCooldownHours) {
                            $outcomeString = 'CooldownSkipped'
                            $outcomeDetail = "Expired rejoin within $reconnectCooldownHours-hour reconnect-only cooldown (started $($State.LastExpiredAttemptStartedUtc), outcome=$($State.LastExpiredAttemptOutcome))."
                            break
                        }
                    } else {
                        $age = ((Get-Date).ToUniversalTime() - $started.ToUniversalTime())
                        if ($age.TotalDays -lt 7) {
                            $outcomeString = 'CooldownSkipped'
                            $outcomeDetail = "Expired rejoin within 7-day cooldown (started $($State.LastExpiredAttemptStartedUtc), outcome=$($State.LastExpiredAttemptOutcome))."
                            break
                        }
                    }
                }
            }
            # Circuit breaker check (with fleet-scale auto-reset via blob).
            if ([bool]$State.BreakerTripped) {
                # Check for operator-issued fleet-wide breaker reset.
                if ($Config.PSObject.Properties.Name -contains 'BreakerResetUrl' -and $Config.BreakerResetUrl) {
                    $breakerReset = Get-BreakerResetState -BreakerResetUrl $Config.BreakerResetUrl -BreakerTrippedUtc $State.BreakerTrippedUtc
                    if ($breakerReset.ShouldReset) {
                        $State.ConsecutiveFailures = 0
                        $State.BreakerTripped = $false
                        $State.BreakerLastResetUtc = (Get-Date).ToUniversalTime().ToString('o')
                        if ($LogDirectory) {
                            Write-LocalLog -Level 'Info' -Message "Circuit breaker auto-reset via fleet blob (reset timestamp=$($breakerReset.ResetTimestamp))." -Directory $LogDirectory
                        }
                        Write-SecurityEventLog -EventId 1002 -Message "ArcRemediator: circuit breaker auto-reset via fleet blob on machine $env:COMPUTERNAME (reset timestamp=$($breakerReset.ResetTimestamp))."
                    } else {
                        $outcomeString = 'BreakerTripped'
                        $outcomeDetail = "Circuit breaker tripped; not attempting Expired rejoin."
                        break
                    }
                } else {
                    $outcomeString = 'BreakerTripped'
                    $outcomeDetail = "Circuit breaker tripped; not attempting Expired rejoin."
                    break
                }
            }
            # Destructive path.
            $actionsAttempted.Add('Invoke-ExpiredRejoin')
            Write-SecurityEventLog -EventId 1004 -Message "ArcRemediator: entering Expired rejoin path on machine $env:COMPUTERNAME (sub=$($Config.SubscriptionId) rg=$LocalRg name=$LocalName)." -EntryType 'Warning'
            $rejoin = Invoke-ExpiredRejoin -CloudProfile $CloudProfile -ArcCredential $Config.ArcCredential `
                -AccessToken $ArmAccessToken -SubscriptionId $Config.SubscriptionId `
                -ResourceGroupName $LocalRg -MachineName $LocalName `
                -ConnectivitySettings $Connectivity -PreservedTags $ResourceState.Tags `
                -PreservedLocation $ResourceState.Location `
                -EnableAutomaticUpgrade:([bool]$Config.EnableAutomaticAgentUpgrade) `
                -StatePath $StatePath -AzcmagentPath $AzcmagentPath -Confirm:$false
            $outcomeDetail = $rejoin.Detail
            Write-SecurityEventLog -EventId 1005 -Message "ArcRemediator: Expired rejoin outcome '$($rejoin.Outcome)' on machine $env:COMPUTERNAME. Detail: $($rejoin.Detail)" -EntryType $(if ($rejoin.Outcome -eq 'ExpiredRejoined') { 'Information' } else { 'Warning' })
            switch ($rejoin.Outcome) {
                'ExpiredRejoined'      { $outcomeString = 'ExpiredRejoinSuccess'; $actionsSuccessful.Add('Invoke-ExpiredRejoin') }
                'ExpiredRejoinFailure' { $outcomeString = 'ExpiredRejoinFailure' }
                'NeedsHuman'           { $outcomeString = 'NeedsHuman' }
                'ConfigMismatch'       { $outcomeString = 'ConfigMismatch' }
                'Aborted'              { $outcomeString = 'Healthy'; $outcomeDetail = 'Pre-destructive re-read no longer classified as Expired; nothing destructive performed.' }
                'WhatIf'               { $outcomeString = 'ObserveOnly' }
                default                { $outcomeString = 'Error' }
            }
        }
    }

    # ---- Phase 8: breaker accounting (Enforce only) -------------------------
    if ($Mode -eq 'Enforce') {
        $failingOutcomes = @('AuthFailure','ConfigMismatch','ArmForbidden','AzureMachineError','ExpiredRejoinFailure','Error')
        if ($outcomeString -in $failingOutcomes) {
            $State.ConsecutiveFailures = [int]$State.ConsecutiveFailures + 1
            $threshold = if ($Config.PSObject.Properties.Name -contains 'CircuitBreakerFailureThreshold' -and $Config.CircuitBreakerFailureThreshold) {
                [int]$Config.CircuitBreakerFailureThreshold
            } else { 3 }
            if ($State.ConsecutiveFailures -ge $threshold) {
                $State.BreakerTripped = $true
                $State.BreakerTrippedUtc = (Get-Date).ToUniversalTime().ToString('o')
                Write-SecurityEventLog -EventId 1001 -Message "ArcRemediator: circuit breaker tripped on machine $env:COMPUTERNAME after $($State.ConsecutiveFailures) consecutive failures (threshold=$threshold, outcome=$outcomeString)." -EntryType 'Warning'
            }
        } elseif ($outcomeString -in @('Healthy', 'ServicesRepaired', 'ExpiredRejoinSuccess')) {
            $State.ConsecutiveFailures = 0
            $State.BreakerTripped = $false
            $State.LastSuccessfulRunUtc = $EventTime.ToString('o')
        }
        try { Set-RemediatorState -State $State -Path $StatePath -Confirm:$false } catch { $null = $_ }
    }

    return [PSCustomObject]@{
        OutcomeString     = $outcomeString
        OutcomeDetail     = $outcomeDetail
        ActionsAttempted  = $actionsAttempted.ToArray()
        ActionsSuccessful = $actionsSuccessful.ToArray()
        ProbeCheck        = $probeCheck
        ProbeServices     = $probeServices
        ProbeCert         = $probeCert
        ProbeTime         = $probeTime
        ProbeVersion      = $probeVersion
    }
}
