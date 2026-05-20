// AzureUSGovernment (DoD/IL5) parameters for ArcRemediator infrastructure.
// Usage:
//   az deployment group create \
//     --resource-group rg-arc-infra-dod \
//     --template-file main.bicep \
//     --parameters @parameters.dod.bicepparam

using './main.bicep'

param cloudProfile = 'AzureGovernmentDoD'
param location = 'usgovvirginia'
param storageAccountName = 'starcremediatordod'
param containerName = 'arc-remediator'
param killSwitchBlobName = 'kill-switch.txt'
param workspaceName = 'law-arc-remediator-dod'
param tableName = 'ArcRemediation_CL'
param dcrName = 'dcr-arc-remediator-dod'
param createDce = false
param dceName = 'dcr-arc-remediator-dod-dce'
param sasSasHours = 8760
