#Requires -Version 5.1
<#
    .SYNOPSIS
        Build a release ZIP for the ArcRemediator module.

    .DESCRIPTION
         the build artifact is a self-contained ZIP an
        operator copies to a target host (or to a software-distribution
        share) before running Bootstrap\Install.ps1.

        Layout produced inside the ZIP:

          arc-remediator-<version>.zip
          |- ArcRemediator/ <- module
          | |- ArcRemediator.psd1
          | |- ArcRemediator.psm1
          | |- Bootstrap/
          | | |- Install.ps1
          | | |- Uninstall.ps1
          | | |- Invoke-RemediatorTask.ps1
          | | '- Test-ArcInstallation.ps1
          | |- Private/...
          | |- Public/...
          | '- Data/
          | |- cloud-profiles.psd1
          | '- version.txt
          |- azure-setup/ <- operator workstation only
          | |- Setup-AzureSide.ps1
          | '- private/...
          |- samples/
          | |- config.commercial.sample.json
          | '- config.usgovdod.sample.json
          '- README.md

        The build does NOT include the tests/ tree or the docs/ tree --
        those stay in source control.

        Version comes from Data/version.txt (a single line). The output
        filename embeds the version so multiple builds can coexist in
        package/dist/.

        The script is intended to be re-runnable: it cleans the staging
        directory each time and overwrites any existing ZIP at the same
        path.

    .PARAMETER OutputDirectory
        Where to write the ZIP. Default: package/dist next to this file.

    .PARAMETER Version
        Override the version. Default: read from
        src/ArcRemediator/Data/version.txt.

    .PARAMETER IncludeAzureSetup
        Include azure-setup/ in the ZIP (default $true). Set $false
        for per-host packages where only the module + samples are
        needed.

    .OUTPUTS
        PSCustomObject with the ZIP path, computed version, and the
        list of files staged.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()] [string]$OutputDirectory,
    [Parameter()] [string]$Version,
    [Parameter()] [bool]$IncludeAzureSetup = $true
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ---- Helpers (declared before main flow uses them) ---------------------

function Write-SampleConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Caller gates writes via SupportsShouldProcess.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [ValidateSet('Commercial', 'AzureGovernmentDoD')] [string]$CloudProfile
    )
    $obj = [ordered]@{
        CloudProfile = $CloudProfile
        ArcCredential = [ordered]@{
            TenantId = '00000000-0000-0000-0000-000000000000'
            ClientId = '00000000-0000-0000-0000-000000000000'
            CredentialType = 'Certificate'
            ClientSecret = $null
            CertificateThumbprint = '0000000000000000000000000000000000000000'
        }
        MonitorCredential = [ordered]@{
            UseArcCredential = $false
            TenantId = '00000000-0000-0000-0000-000000000000'
            ClientId = '00000000-0000-0000-0000-000000000000'
            CredentialType = 'Certificate'
            ClientSecret = $null
            CertificateThumbprint = '0000000000000000000000000000000000000000'
        }
        SubscriptionId = '00000000-0000-0000-0000-000000000000'
        ScopedResourceGroups = @('rg-arc-prod-1', 'rg-arc-prod-2')
        LogIngestionEndpoint = if ($CloudProfile -eq 'AzureGovernmentDoD') { 'https://<dce-or-dcr>.<region>.ingest.monitor.azure.us' } else { 'https://<dce-or-dcr>.<region>.ingest.monitor.azure.com' }
        DcrImmutableId = 'dcr-...'
        StreamName = 'Custom-ArcRemediation'
        KillSwitchUrl = if ($CloudProfile -eq 'AzureGovernmentDoD') { 'https://<storage>.blob.core.usgovcloudapi.net/arc-remediator/kill-switch.txt?<sas>' } else { 'https://<storage>.blob.core.windows.net/arc-remediator/kill-switch.txt?<sas>' }
        PrivateLinkScopeResourceId = $null
        ArcGatewayResourceId = $null
        ProxyUrl = $null
        EnableAutomaticAgentUpgrade = $false
        CircuitBreakerFailureThreshold = 3
        Mode = 'Observe'
        Version = '1.0.0'
    }
    ($obj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-PackageReadme {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Caller gates writes via SupportsShouldProcess.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Version
    )
    $text = @"
# ArcRemediator $Version

Per-server remediator for Azure Arc-enabled Windows servers (Commercial + AzureGovernmentDoD).

## Layout

- ArcRemediator\ - the PowerShell 5.1 module.
- ArcRemediator\Bootstrap\Install.ps1 - install on the target host.
- ArcRemediator\Bootstrap\Uninstall.ps1 - remove the task + install path.
- azure-setup\ - operator-side. Run once per cloud from the
                         operator's workstation to provision the
                         shared infra.
- samples\ - starting-point config files. Fill in tenant,
                         subscription, RG, SP credentials, kill-switch
                         SAS URL, log ingestion endpoint, and DCR
                         immutable ID before passing to Install.ps1.

## Install (target host, elevated)

```powershell
# 1. Copy this package somewhere local.
# 2. Edit samples\config.commercial.sample.json (or usgovdod).
# 3. .\ArcRemediator\Bootstrap\Install.ps1 -ConfigJsonPath .\samples\config.commercial.sample.json
```

## Active validation

```powershell
. 'C:\Program Files\ArcRemediator\Bootstrap\Test-ArcInstallation.ps1'
Test-ArcInstallation
```

## Uninstall

```powershell
.\ArcRemediator\Bootstrap\Uninstall.ps1
```

Preserves %ProgramData%\ArcRemediator (logs + state + cooldown marker)
by default. Add -RemoveData to wipe it.
"@
    Set-Content -LiteralPath $Path -Value $text -Encoding UTF8
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $PSScriptRoot 'dist'
}
$sourceModule = Join-Path $repoRoot 'src\ArcRemediator'
if (-not (Test-Path -LiteralPath $sourceModule)) {
    throw "build.ps1: source module not found at '$sourceModule'."
}

