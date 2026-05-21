#Requires -Version 5.1
<#
    .SYNOPSIS
        Idempotent Azure-side setup for the Arc Remediator MVP. Runs the
        12 numbered steps for one cloud profile
        (Commercial or AzureGovernmentDoD) and emits a cloud-specific
        config sample the operator distributes to Arc-enabled servers.

    .DESCRIPTION
        Compose the azure-setup/private helpers (Tiers 1-4) into the
        documented setup flow:

          1. Assert-AzEnvironment - Az context matches cloud profile
          2. Register-RequiredProvider - Arc / DCR / Storage providers
          3. (caller prerequisites) - app reg + RBAC perms (out of scope here)
          4. New-ScopedServicePrincipal x2 - Arc SP + Logs Ingestion SP
          5. Set-ArcRgRoleAssignment - Arc roles on scoped RGs
          6. New-KillSwitchInfra - storage / blob / SAS
          7-8. New-LawAndTable - workspace + ArcRemediation_CL
          9. New-DirectDcr - kind:Direct DCR
          10. New-OptionalDce - only if -UseDataCollectionEndpoint
          11. Set-DcrMetricsPublisher - role on DCR for Logs Ingestion SP
          12. Out-CloudConfigSample - emit config.json sample

        AzureGovernmentDoD always emits a config with ArcGatewayResourceId=null
        and EnableAutomaticAgentUpgrade=$false per the capability flag
        flags; the operator cannot override these in the generated file.

        This script is operator-side, not server-side - it runs from the
        admin's workstation against an authenticated Az session. It does
        not depend on the ArcRemediator module being installed locally.

    .PARAMETER CloudProfile
        'Commercial' or 'AzureGovernmentDoD'. Drives endpoint selection
        and the DoD-only forced overrides.

    .PARAMETER SubscriptionId
        Subscription that will hold the setup resources.

    .PARAMETER Location
        Azure region for the kill-switch storage account, workspace, DCR.

    .PARAMETER InfraResourceGroupName
        Resource group for the setup-managed resources (storage, LAW, DCR).

    .PARAMETER ScopedArcResourceGroupName
        One or more Arc resource groups the SP is allowed to manage.
        These become the role-assignment scopes.

    .PARAMETER StorageAccountName
        Globally unique storage account name (3-24 lowercase chars).

    .PARAMETER WorkspaceName
        Log Analytics workspace name.

    .PARAMETER DcrName
        Data collection rule name.

    .PARAMETER ArcSpDisplayName
        Display name for the Arc remediation SP.

    .PARAMETER LogsSpDisplayName
        Display name for the Logs Ingestion SP.

    .PARAMETER ConfigOutputPath
        Where to write the generated config sample.

    .PARAMETER UseClientSecret
        Lab/canary credential path for both SPs. Default is certificate.

    .PARAMETER UseDataCollectionEndpoint
        Provision a DCE alongside the DCR. Default is direct logsIngestion
        on the DCR.

    .PARAMETER IncludeSqlArc
        Also register Microsoft.AzureArcData for SQL Server enabled by Arc.

    .PARAMETER Mode
        Initial config Mode - 'Observe' (default) or 'Enforce'.

    .PARAMETER DeploymentMode
        Infrastructure deployment strategy. 'Imperative' (default) runs the
        az-setup private helpers directly. 'Bicep' runs
        `az deployment group create` against azure-setup/bicep/main.bicep for
        Storage + LAW + DCE + DCR, then falls through to the imperative path
        for AAD app registration, RBAC, and config-sample steps.

        The Bicep path is opt-in and treated as Phase 1 parity.  Verify with
        `--DeploymentMode Bicep -WhatIf` before running destructively.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Setup-AzureSide.ps1 is a user-facing CLI; per-step progress output to host is intentional and matches the runbook expectation.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Commercial', 'AzureGovernmentDoD')]
    [string]$CloudProfile,

    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter(Mandatory)]
    [string]$InfraResourceGroupName,

    [Parameter(Mandatory)]
    [string[]]$ScopedArcResourceGroupName,

    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [Parameter(Mandatory)]
    [string]$DcrName,

    [Parameter()]
    [string]$ArcSpDisplayName = "sp-arc-remediator-$($CloudProfile.ToLower())",

    [Parameter()]
    [string]$LogsSpDisplayName = "sp-arc-logs-ingestion-$($CloudProfile.ToLower())",

    [Parameter()]
    [string]$ConfigOutputPath,

    [Parameter()]
    [switch]$UseClientSecret,

    [Parameter()]
    [switch]$UseDataCollectionEndpoint,

    [Parameter()]
    [switch]$IncludeSqlArc,

    [Parameter()]
    [ValidateSet('Observe', 'Enforce')]
    [string]$Mode = 'Observe',

    [Parameter()]
    [ValidateSet('Imperative', 'Bicep')]
    [string]$DeploymentMode = 'Imperative'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ---- Dot-source private helpers ----
$private = Join-Path $PSScriptRoot 'private'
foreach ($f in Get-ChildItem -Path $private -Filter '*.ps1' -File) {
    . $f.FullName
}

