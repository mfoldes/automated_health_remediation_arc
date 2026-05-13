#Requires -Version 5.1

function Invoke-ArcRemediation {
    <#
        .SYNOPSIS
            Run one scheduled remediator pass against the local Arc machine.

        .DESCRIPTION
            This is the public entry point invoked by the scheduled task once
            per day. It walks a linear decision tree:

              1. Acquire the local mutex so two copies cannot run at once.
              2. Load the DPAPI-wrapped config and local state.
              3. Read the kill-switch blob BEFORE any Azure auth. Anything
                 other than the literal word "enabled" pauses the run.
              4. Validate that the local agent's cloud and resource ID
                 match the configured cloud profile and scope; mismatch
                 fails closed before any token is acquired.
              5. Acquire separate ARM and Monitor access tokens.
              6. ARM GET the local machine resource and classify the
                 response into one of: Connected, Disconnected, Expired,
                 AzureMachineError, ResourceNotFound, ArmForbidden,
                 ArmThrottled, ArmTransientFailure, Unknown.
              7. Take action by classification and mode:
                   * Observe mode never mutates anything cloud-side.
                   * Connected     -> Healthy.
                   * Disconnected  -> restart stopped Arc services in
                                      Enforce; report ConnectivityBlocked
                                      or NeedsHuman otherwise.
                   * Expired       -> delete + rejoin only when fully
                                      gated (Enforce + not cluster-backed
                                      + 7-day cooldown elapsed + breaker
                                      not tripped).
              8. Update local state (consecutive failures, breaker,
                 last-successful timestamp).
              9. Emit one row to Log Analytics; a failure here is logged
                 locally but cannot change the primary exit code.

            The function is a single linear script rather than a state-
            machine class because Windows PowerShell 5.1 + Set-StrictMode
            3.0 make class-based state machines hard to debug. Each step
            either gates the next or short-circuits the run with a final
            outcome.

            The function never throws out of the top frame: any unhandled
            exception is caught at the outermost try/finally and translated
            to Outcome='Error' (exit 4) so the scheduled-task exit code is
            always one of the five documented values (0, 1, 2, 3, 4).

        .PARAMETER ConfigPath
            Path to the DPAPI-wrapped config file.
            Defaults to %ProgramData%\ArcRemediator\config.json.

        .PARAMETER StatePath
            Path to the local state file.
            Defaults to %ProgramData%\ArcRemediator\state.json.

        .PARAMETER LogDirectory
            Where the local log file is written.
            Defaults to %ProgramData%\ArcRemediator\logs.

        .PARAMETER OverrideMode
            Force 'Observe' or 'Enforce' regardless of what the config
            file says. Test-ArcRemediator uses this to pin to Observe;
            an operator can use it for a one-off dry run.

        .PARAMETER AzcmagentPath
            Override path to azcmagent.exe. Used by tests; production
            picks the default install path automatically.

        .OUTPUTS
            A PSCustomObject with:
              Outcome             string  Healthy, FleetPaused, NeedsHuman, etc.
              OutcomeDetail       string  One-line human explanation.
              ExitCode            int     0-4 for the scheduled task.
              Row                 hashtable  The LAW row that was sent.
              LogIngestionFailed  bool    True if the LAW POST failed.
              ErrorMessage        string  Set only when Outcome='Error'.
              ElapsedMs           int     Wall-clock run duration.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Parameters are forwarded to sub-helpers; analyzer cannot trace the indirection.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()] [string]$ConfigPath = (Join-Path $env:ProgramData 'ArcRemediator\config.json'),
        [Parameter()] [string]$StatePath = (Join-Path $env:ProgramData 'ArcRemediator\state.json'),
        [Parameter()] [string]$LogDirectory = (Join-Path $env:ProgramData 'ArcRemediator\logs'),
        [Parameter()] [ValidateSet('Observe', 'Enforce')] [string]$OverrideMode,
        [Parameter()] [string]$AzcmagentPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $eventTime = (Get-Date).ToUniversalTime()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Best-effort early log so a config-load failure still leaves a trace.
    try { Write-LocalLog -Message 'Invoke-ArcRemediation: starting run.' -Directory $LogDirectory } catch { $null = $_ }

    $mutex = $null
    $row = $null
    $logIngestionFailed = $false
    $outcomeString = 'Error'
    $outcomeDetail = $null
    $errorMessage = $null

    try {
        # ---- 1. Single-instance mutex --------------------------------------
        $mutexName = 'Global\ArcRemediator-' + $env:COMPUTERNAME
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        $acquired = $false
        try {
            $acquired = $mutex.WaitOne(2000, $false)
        } catch [System.Threading.AbandonedMutexException] {
            # Previous holder crashed; we acquired the mutex regardless.
            $acquired = $true
        }
        if (-not $acquired) {
            $outcomeString = 'Healthy'
            $outcomeDetail = 'Another remediator instance is running; this invocation exited without action.'
            return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $null -LogIngestionFailed $false -Elapsed $sw
        }

        # ---- 2. Load config + state ----------------------------------------
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            $outcomeString = 'ConfigMismatch'
            $outcomeDetail = "Config file not found at '$ConfigPath'."
            Write-LocalLog -Level 'Error' -Message $outcomeDetail -Directory $LogDirectory
            return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $null -LogIngestionFailed $false -Elapsed $sw
        }
        $cfg = Get-DecryptedConfig -Path $ConfigPath
        $state = Get-RemediatorState -Path $StatePath

        $mode = if ($OverrideMode) { $OverrideMode } else { [string]$cfg.Mode }
        if ($mode -notin @('Observe', 'Enforce')) { $mode = 'Observe' }

        $cloudProfile = Get-CloudProfile -Name $cfg.CloudProfile

        # ---- 3. Kill switch read BEFORE Azure auth ------------------------
        $kill = Get-KillSwitchState -KillSwitchUrl $cfg.KillSwitchUrl
        if (-not $kill.CanProceed) {
            $outcomeString = 'FleetPaused'
            $outcomeDetail = "Kill switch did not unlock the run (reason=$($kill.Reason))."
            $row = New-RemediatorRow -EventTimeUtc $eventTime -CloudProfile $cfg.CloudProfile -ScriptMode $mode `
                -Outcome $outcomeString -OutcomeDetail $outcomeDetail `
                -SubscriptionId $cfg.SubscriptionId -ResourceGroupName $null -MachineName $env:COMPUTERNAME `
                -RunDurationMs ([int]$sw.ElapsedMilliseconds) -RemediatorState $state
            return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $row -LogIngestionFailed $false -Elapsed $sw
        }

        # ---- 4. Local agent state + cloud-profile match -------------------
        $connectivity = Get-ArcConnectivitySettings -CloudProfile $cloudProfile -AzcmagentPath $AzcmagentPath
        $expectedAgentClouds = @()
        if ($cloudProfile.PSObject.Properties.Name -contains 'ExpectedAgentCloudValues') {
            $expectedAgentClouds = @($cloudProfile.ExpectedAgentCloudValues)
        }
        if ($connectivity.Cloud -and @($expectedAgentClouds).Count -gt 0 -and ($connectivity.Cloud -notin $expectedAgentClouds)) {
            $outcomeString = 'ConfigMismatch'
            $outcomeDetail = "Config CloudProfile '$($cfg.CloudProfile)' but azcmagent reports cloud '$($connectivity.Cloud)'."
            Write-LocalLog -Level 'Error' -Message $outcomeDetail -Directory $LogDirectory
            $row = New-RemediatorRow -EventTimeUtc $eventTime -CloudProfile $cfg.CloudProfile -ScriptMode $mode `
                -Outcome $outcomeString -OutcomeDetail $outcomeDetail -ConnectivitySettings $connectivity `
                -SubscriptionId $cfg.SubscriptionId -RunDurationMs ([int]$sw.ElapsedMilliseconds) -RemediatorState $state
            return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $row -LogIngestionFailed $false -Elapsed $sw
        }

        # Scope gate: local sub/RG must match configured scope.
        $localSub = $connectivity.SubscriptionId
        $localRg = $connectivity.ResourceGroupName
        $localName = if ($connectivity.ResourceName) { $connectivity.ResourceName } else { $env:COMPUTERNAME }
        if ($localSub -and ($localSub -ne $cfg.SubscriptionId)) {
            $outcomeString = 'ConfigMismatch'
            $outcomeDetail = "Local agent subscription '$localSub' is outside configured SubscriptionId '$($cfg.SubscriptionId)'."
            Write-LocalLog -Level 'Error' -Message $outcomeDetail -Directory $LogDirectory
            return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $null -LogIngestionFailed $false -Elapsed $sw
        }
        $scopedGroups = @($cfg.ScopedResourceGroups)
        if ($localRg -and @($scopedGroups).Count -gt 0 -and ($localRg -notin $scopedGroups)) {
            $outcomeString = 'ConfigMismatch'
            $outcomeDetail = "Local agent resource group '$localRg' is outside ScopedResourceGroups."
            Write-LocalLog -Level 'Error' -Message $outcomeDetail -Directory $LogDirectory
            return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $null -LogIngestionFailed $false -Elapsed $sw
        }

        # DoD/IL5 with non-null gateway = ConfigMismatch.
        if ($connectivity.HasConfigMismatch) {
            $outcomeString = 'ConfigMismatch'
            $outcomeDetail = [string]$connectivity.ConfigMismatchReason
            Write-LocalLog -Level 'Error' -Message $outcomeDetail -Directory $LogDirectory
            return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $null -LogIngestionFailed $false -Elapsed $sw
        }

        if (-not $localRg) { $localRg = $env:COMPUTERNAME } # fallback for orchestrator-side row population

        # ---- 5. Acquire SEPARATE ARM + Monitor tokens ---------------------
        try {
            $armToken = Get-AzureToken -CloudProfile $cloudProfile -Credential $cfg.ArcCredential -Purpose 'Arc'
            $monitorCred = if ([bool]($cfg.MonitorCredential.UseArcCredential)) { $cfg.ArcCredential } else { $cfg.MonitorCredential }
            $monitorToken = Get-AzureToken -CloudProfile $cloudProfile -Credential $monitorCred -Purpose 'Monitor'
        } catch {
            $outcomeString = 'AuthFailure'
            $outcomeDetail = "Token acquisition failed: $($_.Exception.Message)"
            $errorMessage = $_.Exception.Message
            Write-LocalLog -Level 'Error' -Message $outcomeDetail -Directory $LogDirectory
            return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $null -LogIngestionFailed $false -Elapsed $sw
        }

        # ---- 6. ARM GET classifier ----------------------------------------
        $resourceState = Get-AzureResourceState -CloudProfile $cloudProfile `
            -SubscriptionId $cfg.SubscriptionId -ResourceGroupName $localRg -MachineName $localName `
            -AccessToken $armToken.AccessToken

        # Map non-success classifications to outcomes BEFORE any mutation.
        $earlyOutcome = $null
        $earlyDetail = $null
        switch ($resourceState.Classification) {
            'ArmForbidden' { $earlyOutcome = 'ArmForbidden'; $earlyDetail = $resourceState.ErrorMessage; break }
            'ArmThrottled' { $earlyOutcome = 'ArmThrottled'; $earlyDetail = $resourceState.ErrorMessage; break }
            'ArmTransientFailure' { $earlyOutcome = 'ArmTransientFailure'; $earlyDetail = $resourceState.ErrorMessage; break }
            'ResourceNotFound' { $earlyOutcome = 'ResourceNotFound'; $earlyDetail = 'ARM GET returned 404; refusing to recreate automatically.'; break }
            'AzureMachineError' { $earlyOutcome = 'AzureMachineError'; $earlyDetail = 'ARM reports properties.status=Error without validated Expired evidence.'; break }
            'Unknown' { $earlyOutcome = 'Error'; $earlyDetail = 'ARM GET classifier returned Unknown.'; break }
        }
        if ($earlyOutcome) {
            $outcomeString = $earlyOutcome
            $outcomeDetail = $earlyDetail
            $row = Build-Row $eventTime $cfg $mode $outcomeString $outcomeDetail $resourceState $connectivity $localRg $localName $state @() @() $errorMessage $sw
            $logIngestionFailed = -not (Send-RowOrLogFailure $cfg $row $monitorToken $LogDirectory)
            return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $row -LogIngestionFailed $logIngestionFailed -Elapsed $sw
        }

        # ---- 7. Branch by classification (Connected / Disconnected / Expired) ----
        $actionsAttempted = New-Object System.Collections.Generic.List[string]
        $actionsSuccessful = New-Object System.Collections.Generic.List[string]

        # Probes (read-only in Observe; service probe still read-only here)
        $probeCheck = $null
        $probeServices = $null
        $probeCert = $null
        $probeTime = $null
        $probeVersion = $null
        try { $probeCheck = Invoke-AzcmagentCheck -CloudProfile $cloudProfile -Location $resourceState.Location -AzcmagentPath $AzcmagentPath } catch { $null = $_ }
        try { $probeServices = Test-AgentServices -GatewayRequired:([bool]($connectivity.ArcGatewayResourceId)) } catch { $null = $_ }
        try { $probeCert = Get-AgentCertificateProbe -ConnectivitySettings $connectivity } catch { $null = $_ }
        try { $probeTime = Get-TimeSyncProbe } catch { $null = $_ }
        try { $probeVersion = Get-AgentVersionProbe -ConnectivitySettings $connectivity -SupportedFloor '1.40.0' } catch { $null = $_ }

        switch ($resourceState.Classification) {
            'Connected' {
                $outcomeString = 'Healthy'
                $outcomeDetail = 'ARM and local agent both report Connected.'
                if ($mode -eq 'Enforce') {
                    # Reset consecutive failures on verified-connected.
                    $state.ConsecutiveFailures = 0
                    $state.BreakerTripped = $false
                    $state.LastSuccessfulRunUtc = $eventTime.ToString('o')
                }
                break
            }

            'Disconnected' {
                if ($connectivity.NeedsHuman) {
                    $outcomeString = 'NeedsHuman'
                    $outcomeDetail = [string]$connectivity.NeedsHumanReason
                    break
                }
                if ($mode -eq 'Observe') {
                    $outcomeString = 'ObserveOnly'
                    $outcomeDetail = 'Disconnected; Observe mode means no service repair attempted.'
                    break
                }
                $actionsAttempted.Add('Repair-AgentServices')
                $repair = Repair-AgentServices -GatewayRequired:([bool]($connectivity.ArcGatewayResourceId)) -Confirm:$false
                if ($repair.NeedsHuman) {
                    $outcomeString = 'NeedsHuman'
                    $outcomeDetail = [string]$repair.NeedsHumanReason
                    break
                }
                if (@($repair.Restarted).Count -gt 0) {
                    $actionsSuccessful.Add('Repair-AgentServices')
                    $outcomeString = 'ServicesRepaired'
                    $outcomeDetail = "Restarted services: $([string]::Join(', ', $repair.Restarted))."
                } else {
                    $outcomeString = 'ConnectivityBlocked'
                    $outcomeDetail = 'Disconnected and no stopped services to restart; likely network or proxy issue.'
                }
            }

            'Expired' {
                if ($mode -eq 'Observe') {
                    $outcomeString = 'ObserveOnly'
                    $outcomeDetail = 'Expired classification observed; Observe mode means no destructive remediation.'
                    break
                }
                if ($connectivity.IsClusterBacked) {
                    $outcomeString = 'NeedsHuman'
                    $outcomeDetail = [string]$connectivity.NeedsHumanReason
                    break
                }
                # Cooldown check: no more than one attempt per 7 days.
                if ($state.LastExpiredAttemptStartedUtc) {
                    $started = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$state.LastExpiredAttemptStartedUtc, [ref]$started)) {
                        $age = ((Get-Date).ToUniversalTime() - $started.ToUniversalTime())
                        if ($age.TotalDays -lt 7) {
                            $outcomeString = 'CooldownSkipped'
                            $outcomeDetail = "Expired rejoin within 7-day cooldown (started $($state.LastExpiredAttemptStartedUtc), outcome=$($state.LastExpiredAttemptOutcome))."
                            break
                        }
                    }
                }
                # Breaker check.
                if ([bool]$state.BreakerTripped) {
                    $outcomeString = 'BreakerTripped'
                    $outcomeDetail = "Circuit breaker tripped; not attempting Expired rejoin."
                    break
                }
                # Destructive path.
                $actionsAttempted.Add('Invoke-ExpiredRejoin')
                $rejoin = Invoke-ExpiredRejoin -CloudProfile $cloudProfile -ArcCredential $cfg.ArcCredential `
                    -AccessToken $armToken.AccessToken -SubscriptionId $cfg.SubscriptionId `
                    -ResourceGroupName $localRg -MachineName $localName `
                    -ConnectivitySettings $connectivity -PreservedTags $resourceState.Tags `
                    -PreservedLocation $resourceState.Location `
                    -EnableAutomaticUpgrade:([bool]$cfg.EnableAutomaticAgentUpgrade) `
                    -StatePath $StatePath -AzcmagentPath $AzcmagentPath -Confirm:$false
                $outcomeDetail = $rejoin.Detail
                switch ($rejoin.Outcome) {
                    'ExpiredRejoined' { $outcomeString = 'ExpiredRejoinSuccess'; $actionsSuccessful.Add('Invoke-ExpiredRejoin') }
                    'ExpiredRejoinFailure' { $outcomeString = 'ExpiredRejoinFailure' }
                    'NeedsHuman' { $outcomeString = 'NeedsHuman' }
                    'ConfigMismatch' { $outcomeString = 'ConfigMismatch' }
                    'Aborted' { $outcomeString = 'Healthy'; $outcomeDetail = 'Pre-destructive re-read no longer classified as Expired; nothing destructive performed.' }
                    'WhatIf' { $outcomeString = 'ObserveOnly' }
                    default { $outcomeString = 'Error' }
                }
            }
        }

        # ---- 8. State updates (breaker accounting) ------------------------
        if ($mode -eq 'Enforce') {
            $failingOutcomes = @('AuthFailure','ConfigMismatch','ArmForbidden','AzureMachineError','ExpiredRejoinFailure','Error')
            if ($outcomeString -in $failingOutcomes) {
                $state.ConsecutiveFailures = [int]$state.ConsecutiveFailures + 1
                $threshold = if ($cfg.PSObject.Properties.Name -contains 'CircuitBreakerFailureThreshold' -and $cfg.CircuitBreakerFailureThreshold) { [int]$cfg.CircuitBreakerFailureThreshold } else { 3 }
                if ($state.ConsecutiveFailures -ge $threshold) {
                    $state.BreakerTripped = $true
                }
            } elseif ($outcomeString -in @('Healthy','ServicesRepaired','ExpiredRejoinSuccess')) {
                $state.ConsecutiveFailures = 0
                $state.BreakerTripped = $false
                $state.LastSuccessfulRunUtc = $eventTime.ToString('o')
            }
            try { Set-RemediatorState -State $state -Path $StatePath -Confirm:$false } catch { $null = $_ }
        }

        # ---- 9. Build LAW row + best-effort send -------------------------
        $row = Build-Row $eventTime $cfg $mode $outcomeString $outcomeDetail $resourceState $connectivity $localRg $localName $state $actionsAttempted.ToArray() $actionsSuccessful.ToArray() $errorMessage $sw `
            -ProbeAzcmagentCheck $probeCheck -ProbeServices $probeServices -ProbeCertificate $probeCert -ProbeTimeSync $probeTime -ProbeAgentVersion $probeVersion

        $logIngestionFailed = -not (Send-RowOrLogFailure $cfg $row $monitorToken $LogDirectory)

        return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $row -LogIngestionFailed $logIngestionFailed -Elapsed $sw

    } catch {
        $errorMessage = $_.Exception.Message
        $traceText = if ($_.ScriptStackTrace) { [string]$_.ScriptStackTrace } else { '' }
        try {
            Write-LocalLog -Level 'Error' -Message "Invoke-ArcRemediation: unhandled $($_.Exception.GetType().FullName): $errorMessage" -Directory $LogDirectory
            if ($traceText) { Write-LocalLog -Level 'Error' -Message $traceText -Directory $LogDirectory }
        } catch { $null = $_ }
        $outcomeString = 'Error'
        $outcomeDetail = $errorMessage
        return New-RunResult -Outcome $outcomeString -Detail $outcomeDetail -Row $null -LogIngestionFailed $false -Elapsed $sw -ErrorMessage $errorMessage
    } finally {
        if ($mutex) {
            try { $mutex.ReleaseMutex() } catch { $null = $_ }
            try { $mutex.Dispose() } catch { $null = $_ }
        }
        try {
            $msg = "Invoke-ArcRemediation: run complete (Outcome=$outcomeString, ElapsedMs=$([int]$sw.ElapsedMilliseconds))."
            Write-LocalLog -Message $msg -Directory $LogDirectory
        } catch { $null = $_ }
    }
}

