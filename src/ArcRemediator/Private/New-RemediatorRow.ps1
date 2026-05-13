#Requires -Version 5.1

function New-RemediatorRow {
    <#
        .SYNOPSIS
            Build one ArcRemediation_CL telemetry row. Pure factory; never throws.

        .DESCRIPTION
            The remediator's scheduled run emits exactly one row to the
            Logs Ingestion API per execution (best-effort). Task 16 acceptance:

              * Region is the actual resource/agent region, not the
                agent version string (a real bug from earlier internal
                tooling - worth a regression test).
              * AzureResourceId is populated when known.
              * ResourceGroup is the actual RG when known.
              * FQDN lookup is best-effort and cannot crash the run.
              * Error messages are truncated to a fixed budget so a long
                stack trace cannot blow the row size limit; the full
                trace stays in the local log and only its SHA-256 hash
                is sent to LAW for correlation.

            The function is a pure factory. All input is passed as
            parameters; no global state is consulted. EventTimeUtc
            defaults to UtcNow but the orchestrator typically passes the
            start-of-run timestamp.

        .PARAMETER EventTimeUtc
            Script start timestamp. The DCR transformKql projects this
            into TimeGenerated.

        .PARAMETER CloudProfile
            'Commercial' or 'AzureGovernmentDoD'.

        .PARAMETER ScriptMode
            'Observe' or 'Enforce'.

        .PARAMETER Outcome
            One of the documented outcome strings.

        .PARAMETER OutcomeDetail
            One-line detail; truncated to MaxDetailChars.

        .PARAMETER ResourceState
            Output of Get-AzureResourceState. Optional; when present we
            pull AzureSideState, AzureResourceId, ResourceGroup, Region.

        .PARAMETER ConnectivitySettings
            Output of Get-ArcConnectivitySettings. Optional; used as
            fallback for resource identifiers and for AgentReportedState.

        .PARAMETER SubscriptionId
            Subscription from config (authoritative).

        .PARAMETER ResourceGroupName
            Fallback when ResourceState is null.

        .PARAMETER MachineName
            Fallback when ResourceState is null.

        .PARAMETER RunDurationMs
            Total wall-clock duration in milliseconds.

        .PARAMETER ActionsAttempted
            Array of action names attempted this run.

        .PARAMETER ActionsSuccessful
            Subset of ActionsAttempted that succeeded.

        .PARAMETER ProbeAzcmagentCheck / ProbeServices / ProbeCertificate / ProbeTimeSync / ProbeAgentVersion
            Probe result objects. Each may be $null.

        .PARAMETER RemediatorState
            Output of Get-RemediatorState (post-run). Used to populate
            ConsecutiveFailures, BreakerTripped, LastRemediationUtc,
            ResetByUser.

        .PARAMETER ErrorMessage
            Exception message. Truncated to MaxErrorChars.

        .PARAMETER ErrorType
            Categorical error label (e.g. 'AuthFailure', 'ArmForbidden').

        .PARAMETER StackTrace
            Full local stack trace. Only its SHA-256 hash is sent to
            LAW; the full string stays in the local log.

        .PARAMETER ScriptVersion
            Remediator version string. Defaults to Get-ScriptVersion.

        .PARAMETER MaxDetailChars
            Truncation budget for OutcomeDetail. Default 500.

        .PARAMETER MaxErrorChars
            Truncation budget for ErrorMessage. Default 1000.

        .OUTPUTS
            [hashtable] - ordered keys matching the ArcRemediation_CL
            column list. Serializable directly via ConvertTo-Json -Depth 10.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory: returns a hashtable. Performs no state change.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [datetime]$EventTimeUtc,
        [Parameter(Mandatory)] [ValidateSet('Commercial', 'AzureGovernmentDoD')] [string]$CloudProfile,
        [Parameter(Mandatory)] [ValidateSet('Observe', 'Enforce')] [string]$ScriptMode,
        [Parameter(Mandatory)] [string]$Outcome,
        [Parameter()] [string]$OutcomeDetail,
        [Parameter()] [PSObject]$ResourceState,
        [Parameter()] [PSObject]$ConnectivitySettings,
        [Parameter()] [string]$SubscriptionId,
        [Parameter()] [string]$ResourceGroupName,
        [Parameter()] [string]$MachineName,
        [Parameter()] [int]$RunDurationMs = 0,
        [Parameter()] [string[]]$ActionsAttempted = @(),
        [Parameter()] [string[]]$ActionsSuccessful = @(),
        [Parameter()] [PSObject]$ProbeAzcmagentCheck,
        [Parameter()] [PSObject]$ProbeServices,
        [Parameter()] [PSObject]$ProbeCertificate,
        [Parameter()] [PSObject]$ProbeTimeSync,
        [Parameter()] [PSObject]$ProbeAgentVersion,
        [Parameter()] [PSObject]$RemediatorState,
        [Parameter()] [string]$ErrorMessage,
        [Parameter()] [string]$ErrorType,
        [Parameter()] [string]$LocalStackTrace,
        [Parameter()] [string]$ScriptVersion,
        [Parameter()] [int]$MaxDetailChars = 500,
        [Parameter()] [int]$MaxErrorChars = 1000
    )

    if (-not $ScriptVersion) {
        try { $ScriptVersion = Get-ScriptVersion } catch { $ScriptVersion = '0.0.0'; $null = $_ }
    }

    $hostname = [string]$env:COMPUTERNAME
    $fqdn = $hostname
    try {
        # Best-effort. this lookup cannot crash the run.
        $info = [System.Net.Dns]::GetHostEntry($hostname)
        if ($info -and $info.HostName) { $fqdn = $info.HostName }
    } catch {
        $null = $_
    }

    $azureSideState = $null
    $azureResourceId = $null
    $region = $null
    $effectiveRG = $ResourceGroupName

    if ($ResourceState) {
        if ($ResourceState.PSObject.Properties.Name -contains 'Classification') {
            $azureSideState = [string]$ResourceState.Classification
        }
        if ($ResourceState.PSObject.Properties.Name -contains 'Location' -and $ResourceState.Location) {
            $region = [string]$ResourceState.Location
        }
        if ($ResourceState.PSObject.Properties.Name -contains 'Raw' -and $ResourceState.Raw) {
            $raw = $ResourceState.Raw
            if ($raw.PSObject.Properties.Name -contains 'id' -and $raw.id) {
                $azureResourceId = [string]$raw.id
            }
        }
    }

    if (-not $region -and $ConnectivitySettings -and ($ConnectivitySettings.PSObject.Properties.Name -contains 'Location') -and $ConnectivitySettings.Location) {
        $region = [string]$ConnectivitySettings.Location
    }
    if (-not $effectiveRG -and $ConnectivitySettings -and ($ConnectivitySettings.PSObject.Properties.Name -contains 'ResourceGroupName') -and $ConnectivitySettings.ResourceGroupName) {
        $effectiveRG = [string]$ConnectivitySettings.ResourceGroupName
    }
    if (-not $azureResourceId -and $SubscriptionId -and $effectiveRG -and $MachineName) {
        $azureResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$effectiveRG/providers/Microsoft.HybridCompute/machines/$MachineName"
    }

    $agentVersion = $null
    $agentReportedState = $null
    if ($ConnectivitySettings) {
        if ($ConnectivitySettings.PSObject.Properties.Name -contains 'AgentVersion') {
            $agentVersion = [string]$ConnectivitySettings.AgentVersion
        }
        if ($ConnectivitySettings.PSObject.Properties.Name -contains 'AgentStatus') {
            $agentReportedState = [string]$ConnectivitySettings.AgentStatus
        }
    }

    $consecutiveFailures = 0
    $breakerTripped = $false
    $lastRemediationUtc = $null
    $resetByUser = $null
    if ($RemediatorState) {
        if ($RemediatorState.PSObject.Properties.Name -contains 'ConsecutiveFailures' -and $null -ne $RemediatorState.ConsecutiveFailures) {
            $consecutiveFailures = [int]$RemediatorState.ConsecutiveFailures
        }
        if ($RemediatorState.PSObject.Properties.Name -contains 'BreakerTripped') {
            $breakerTripped = [bool]$RemediatorState.BreakerTripped
        }
        if ($RemediatorState.PSObject.Properties.Name -contains 'LastSuccessfulRunUtc') {
            $lastRemediationUtc = $RemediatorState.LastSuccessfulRunUtc
        }
        if ($RemediatorState.PSObject.Properties.Name -contains 'ResetByUser') {
            $resetByUser = $RemediatorState.ResetByUser
        }
    }

    $truncatedDetail = ConvertTo-TruncatedString -Value $OutcomeDetail -Max $MaxDetailChars
    $truncatedError = ConvertTo-TruncatedString -Value $ErrorMessage -Max $MaxErrorChars
    $stackTraceHash = if ([string]::IsNullOrEmpty($LocalStackTrace)) { $null } else { ConvertTo-Sha256Hex -Value $LocalStackTrace }

    return [ordered]@{
        EventTimeUtc = $EventTimeUtc.ToUniversalTime().ToString('o')
        Hostname = $hostname
        Fqdn = $fqdn
        CloudProfile = $CloudProfile
        SubscriptionId = $SubscriptionId
        ResourceGroup = $effectiveRG
        Region = $region
        AzureResourceId = $azureResourceId
        AgentVersion = $agentVersion
        ScriptVersion = $ScriptVersion
        ScriptMode = $ScriptMode
        RunDurationMs = $RunDurationMs
        Outcome = $Outcome
        OutcomeDetail = $truncatedDetail
        AzureSideState = $azureSideState
        AgentReportedState = $agentReportedState
        ActionsAttempted = @($ActionsAttempted)
        ActionsSuccessful = @($ActionsSuccessful)
        ProbeAzcmagentCheck = $ProbeAzcmagentCheck
        ProbeServices = $ProbeServices
        ProbeCertificate = $ProbeCertificate
        ProbeTimeSync = $ProbeTimeSync
        ProbeAgentVersion = $ProbeAgentVersion
        ConsecutiveFailures = $consecutiveFailures
        BreakerTripped = $breakerTripped
        LastRemediationUtc = $lastRemediationUtc
        ErrorMessage = $truncatedError
        ErrorType = $ErrorType
        StackTraceHash = $stackTraceHash
        ResetByUser = $resetByUser
    }
}

function ConvertTo-TruncatedString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()] [AllowNull()] [string]$Value,
        [Parameter(Mandatory)] [int]$Max
    )
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value.Length -le $Max) { return $Value }
    if ($Max -le 12) { return $Value.Substring(0, $Max) }
    return $Value.Substring(0, $Max - 12) + '...[truncated]'
}

function ConvertTo-Sha256Hex {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}
