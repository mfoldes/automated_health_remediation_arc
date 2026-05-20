#Requires -Version 5.1

function Test-ArcInstallation {
    <#
        .SYNOPSIS
            Probe a freshly installed ArcRemediator end-to-end without
            making any cloud-side changes.

        .DESCRIPTION
            Used either by Install.ps1 -Validate or interactively after
            install. It walks the five things that can go wrong between
            "the install ran" and "the first scheduled run will succeed":

              1. The DPAPI-wrapped config decrypts and parses, and the
                 cloud profile it names is recognized.
              2. An ARM access token can be acquired with the configured
                 service principal.
              3. A Monitor access token can be acquired (separately, with
                 either the ARM credential or the dedicated Monitor one).
              4. The kill-switch SAS URL is reachable AND the blob body
                 is exactly the literal word "enabled".
              5. A sample row POSTs successfully to the Logs Ingestion
                 endpoint configured for the DCR.

            Each step returns Passed + a one-line Detail. The aggregate
            AllPassed is true only when every step passed. The probe is
            non-mutating from the cloud's perspective: tokens are
            read-only, the kill-switch read is a GET, and the sample
            row is tagged OutcomeDetail='Test-ArcInstallation probe' so
            operators can filter it out of production telemetry.

        .PARAMETER ConfigPath
            Path to the DPAPI-wrapped config file.
            Defaults to %ProgramData%\ArcRemediator\config.json.

        .PARAMETER ModulePath
            Path to the module manifest to import.
            Defaults to %ProgramFiles%\ArcRemediator\ArcRemediator.psd1,
            the location Install.ps1 writes to.

        .PARAMETER SkipLogIngestion
            Skip step 5 (the sample LAW POST). Useful in air-gapped
            lab setups where Monitor is unreachable but the rest of
            the stack still needs to be validated.

        .OUTPUTS
            A PSCustomObject with one entry per step:
              CloudProfile  { Passed, Detail }
              ArmToken      { Passed, Detail }
              MonitorToken  { Passed, Detail }
              KillSwitch    { Passed, Detail }
              LogIngestion  { Passed, Detail }
            plus an aggregate AllPassed boolean.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()] [string]$ConfigPath = (Join-Path $env:ProgramData 'ArcRemediator\config.json'),
        [Parameter()] [string]$ModulePath = (Join-Path $env:ProgramFiles 'ArcRemediator\ArcRemediator.psd1'),
        [Parameter()] [switch]$SkipLogIngestion
    )

    if (-not (Test-Path -LiteralPath $ModulePath)) {
        throw "Test-ArcInstallation: module manifest not found at '$ModulePath'."
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Test-ArcInstallation: DPAPI-wrapped config not found at '$ConfigPath'."
    }

    Import-Module $ModulePath -Force -ErrorAction Stop | Out-Null

    $result = [ordered]@{
        CloudProfile = [ordered]@{ Passed = $false; Detail = $null }
        ArmToken = [ordered]@{ Passed = $false; Detail = $null }
        MonitorToken = [ordered]@{ Passed = $false; Detail = $null }
        KillSwitch = [ordered]@{ Passed = $false; Detail = $null }
        LogIngestion = [ordered]@{ Passed = $false; Detail = $null }
        AllPassed = $false
    }

    $cfg = $null
    try {
        $cfg = & (Get-Module ArcRemediator | Select-Object -First 1) {
            param($Path) Get-DecryptedConfig -Path $Path
        } $ConfigPath
    } catch {
        $result.CloudProfile.Detail = "Get-DecryptedConfig failed: $($_.Exception.Message)"
        return [PSCustomObject]$result
    }

    # ---- 1. Cloud profile ------------------------------------------------
    $cloudProfile = $null
    try {
        $cloudProfile = & (Get-Module ArcRemediator | Select-Object -First 1) {
            param($name) Get-CloudProfile -Name $name
        } $cfg.CloudProfile
        $result.CloudProfile.Passed = $true
        $result.CloudProfile.Detail = "Cloud profile '$($cfg.CloudProfile)' loaded; ArmEndpoint=$($cloudProfile.ArmEndpoint)"
    } catch {
        $result.CloudProfile.Detail = "Get-CloudProfile failed: $($_.Exception.Message)"
        return [PSCustomObject]$result
    }

    # ---- 2. ARM token ---------------------------------------------------
    $armToken = $null
    try {
        $armToken = & (Get-Module ArcRemediator | Select-Object -First 1) {
            param($p, $c) Get-AzureToken -CloudProfile $p -Credential $c -Purpose 'Arc'
        } $cloudProfile $cfg.ArcCredential
        $result.ArmToken.Passed = $true
        $result.ArmToken.Detail = "ARM token acquired (expires $($armToken.ExpiresOnUtc.ToString('o')))."
    } catch {
        $result.ArmToken.Detail = "Get-AzureToken -Purpose Arc failed: $($_.Exception.Message)"
    }

    # ---- 3. Monitor token ----------------------------------------------
    $monitorCred = if ([bool]$cfg.MonitorCredential.UseArcCredential) { $cfg.ArcCredential } else { $cfg.MonitorCredential }
    $monitorToken = $null
    try {
        $monitorToken = & (Get-Module ArcRemediator | Select-Object -First 1) {
            param($p, $c) Get-AzureToken -CloudProfile $p -Credential $c -Purpose 'Monitor'
        } $cloudProfile $monitorCred
        $result.MonitorToken.Passed = $true
        $result.MonitorToken.Detail = "Monitor token acquired (expires $($monitorToken.ExpiresOnUtc.ToString('o')))."
    } catch {
        $result.MonitorToken.Detail = "Get-AzureToken -Purpose Monitor failed: $($_.Exception.Message)"
    }

    # ---- 4. Kill switch -------------------------------------------------
    try {
        $kill = & (Get-Module ArcRemediator | Select-Object -First 1) {
            param($u) Get-KillSwitchState -KillSwitchUrl $u
        } $cfg.KillSwitchUrl
        if ($kill.CanProceed) {
            $result.KillSwitch.Passed = $true
            $result.KillSwitch.Detail = "Kill switch returned exact 'enabled'."
        } else {
            $result.KillSwitch.Detail = "Kill switch did not unlock (Reason=$($kill.Reason); LastError=$($kill.LastError))."
        }
    } catch {
        $result.KillSwitch.Detail = "Get-KillSwitchState threw: $($_.Exception.Message)"
    }

    # ---- 5. Sample LAW POST --------------------------------------------
    if ($SkipLogIngestion) {
        $result.LogIngestion.Passed = $true
        $result.LogIngestion.Detail = 'Skipped (operator passed -SkipLogIngestion).'
    } elseif (-not $monitorToken) {
        $result.LogIngestion.Detail = 'Skipped: Monitor token not acquired.'
    } else {
        try {
            $probeRow = @{
                EventTimeUtc = (Get-Date).ToUniversalTime().ToString('o')
                Hostname = $env:COMPUTERNAME
                CloudProfile = $cfg.CloudProfile
                SubscriptionId = $cfg.SubscriptionId
                ScriptMode = 'Observe'
                ScriptVersion = '0.0.0-validation'
                Outcome = 'Healthy'
                OutcomeDetail = 'Test-ArcInstallation probe'
                RunDurationMs = 0
            }
            $send = & (Get-Module ArcRemediator | Select-Object -First 1) {
                param($ep, $dcr, $sn, $tok, $rows) Send-LogAnalytics -LogIngestionEndpoint $ep -DcrImmutableId $dcr -StreamName $sn -AccessToken $tok -Rows $rows
            } $cfg.LogIngestionEndpoint $cfg.DcrImmutableId ([string]$cfg.StreamName) $monitorToken.AccessToken @($probeRow)
            if ($send.Success) {
                $result.LogIngestion.Passed = $true
                $result.LogIngestion.Detail = "Sample row accepted (status=$($send.StatusCode))."
            } else {
                $result.LogIngestion.Detail = "Send-LogAnalytics failed (status=$($send.StatusCode), error=$($send.ErrorMessage))."
            }
        } catch {
            $result.LogIngestion.Detail = "Send-LogAnalytics threw: $($_.Exception.Message)"
        }
    }

    $result.AllPassed = ($result.CloudProfile.Passed -and $result.ArmToken.Passed -and $result.MonitorToken.Passed -and $result.KillSwitch.Passed -and $result.LogIngestion.Passed)
    return [PSCustomObject]$result
}
