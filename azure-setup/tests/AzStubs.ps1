#Requires -Version 5.1
<#
    Shared Az cmdlet stubs for azure-setup/tests/*.Tests.ps1.

    Pester 5's Mock requires the command to exist in the runspace before it
    can redirect. Az modules (Az.Accounts, Az.Resources, Az.Storage,
    Az.OperationalInsights, Az.Monitor) may or may not be loaded in the test
    environment, so each stub is only defined when the real cmdlet is absent.

    These stubs are intentionally empty - tests must Mock them with the
    desired behavior. The parameter signatures only need to be loose enough
    that the splat call from the helper under test does not blow up before
    the mock intercepts.
#>

# ---- Az.Accounts ----
if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue)) {
    function Get-AzContext { }
}

# ---- Az.Resources - providers ----
if (-not (Get-Command Get-AzResourceProvider -ErrorAction SilentlyContinue)) {
    function Get-AzResourceProvider { param([string]$ProviderNamespace) }
}
if (-not (Get-Command Register-AzResourceProvider -ErrorAction SilentlyContinue)) {
    function Register-AzResourceProvider { param([string]$ProviderNamespace) }
}

# ---- Az.Resources - AAD app + SP ----
if (-not (Get-Command Get-AzADApplication -ErrorAction SilentlyContinue)) {
    function Get-AzADApplication { param([string]$DisplayName, [string]$ApplicationId) }
}
if (-not (Get-Command New-AzADApplication -ErrorAction SilentlyContinue)) {
    function New-AzADApplication { param([string]$DisplayName) }
}
if (-not (Get-Command Get-AzADServicePrincipal -ErrorAction SilentlyContinue)) {
    function Get-AzADServicePrincipal { param([string]$ApplicationId, [string]$ObjectId) }
}
if (-not (Get-Command New-AzADServicePrincipal -ErrorAction SilentlyContinue)) {
    function New-AzADServicePrincipal { param([string]$ApplicationId) }
}
if (-not (Get-Command New-AzADAppCredential -ErrorAction SilentlyContinue)) {
    function New-AzADAppCredential {
        param(
            [string]$ApplicationId,
            [string]$CertValue,
            [datetime]$EndDate
        )
    }
}

# ---- Az.Resources - role assignments ----
if (-not (Get-Command Get-AzRoleAssignment -ErrorAction SilentlyContinue)) {
    function Get-AzRoleAssignment {
        param(
            [string]$ObjectId,
            [string]$RoleDefinitionId,
            [string]$Scope
        )
    }
}
if (-not (Get-Command New-AzRoleAssignment -ErrorAction SilentlyContinue)) {
    function New-AzRoleAssignment {
        param(
            [string]$ObjectId,
            [string]$RoleDefinitionId,
            [string]$Scope
        )
    }
}

# ---- PKI (Windows built-in) ----
if (-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
    function New-SelfSignedCertificate {
        param(
            [string]$Subject,
            [string]$CertStoreLocation,
            $KeyExportPolicy,
            $KeySpec,
            [int]$KeyLength,
            [string]$KeyAlgorithm,
            [string]$HashAlgorithm,
            [datetime]$NotAfter
        )
    }
}

# ---- Az.Storage ----
if (-not (Get-Command Get-AzStorageAccount -ErrorAction SilentlyContinue)) {
    function Get-AzStorageAccount { param([string]$ResourceGroupName, [string]$Name) }
}
if (-not (Get-Command New-AzStorageAccount -ErrorAction SilentlyContinue)) {
    function New-AzStorageAccount {
        param(
            [string]$ResourceGroupName, [string]$Name, [string]$Location,
            [string]$SkuName, [string]$Kind, [string]$MinimumTlsVersion,
            [bool]$AllowBlobPublicAccess
        )
    }
}
if (-not (Get-Command Get-AzStorageContainer -ErrorAction SilentlyContinue)) {
    function Get-AzStorageContainer { param([string]$Name, $Context) }
}
if (-not (Get-Command New-AzStorageContainer -ErrorAction SilentlyContinue)) {
    function New-AzStorageContainer { param([string]$Name, $Context, [string]$Permission) }
}
if (-not (Get-Command Get-AzStorageBlob -ErrorAction SilentlyContinue)) {
    function Get-AzStorageBlob { param([string]$Container, [string]$Blob, $Context) }
}
if (-not (Get-Command Set-AzStorageBlobContent -ErrorAction SilentlyContinue)) {
    function Set-AzStorageBlobContent { param([string]$File, [string]$Container, [string]$Blob, $Context) }
}
if (-not (Get-Command Get-AzStorageContainerStoredAccessPolicy -ErrorAction SilentlyContinue)) {
    function Get-AzStorageContainerStoredAccessPolicy { param([string]$Container, $Context) }
}
if (-not (Get-Command New-AzStorageContainerStoredAccessPolicy -ErrorAction SilentlyContinue)) {
    function New-AzStorageContainerStoredAccessPolicy {
        param([string]$Container, $Context, [string]$Policy, [string]$Permission, [datetime]$ExpiryTime)
    }
}
if (-not (Get-Command New-AzStorageBlobSASToken -ErrorAction SilentlyContinue)) {
    function New-AzStorageBlobSASToken {
        param([string]$Container, [string]$Blob, [string]$Policy, $Context, [switch]$FullUri)
    }
}

# ---- Az.OperationalInsights + Az.Accounts REST ----
if (-not (Get-Command Get-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue)) {
    function Get-AzOperationalInsightsWorkspace { param([string]$ResourceGroupName, [string]$Name) }
}
if (-not (Get-Command New-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue)) {
    function New-AzOperationalInsightsWorkspace {
        param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$Sku)
    }
}
if (-not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) {
    function Invoke-AzRestMethod {
        param([string]$Path, [string]$Method, [string]$Payload)
    }
}