Write-Host "==> Setup-AzureSide ($CloudProfile, $SubscriptionId, $Location)" -ForegroundColor Cyan

# 1. Az context must match cloud profile.
$null = Assert-AzEnvironment -CloudProfile $CloudProfile
Write-Host " 1/12 Az environment matches '$CloudProfile'." -ForegroundColor Green

# 2. Required resource providers.
Register-RequiredProvider -IncludeSqlArc:$IncludeSqlArc
Write-Host ' 2/12 Required resource providers registered.' -ForegroundColor Green

# 3. Operator prerequisites checked by inviting Azure to fail closed on
# missing perms below; documented in the runbook.
Write-Host ' 3/12 Operator app-reg + role-assign permissions assumed (runbook).' -ForegroundColor DarkGray

# 4. Two scoped service principals: Arc + Logs Ingestion.
$arcSp = New-ScopedServicePrincipal -DisplayName $ArcSpDisplayName -UseClientSecret:$UseClientSecret
$logsSp = New-ScopedServicePrincipal -DisplayName $LogsSpDisplayName -UseClientSecret:$UseClientSecret
Write-Host " 4/12 Service principals: arc=$($arcSp.ApplicationId), logs=$($logsSp.ApplicationId)." -ForegroundColor Green

# 5. Arc RBAC on scoped resource groups.
Set-ArcRgRoleAssignment `
    -ServicePrincipalObjectId $arcSp.ObjectId `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ScopedArcResourceGroupName
Write-Host " 5/12 Arc role assignments applied to $($ScopedArcResourceGroupName.Count) RG(s)." -ForegroundColor Green

# 6-9. Infrastructure resources (Storage + LAW + DCE + DCR).
# Bicep path runs an ARM deployment for these resources; Imperative path
# calls the private helper functions directly.  AAD + RBAC always run
# imperatively (no Graph Bicep extension required).
if ($DeploymentMode -eq 'Bicep') {
    Write-Host ' 6-9/12 DeploymentMode=Bicep: running az deployment group create ...' -ForegroundColor Cyan
    $bicepDir = Join-Path $PSScriptRoot 'bicep'
    $bicepTemplate = Join-Path $bicepDir 'main.bicep'
    if (-not (Test-Path $bicepTemplate)) {
        throw "Bicep template not found at '$bicepTemplate'. Ensure azure-setup/bicep/main.bicep is present."
    }

    $deployName = "arcremediator-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    $azArgs = @(
        'deployment', 'group', 'create',
        '--resource-group', $InfraResourceGroupName,
        '--name', $deployName,
        '--template-file', $bicepTemplate,
        '--parameters', "cloudProfile=$CloudProfile",
        '--parameters', "location=$Location",
        '--parameters', "storageAccountName=$StorageAccountName",
        '--parameters', "workspaceName=$WorkspaceName",
        '--parameters', "dcrName=$DcrName",
        '--parameters', "createDce=$(if ($UseDataCollectionEndpoint) { 'true' } else { 'false' })",
        '--parameters', "dceName=$($DcrName)-dce",
        '--query', 'properties.outputs',
        '--output', 'json'
    )
    if (-not $PSCmdlet.ShouldProcess($InfraResourceGroupName, "az deployment group create ($deployName)")) {
        Write-Host ' (WhatIf: Bicep deployment skipped)' -ForegroundColor DarkGray
        return
    }
    $outputJson = & az @azArgs
    if ($LASTEXITCODE -ne 0) { throw "az deployment group create failed (exit $LASTEXITCODE). Check az CLI output above." }
    $outputs = $outputJson | ConvertFrom-Json

    # Rehydrate the same shape that the imperative helpers produce.
    $killSwitch = [PSCustomObject]@{
        KillSwitchUrl      = $null  # SAS URL must be generated separately via az storage blob generate-sas
        StorageAccountName = $StorageAccountName
        ContainerName      = 'arc-remediator'
    }
    $law = [PSCustomObject]@{
        WorkspaceName      = $WorkspaceName
        WorkspaceResourceId = $outputs.workspaceId.value
    }
    $dcr = [PSCustomObject]@{
        DcrResourceId  = $outputs.dcrId.value
        ImmutableId    = $outputs.dcrImmutableId.value
        StreamName     = $outputs.streamName.value
        LogsIngestion  = $outputs.logsIngestionEndpoint.value
    }
    $dceId       = $outputs.dceId.value
    $dceEndpoint = $outputs.dceLogsIngestionEndpoint.value
    Write-Host ' 6-9/12 Bicep deployment complete.' -ForegroundColor Green
} else {
    # ---- Imperative path (original, default) --------------------------------

    # 6. Kill-switch storage + SAS.
    $killSwitch = New-KillSwitchInfra `
        -ResourceGroupName $InfraResourceGroupName `
        -StorageAccountName $StorageAccountName `
        -Location $Location
    Write-Host " 6/12 Kill-switch blob ready (private container, TLS1_2)." -ForegroundColor Green

    # 7-8. Workspace + custom table.
    $law = New-LawAndTable `
        -ResourceGroupName $InfraResourceGroupName `
        -WorkspaceName $WorkspaceName `
        -Location $Location `
        -SubscriptionId $SubscriptionId
    Write-Host " 7-8/12 Workspace + ArcRemediation_CL ready." -ForegroundColor Green

    # 6b. Blob-write alert (diagnostic setting + SQR) — Detect strategy for R6.
    # Placed after step 7-8 because the LAW workspace ID is required.
    # Best-effort; do not abort the setup if the alert cannot be created.
    try {
        $storageId = (Get-AzStorageAccount -ResourceGroupName $InfraResourceGroupName -Name $StorageAccountName -ErrorAction Stop).Id
        $null = New-BlobWriteAlert `
            -StorageAccountResourceId $storageId `
            -WorkspaceResourceId $law.WorkspaceResourceId `
            -ResourceGroupName $InfraResourceGroupName `
            -Location $Location `
            -SubscriptionId $SubscriptionId
        Write-Host ' 6b/12 Blob-write alert (diagnostic setting + SQR) configured.' -ForegroundColor Green
    } catch {
        Write-Warning "Setup-AzureSide: Blob-write alert setup failed (non-fatal): $($_.Exception.Message)"
        Write-Host ' 6b/12 Blob-write alert skipped (see warning above).' -ForegroundColor Yellow
    }

    # 9. Optional DCE (provisioned BEFORE DCR if requested).
    $dceId = $null
    $dceEndpoint = $null
    if ($UseDataCollectionEndpoint) {
        $dce = New-OptionalDce `
            -ResourceGroupName $InfraResourceGroupName `
            -DceName ($DcrName + '-dce') `
            -Location $Location `
            -SubscriptionId $SubscriptionId
        $dceId = $dce.DceResourceId
        $dceEndpoint = $dce.LogsIngestionUrl
        Write-Host " 10/12 DCE provisioned (-UseDataCollectionEndpoint)." -ForegroundColor Green
    } else {
        Write-Host ' 10/12 DCE skipped (direct logsIngestion on DCR).' -ForegroundColor DarkGray
    }

    # 9. DCR (kind:Direct).
    $dcr = New-DirectDcr `
        -ResourceGroupName $InfraResourceGroupName `
        -DcrName $DcrName `
        -Location $Location `
        -WorkspaceResourceId $law.WorkspaceResourceId `
        -SubscriptionId $SubscriptionId `
        -DataCollectionEndpointId $dceId
    Write-Host " 9/12 DCR ready (kind:Direct, immutableId=$($dcr.ImmutableId))." -ForegroundColor Green
}

