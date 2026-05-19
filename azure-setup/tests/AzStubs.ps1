#Requires -Version 5.1
<#
    Shared Az cmdlet stubs for azure-setup/tests/*.Tests.ps1.

    These stubs are ALWAYS defined (unconditionally) so they shadow any real
    Az module cmdlets that happen to be installed on the runner (e.g.
    windows-latest ships Az.Resources and Az.Storage).  Defining them as
    script-scope functions here ensures PowerShell resolves these names to
    the loosely-typed stubs in the current scope chain before reaching the
    strictly-typed Az module cmdlets in the global scope.  Pester's Mock
    then intercepts the stubs — whose parameters are untyped — rather than
    the real cmdlets, which have [guid], [IStorageContext], etc. constraints
    that PSCustomObject test fixtures cannot satisfy.

    Tests must Mock them with the desired behavior.
#>

# ---- Az.Accounts ----
function Get-AzContext { }

# ---- Az.Resources - providers ----
function Get-AzResourceProvider { param([string]$ProviderNamespace) }
function Register-AzResourceProvider { param([string]$ProviderNamespace) }

# ---- Az.Resources - AAD app + SP ----
function Get-AzADApplication { param([string]$DisplayName, [string]$ApplicationId) }
function New-AzADApplication { param([string]$DisplayName) }
function Get-AzADServicePrincipal { param([string]$ApplicationId, [string]$ObjectId) }
function New-AzADServicePrincipal { param([string]$ApplicationId) }
function New-AzADAppCredential {
    param(
        [string]$ApplicationId,
        [string]$CertValue,
        [datetime]$EndDate
    )
}

# ---- Az.Resources - role assignments ----
function Get-AzRoleAssignment {
    param(
        [string]$ObjectId,
        [string]$RoleDefinitionId,
        [string]$Scope
    )
}
function New-AzRoleAssignment {
    param(
        [string]$ObjectId,
        [string]$RoleDefinitionId,
        [string]$Scope
    )
}

# ---- PKI (Windows built-in) ----
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

# ---- Az.Storage ----
function Get-AzStorageAccount { param([string]$ResourceGroupName, [string]$Name) }
function New-AzStorageAccount {
    param(
        [string]$ResourceGroupName, [string]$Name, [string]$Location,
        [string]$SkuName, [string]$Kind, [string]$MinimumTlsVersion,
        [bool]$AllowBlobPublicAccess
    )
}
function Get-AzStorageContainer { param([string]$Name, $Context) }
function New-AzStorageContainer { param([string]$Name, $Context, [string]$Permission) }
function Get-AzStorageBlob { param([string]$Container, [string]$Blob, $Context) }
function Set-AzStorageBlobContent { param([string]$File, [string]$Container, [string]$Blob, $Context) }
function Get-AzStorageContainerStoredAccessPolicy { param([string]$Container, $Context) }
function New-AzStorageContainerStoredAccessPolicy {
    param([string]$Container, $Context, [string]$Policy, [string]$Permission, [datetime]$ExpiryTime)
}
function New-AzStorageBlobSASToken {
    param([string]$Container, [string]$Blob, [string]$Policy, $Context, [switch]$FullUri)
}

# ---- Az.OperationalInsights + Az.Accounts REST ----
function Get-AzOperationalInsightsWorkspace { param([string]$ResourceGroupName, [string]$Name) }
function New-AzOperationalInsightsWorkspace {
    param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$Sku)
}
function Invoke-AzRestMethod {
    param([string]$Path, [string]$Method, [string]$Payload)
}
