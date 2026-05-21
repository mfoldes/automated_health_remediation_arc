#Requires -Version 5.1

function New-BlobWriteAlert {
    <#
        .SYNOPSIS
            Create a Storage Account diagnostic setting and a Scheduled Query
            Alert Rule that fires when the kill-switch or breaker-reset blob
            is written to directly via RBAC.

        .DESCRIPTION
            Implements the short-term Detect strategy for STRIDE finding R6.
            Two Azure resources are created:

              1. Diagnostic Setting on the Storage Account's blob service:
                 routes StorageWrite (and StorageRead) logs to the Log
                 Analytics Workspace. The setting is named
                 'ArcRemediator-BlobAudit'.

              2. Scheduled Query Alert Rule (SQR): queries the
                 StorageBlobLogs table for PutBlob / SetBlobContents
                 operations targeting the kill-switch or breaker-reset blob
                 names, and fires a severity-1 alert if any are found in the
                 last evaluation window.

            Both resources are idempotent: running the function again with
            the same parameters updates the existing resources.

        .PARAMETER StorageAccountResourceId
            Full ARM resource ID of the kill-switch Storage Account.

        .PARAMETER WorkspaceResourceId
            Full ARM resource ID of the Log Analytics Workspace.

        .PARAMETER ResourceGroupName
            Resource group where the Scheduled Query Alert Rule is created.

        .PARAMETER Location
            Azure region for the alert rule (must match the workspace region).

        .PARAMETER SubscriptionId
            Subscription ID (used to build the alert rule scope).

        .PARAMETER KillSwitchBlobName
            Name of the kill-switch blob to watch. Defaults to 'kill-switch.txt'.

        .PARAMETER BreakerResetBlobName
            Name of the breaker-reset blob to watch. Defaults to 'breaker-reset.txt'.

        .PARAMETER AlertRuleName
            Name of the Scheduled Query Alert Rule. Defaults to
            'arc-remediator-blob-write-alert'.

        .PARAMETER AlertActionGroupResourceId
            Optional ARM resource ID of an Action Group to notify. If omitted,
            the alert fires but takes no action until an Action Group is
            manually associated.

        .OUTPUTS
            PSCustomObject with:
              DiagnosticSettingName (string)
              AlertRuleName         (string)
              AlertRuleResourceId   (string)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Caller (Setup-AzureSide.ps1) gates this via SupportsShouldProcess.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$StorageAccountResourceId,

        [Parameter(Mandatory)]
        [string]$WorkspaceResourceId,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter()]
        [string]$KillSwitchBlobName = 'kill-switch.txt',

        [Parameter()]
        [string]$BreakerResetBlobName = 'breaker-reset.txt',

        [Parameter()]
        [string]$AlertRuleName = 'arc-remediator-blob-write-alert',

        [Parameter()]
        [string]$AlertActionGroupResourceId
    )

    $diagSettingName = 'ArcRemediator-BlobAudit'

    # ---- 1. Storage Account diagnostic setting (blob service) ----------------
    # The diagnostic setting is created on the blob service sub-resource.
    $blobServiceResourceId = "$StorageAccountResourceId/blobServices/default"

    try {
        Set-AzDiagnosticSetting `
            -ResourceId $blobServiceResourceId `
            -Name $diagSettingName `
            -WorkspaceId $WorkspaceResourceId `
            -EnableLog $true `
            -Category 'StorageWrite', 'StorageRead' `
            -ErrorAction Stop | Out-Null
    } catch {
        # Fallback: use az cli if the Az PowerShell cmdlet is unavailable.
        $azArgs = @(
            'monitor', 'diagnostic-settings', 'create',
            '--resource', $blobServiceResourceId,
            '--name', $diagSettingName,
            '--workspace', $WorkspaceResourceId,
            '--logs', '[{"category":"StorageWrite","enabled":true},{"category":"StorageRead","enabled":true}]'
        )
        & az @azArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "New-BlobWriteAlert: failed to create diagnostic setting. Check az cli output."
        }
    }

    # ---- 2. Scheduled Query Alert Rule ----------------------------------------
    # KQL: alert on any PutBlob or SetBlobProperties to the monitored blob names.
    $kql = @"
StorageBlobLogs
| where OperationName in ('PutBlob', 'SetBlobProperties', 'PutBlockList')
| where ObjectKey has '$KillSwitchBlobName' or ObjectKey has '$BreakerResetBlobName'
| project TimeGenerated, OperationName, CallerIpAddress, AuthenticationType, ObjectKey, StatusCode
"@

    try {
        $criteria = New-AzScheduledQueryRuleCriteria `
            -Query $kql `
            -TimeAggregation 'Count' `
            -Operator 'GreaterThan' `
            -Threshold 0 `
            -FailingPeriodNumberOfEvaluationPeriods 1 `
            -FailingPeriodMinFailingPeriodsToAlert 1

        $actionGroupIds = @()
        if ($AlertActionGroupResourceId) {
            $actionGroupIds = @($AlertActionGroupResourceId)
        }

        $rule = New-AzScheduledQueryRule `
            -ResourceGroupName $ResourceGroupName `
            -Name $AlertRuleName `
            -Location $Location `
            -DisplayName 'ArcRemediator: Kill-Switch or Breaker-Reset Blob Written' `
            -Description "Fires when a PutBlob or equivalent operation targets the kill-switch ('$KillSwitchBlobName') or breaker-reset ('$BreakerResetBlobName') blob. Investigate immediately — direct RBAC write bypasses the SAS read-only restriction." `
            -Scope @($WorkspaceResourceId) `
            -Severity 1 `
            -Enabled $true `
            -EvaluationFrequency 'PT5M' `
            -WindowSize 'PT10M' `
            -CriterionAllOf $criteria `
            -ActionGroupResourceId $actionGroupIds `
            -SkipQueryValidation `
            -ErrorAction Stop

        $alertRuleId = $rule.Id
    } catch {
        # Fallback: use az cli.
        $azArgs = @(
            'monitor', 'scheduled-query', 'create',
            '--name', $AlertRuleName,
            '--resource-group', $ResourceGroupName,
            '--location', $Location,
            '--description', "ArcRemediator blob write alert for $KillSwitchBlobName and $BreakerResetBlobName",
            '--scopes', $WorkspaceResourceId,
            '--condition', "count ''$kql'' > 0",
            '--evaluation-frequency', '5m',
            '--window-size', '10m',
            '--severity', '1',
            '--condition-query', $kql
        )
        & az @azArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "New-BlobWriteAlert: az scheduled-query create returned exit code $LASTEXITCODE. Verify alert rule manually."
        }
        $alertRuleId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/scheduledQueryRules/$AlertRuleName"
    }

    return [PSCustomObject]@{
        DiagnosticSettingName = $diagSettingName
        AlertRuleName         = $AlertRuleName
        AlertRuleResourceId   = $alertRuleId
    }
}