function New-RunResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$Outcome,
        [Parameter()] [AllowNull()] [string]$Detail,
        [Parameter()] [AllowNull()] [hashtable]$Row,
        [Parameter(Mandatory)] [bool]$LogIngestionFailed,
        [Parameter(Mandatory)] [System.Diagnostics.Stopwatch]$Elapsed,
        [Parameter()] [AllowNull()] [string]$ErrorMessage
    )
    $exit = ConvertTo-RemediatorExitCode -Outcome $Outcome -LogIngestionOnlyFailed:$LogIngestionFailed
    return [PSCustomObject]@{
        Outcome = $Outcome
        OutcomeDetail = $Detail
        ExitCode = $exit
        Row = $Row
        LogIngestionFailed = $LogIngestionFailed
        ErrorMessage = $ErrorMessage
        ElapsedMs = [int]$Elapsed.ElapsedMilliseconds
    }
}

function Build-Row {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Thin wrapper around New-RemediatorRow; pure factory.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [datetime]$EventTime,
        [PSObject]$Config,
        [string]$Mode,
        [string]$Outcome,
        [string]$Detail,
        [PSObject]$ResourceState,
        [PSObject]$Connectivity,
        [string]$ResourceGroupName,
        [string]$MachineName,
        [PSObject]$RemediatorState,
        [string[]]$ActionsAttempted,
        [string[]]$ActionsSuccessful,
        [string]$ErrorMessage,
        [System.Diagnostics.Stopwatch]$Sw,
        [PSObject]$ProbeAzcmagentCheck,
        [PSObject]$ProbeServices,
        [PSObject]$ProbeCertificate,
        [PSObject]$ProbeTimeSync,
        [PSObject]$ProbeAgentVersion
    )
    return New-RemediatorRow -EventTimeUtc $EventTime `
        -CloudProfile $Config.CloudProfile -ScriptMode $Mode `
        -Outcome $Outcome -OutcomeDetail $Detail `
        -ResourceState $ResourceState -ConnectivitySettings $Connectivity `
        -SubscriptionId $Config.SubscriptionId -ResourceGroupName $ResourceGroupName -MachineName $MachineName `
        -RunDurationMs ([int]$Sw.ElapsedMilliseconds) `
        -ActionsAttempted $ActionsAttempted -ActionsSuccessful $ActionsSuccessful `
        -ProbeAzcmagentCheck $ProbeAzcmagentCheck -ProbeServices $ProbeServices `
        -ProbeCertificate $ProbeCertificate -ProbeTimeSync $ProbeTimeSync -ProbeAgentVersion $ProbeAgentVersion `
        -RemediatorState $RemediatorState -ErrorMessage $ErrorMessage
}

function Send-RowOrLogFailure {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [PSObject]$Config,
        [hashtable]$Row,
        [PSObject]$MonitorToken,
        [string]$LogDirectory
    )
    if (-not $Config -or -not $Row -or -not $MonitorToken) { return $false }
    try {
        $send = Send-LogAnalytics -LogIngestionEndpoint $Config.LogIngestionEndpoint `
            -DcrImmutableId $Config.DcrImmutableId `
            -StreamName ([string]$Config.StreamName) `
            -AccessToken $MonitorToken.AccessToken `
            -Rows @($Row)
        if (-not $send.Success) {
            Write-LocalLog -Level 'Warn' -Message "LogIngestionFailure: $($send.ErrorMessage)" -Directory $LogDirectory
            return $false
        }
        return $true
    } catch {
        Write-LocalLog -Level 'Warn' -Message "LogIngestionFailure (exception): $($_.Exception.Message)" -Directory $LogDirectory
        return $false
    }
}