if (-not $Version) {
    $verFile = Join-Path $sourceModule 'Data\version.txt'
    if (-not (Test-Path -LiteralPath $verFile)) {
        throw "build.ps1: version.txt not found at '$verFile'."
    }
    $Version = (Get-Content -LiteralPath $verFile -Raw).Trim()
    if (-not $Version) {
        throw "build.ps1: version.txt is empty."
    }
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$stage = Join-Path $OutputDirectory ("stage-" + [guid]::NewGuid().ToString('N'))
New-Item -Path $stage -ItemType Directory -Force | Out-Null

$stagedFiles = New-Object System.Collections.Generic.List[string]

try {
    # ---- 1. Module --------------------------------------------------
    $destModule = Join-Path $stage 'ArcRemediator'
    if ($PSCmdlet.ShouldProcess($destModule, 'Stage module')) {
        Copy-Item -LiteralPath $sourceModule -Destination $destModule -Recurse -Force
    }
    Get-ChildItem -LiteralPath $destModule -Recurse -File | ForEach-Object {
        $stagedFiles.Add($_.FullName.Substring($stage.Length + 1)) | Out-Null
    }

    # ---- 2. azure-setup (operator workstation) ----------------------
    if ($IncludeAzureSetup) {
        $azSetupSrc = Join-Path $repoRoot 'azure-setup'
        if (Test-Path -LiteralPath $azSetupSrc) {
            $azSetupDest = Join-Path $stage 'azure-setup'
            if ($PSCmdlet.ShouldProcess($azSetupDest, 'Stage azure-setup')) {
                # Stage everything except the tests/ subdirectory.
                Copy-Item -LiteralPath $azSetupSrc -Destination $azSetupDest -Recurse -Force
                $testsDir = Join-Path $azSetupDest 'tests'
                if (Test-Path -LiteralPath $testsDir) {
                    Remove-Item -LiteralPath $testsDir -Recurse -Force
                }
            }
            Get-ChildItem -LiteralPath $azSetupDest -Recurse -File | ForEach-Object {
                $stagedFiles.Add($_.FullName.Substring($stage.Length + 1)) | Out-Null
            }
        }
    }

    # ---- 3. Cloud-specific config samples ---------------------------
    $samplesDir = Join-Path $stage 'samples'
    New-Item -Path $samplesDir -ItemType Directory -Force | Out-Null
    if ($PSCmdlet.ShouldProcess($samplesDir, 'Stage cloud config samples')) {
        Write-SampleConfig -Path (Join-Path $samplesDir 'config.commercial.sample.json') -CloudProfile 'Commercial'
        Write-SampleConfig -Path (Join-Path $samplesDir 'config.usgovdod.sample.json') -CloudProfile 'AzureGovernmentDoD'
    }
    $stagedFiles.Add('samples\config.commercial.sample.json') | Out-Null
    $stagedFiles.Add('samples\config.usgovdod.sample.json') | Out-Null

    # ---- 4. README ---------------------------------------------------
    $readme = Join-Path $stage 'README.md'
    if ($PSCmdlet.ShouldProcess($readme, 'Stage README')) {
        Write-PackageReadme -Path $readme -Version $Version
    }
    $stagedFiles.Add('README.md') | Out-Null

    # ---- 5. ZIP it up ------------------------------------------------
    $zipPath = Join-Path $OutputDirectory ("arc-remediator-$Version.zip")
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    if ($PSCmdlet.ShouldProcess($zipPath, 'Compress release archive')) {
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -Force
    }

    return [PSCustomObject]@{
        ZipPath = $zipPath
        Version = $Version
        StagedFiles = @($stagedFiles.ToArray())
        SizeBytes = (Get-Item -LiteralPath $zipPath).Length
    }
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

