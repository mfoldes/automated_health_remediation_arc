// Commercial (AzureCloud) parameters for ArcRemediator infrastructure.
// Usage:
//   az deployment group create \
//     --resource-group rg-arc-infra-commercial \
//     --template-file main.bicep \
//     --parameters @parameters.commercial.bicepparam

using './main.bicep'

param cloudProfile = 'Commercial'
param location = 'eastus'
param storageAccountName = 'starcremediator'
param containerName = 'arc-remediator'
param killSwitchBlobName = 'kill-switch.txt'
param workspaceName = 'law-arc-remediator-commercial'
param tableName = 'ArcRemediation_CL'
param dcrName = 'dcr-arc-remediator-commercial'
param createDce = false
param dceName = 'dcr-arc-remediator-commercial-dce'
param sasSasHours = 8760