# 11. Metrics Publisher on the DCR for the Logs Ingestion SP.
Set-DcrMetricsPublisher `
    -DcrResourceId $dcr.DcrResourceId `
    -LogsIngestionSpObjectId $logsSp.ObjectId
Write-Host ' 11/12 Monitoring Metrics Publisher assigned on DCR.' -ForegroundColor Green

# Endpoint: prefer DCR-embedded over DCE if both exist.
$endpoint = $dcr.LogsIngestion
if (-not $endpoint -and $dceEndpoint) {
    $endpoint = $dceEndpoint
}

# 12. Emit config sample.
$arcCred = [PSCustomObject]@{
    TenantId = $arcSp.TenantId
    ClientId = $arcSp.ApplicationId
    CredentialType = $arcSp.CredentialType
    ClientSecret = $arcSp.ClientSecret
    CertificateThumbprint = $arcSp.CertificateThumbprint
}
$logsCred = [PSCustomObject]@{
    UseArcCredential = $false
    TenantId = $logsSp.TenantId
    ClientId = $logsSp.ApplicationId
    CredentialType = $logsSp.CredentialType
    ClientSecret = $logsSp.ClientSecret
    CertificateThumbprint = $logsSp.CertificateThumbprint
}

$configJson = Out-CloudConfigSample `
    -OutputPath $ConfigOutputPath `
    -CloudProfile $CloudProfile `
    -ArcCredential $arcCred `
    -MonitorCredential $logsCred `
    -SubscriptionId $SubscriptionId `
    -ScopedResourceGroupName $ScopedArcResourceGroupName `
    -LogIngestionEndpoint $endpoint `
    -DcrImmutableId $dcr.ImmutableId `
    -StreamName $dcr.StreamName `
    -KillSwitchUrl $killSwitch.KillSwitchUrl `
    -Mode $Mode

Write-Host " 12/12 Config sample emitted ($(if ($ConfigOutputPath) { $ConfigOutputPath } else { '<stdout>' }))." -ForegroundColor Green
Write-Host '==> Setup complete.' -ForegroundColor Cyan

return [PSCustomObject]@{
    CloudProfile = $CloudProfile
    ArcServicePrincipal = $arcSp
    LogsServicePrincipal = $logsSp
    KillSwitch = $killSwitch
    Workspace = $law
    Dcr = $dcr
    DceResourceId = $dceId
    ConfigJson = $configJson
}
