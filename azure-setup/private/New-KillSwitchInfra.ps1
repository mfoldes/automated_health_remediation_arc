#Requires -Version 5.1

function New-KillSwitchInfra {
    <#
        .SYNOPSIS
            Create or reuse the kill-switch storage account, private container,
            content blob, stored access policy, and Service SAS that the
            remediator reads before Azure auth.

        .DESCRIPTION
             Setup-AzureSide.ps1 must provision a
            small Storage Account with:

              * Private container (no public access).
              * Blob containing the literal text 'enabled' (or 'paused').
              * Stored access policy granting read-only.
              * Service SAS backed by that policy, included in the generated
                config as KillSwitchUrl.

            The remediator reads the blob before any Azure auth call. Anything
            other than exact 'enabled' (including unreachable, 'paused', or
            anything else) pauses the run - this is the fleet kill switch
            documented below.

            The function is idempotent: existing storage account, container,
            blob, and access policy are all reused when present.

            Storage account creation enforces MinimumTlsVersion=TLS1_2 (per
            the design - TLS 1.2 in effect since 2026-03-01) and
            AllowBlobPublicAccess=$false (the container must NOT be public;
            access goes through the SAS only).

        .PARAMETER ResourceGroupName
            Resource group that contains (or will contain) the storage account.

        .PARAMETER StorageAccountName
            Storage account name. Must be globally unique, 3-24 lowercase
            alphanumeric chars per Azure rules.

        .PARAMETER Location
            Azure region for the storage account.

        .PARAMETER ContainerName
            Container name. Defaults to 'arc-remediator'.

        .PARAMETER BlobName
            Blob name. Defaults to 'kill-switch.txt'.

        .PARAMETER BlobContent
            Initial blob content. Defaults to 'enabled' so the fleet starts
            allowed. Operators flip to 'paused' to halt the fleet.

        .PARAMETER AccessPolicyName
            Stored access policy name. Defaults to 'arc-remediator-readonly'.

        .PARAMETER AccessPolicyValidityDays
            Policy expiry in days. Defaults to 365.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$StorageAccountName,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter()]
        [string]$ContainerName = 'arc-remediator',

        [Parameter()]
        [string]$BlobName = 'kill-switch.txt',

        [Parameter()]
        [string]$BlobContent = 'enabled',

        [Parameter()]
        [string]$AccessPolicyName = 'arc-remediator-readonly',

        [Parameter()]
        [int]$AccessPolicyValidityDays = 365
    )

    # ---- Storage account ----
    $sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue
    if (-not $sa) {
        if (-not $PSCmdlet.ShouldProcess($StorageAccountName, 'New-AzStorageAccount')) {
            return
        }
        $sa = New-AzStorageAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name $StorageAccountName `
            -Location $Location `
            -SkuName 'Standard_LRS' `
            -Kind 'StorageV2' `
            -MinimumTlsVersion 'TLS1_2' `
            -AllowBlobPublicAccess $false `
            -ErrorAction Stop
    }

    $ctx = $sa.Context

    # ---- Private container ----
    $container = Get-AzStorageContainer -Name $ContainerName -Context $ctx -ErrorAction SilentlyContinue
    if (-not $container) {
        if (-not $PSCmdlet.ShouldProcess($ContainerName, 'New-AzStorageContainer -Permission Off')) {
            return
        }
        $null = New-AzStorageContainer -Name $ContainerName -Context $ctx -Permission Off -ErrorAction Stop
    }

    # ---- Kill switch blob (only created on first run; do NOT overwrite existing content) ----
    $blob = Get-AzStorageBlob -Container $ContainerName -Blob $BlobName -Context $ctx -ErrorAction SilentlyContinue
    if (-not $blob) {
        if ($PSCmdlet.ShouldProcess($BlobName, "Set-AzStorageBlobContent (initial='$BlobContent')")) {
            $temp = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -LiteralPath $temp -Value $BlobContent -NoNewline -Encoding ASCII
                $null = Set-AzStorageBlobContent `
                    -File $temp `
                    -Container $ContainerName `
                    -Blob $BlobName `
                    -Context $ctx `
                    -ErrorAction Stop
            } finally {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # ---- Stored access policy ----
    $existingPolicies = @(Get-AzStorageContainerStoredAccessPolicy -Container $ContainerName -Context $ctx -ErrorAction SilentlyContinue)
    $hasPolicy = $existingPolicies | Where-Object { $_.Policy -eq $AccessPolicyName }
    if (-not $hasPolicy) {
        if ($PSCmdlet.ShouldProcess($AccessPolicyName, "New-AzStorageContainerStoredAccessPolicy (r, $AccessPolicyValidityDays days)")) {
            $expiry = (Get-Date).AddDays($AccessPolicyValidityDays)
            $null = New-AzStorageContainerStoredAccessPolicy `
                -Container $ContainerName `
                -Context $ctx `
                -Policy $AccessPolicyName `
                -Permission 'r' `
                -ExpiryTime $expiry `
                -ErrorAction Stop
        }
    }

    # ---- Service SAS backed by the policy ----
    $sasUrl = New-AzStorageBlobSASToken `
        -Container $ContainerName `
        -Blob $BlobName `
        -Policy $AccessPolicyName `
        -Context $ctx `
        -FullUri `
        -ErrorAction Stop

    return [PSCustomObject]@{
        StorageAccountName = $StorageAccountName
        ContainerName = $ContainerName
        BlobName = $BlobName
        AccessPolicyName = $AccessPolicyName
        KillSwitchUrl = $sasUrl
    }
}
