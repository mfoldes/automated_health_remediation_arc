@{
    RootModule = 'ArcRemediator.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'b8f3a5c2-9e4d-4f81-a6c7-2d5e1b9a3c84'
    Author = 'Michael Foldes'
    CompanyName = 'Microsoft Corporation'
    Copyright = '(c) 2026 Microsoft Corporation. Internal use only.'
    Description = 'Per-server remediator for Azure Arc-enabled Windows servers (Azure Commercial + AzureGovernmentDoD).'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop')
    FunctionsToExport = @('Invoke-ArcRemediation', 'Test-ArcRemediator', 'Reset-ArcRemediator', 'Test-ArcInstallation')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags         = @('Azure', 'Arc', 'Remediation', 'Hybrid')
            ProjectUri   = 'https://github.com/mfoldes/automated_health_remediation_arc'
            ReleaseNotes = 'See CHANGELOG.md'
            Prerelease   = 'preview'
        }
    }
}
