#Requires -Version 5.1

# Bicep template structure tests.
# These tests validate the Bicep template files without requiring a live
# Azure subscription.  They parse file structure, check required parameters,
# and verify resource type presence.
#
# Optional what-if test: set $env:ARC_BICEP_WHATIF_RG and $env:ARC_BICEP_WHATIF_SUB
# to run `az deployment group what-if` against a real (empty) resource group.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:BicepDir = Join-Path $script:RepoRoot 'azure-setup' 'bicep'
    $script:MainBicep = Join-Path $script:BicepDir 'main.bicep'
    $script:ParamsCommercial = Join-Path $script:BicepDir 'parameters.commercial.bicepparam'
    $script:ParamsDod = Join-Path $script:BicepDir 'parameters.dod.bicepparam'
}

Describe 'Bicep template file structure' {
    Context 'Required files exist' {
        It 'main.bicep is present' {
            $script:MainBicep | Should -Exist
        }

        It 'parameters.commercial.bicepparam is present' {
            $script:ParamsCommercial | Should -Exist
        }

        It 'parameters.dod.bicepparam is present' {
            $script:ParamsDod | Should -Exist
        }
    }

    Context 'main.bicep content' {
        BeforeAll {
            $script:BicepContent = Get-Content -LiteralPath $script:MainBicep -Raw
        }

        It 'declares cloudProfile parameter with allowed values' {
            $script:BicepContent | Should -Match "param cloudProfile string"
            $script:BicepContent | Should -Match "Commercial"
            $script:BicepContent | Should -Match "AzureGovernmentDoD"
        }

        It 'declares storageAccountName parameter' {
            $script:BicepContent | Should -Match "param storageAccountName string"
        }

        It 'declares workspaceName parameter' {
            $script:BicepContent | Should -Match "param workspaceName string"
        }

        It 'declares dcrName parameter' {
            $script:BicepContent | Should -Match "param dcrName string"
        }

        It 'declares createDce parameter defaulting to false' {
            $script:BicepContent | Should -Match "param createDce bool = false"
        }

        It 'includes Microsoft.Storage/storageAccounts resource' {
            $script:BicepContent | Should -Match "Microsoft\.Storage/storageAccounts"
        }

        It 'includes kill-switch container resource' {
            $script:BicepContent | Should -Match "Microsoft\.Storage/storageAccounts/blobServices/containers"
        }

        It 'includes Log Analytics workspace resource' {
            $script:BicepContent | Should -Match "Microsoft\.OperationalInsights/workspaces"
        }

        It 'includes ArcRemediation_CL table resource' {
            $script:BicepContent | Should -Match "Microsoft\.OperationalInsights/workspaces/tables"
        }

        It 'includes DCR resource (kind:Direct)' {
            $script:BicepContent | Should -Match "Microsoft\.Insights/dataCollectionRules"
            $script:BicepContent | Should -Match "kind: 'Direct'"
        }

        It 'includes transformKql with TimeGenerated projection' {
            $script:BicepContent | Should -Match "transformKql"
            $script:BicepContent | Should -Match "extend TimeGenerated = EventTimeUtc"
        }

        It 'includes SchemaVersion column in table schema' {
            $script:BicepContent | Should -Match "SchemaVersion"
        }

        It 'emits dcrImmutableId output' {
            $script:BicepContent | Should -Match "output dcrImmutableId string"
        }

        It 'emits logsIngestionEndpoint output' {
            $script:BicepContent | Should -Match "output logsIngestionEndpoint string"
        }

        It 'emits streamName output' {
            $script:BicepContent | Should -Match "output streamName string"
        }

        It 'sets AllowBlobPublicAccess to false' {
            $script:BicepContent | Should -Match "allowBlobPublicAccess: false"
        }

        It 'enforces TLS1_2 on storage account' {
            $script:BicepContent | Should -Match "TLS1_2"
        }
    }

    Context 'parameters.commercial.bicepparam content' {
        BeforeAll {
            $script:CommercialContent = Get-Content -LiteralPath $script:ParamsCommercial -Raw
        }

        It 'references main.bicep via using directive' {
            $script:CommercialContent | Should -Match "using './main.bicep'"
        }

        It 'sets cloudProfile to Commercial' {
            $script:CommercialContent | Should -Match "cloudProfile = 'Commercial'"
        }

        It 'sets a workspaceName' {
            $script:CommercialContent | Should -Match "param workspaceName ="
        }

        It 'sets a dcrName' {
            $script:CommercialContent | Should -Match "param dcrName ="
        }
    }

    Context 'parameters.dod.bicepparam content' {
        BeforeAll {
            $script:DodContent = Get-Content -LiteralPath $script:ParamsDod -Raw
        }

        It 'references main.bicep via using directive' {
            $script:DodContent | Should -Match "using './main.bicep'"
        }

        It 'sets cloudProfile to AzureGovernmentDoD' {
            $script:DodContent | Should -Match "cloudProfile = 'AzureGovernmentDoD'"
        }

        It 'sets usgovvirginia as default location' {
            $script:DodContent | Should -Match "usgovvirginia"
        }
    }

    Context 'az deployment group what-if (live Azure; skipped by default)' -Skip:(-not ($env:ARC_BICEP_WHATIF_RG -and $env:ARC_BICEP_WHATIF_SUB)) {
        It 'what-if resolves expected resource types without errors' {
            $result = & az deployment group what-if `
                --subscription $env:ARC_BICEP_WHATIF_SUB `
                --resource-group $env:ARC_BICEP_WHATIF_RG `
                --template-file $script:MainBicep `
                --parameters "@$script:ParamsCommercial" `
                --no-prompt `
                --output json 2>&1

            $LASTEXITCODE | Should -Be 0
            $result | Should -Match 'Microsoft.Storage/storageAccounts'
            $result | Should -Match 'Microsoft.OperationalInsights/workspaces'
            $result | Should -Match 'Microsoft.Insights/dataCollectionRules'
        }
    }
}
