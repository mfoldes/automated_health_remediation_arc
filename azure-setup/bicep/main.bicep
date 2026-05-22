// ArcRemediator Infrastructure - Phase 1 (Storage + LAW + DCE + DCR)
//
// Scope: resource group.
// Manages:
//   - Storage account + private container + kill-switch blob (SAS URL emitted as output)
//   - Log Analytics workspace with ArcRemediation_CL custom table
//   - Optional Data Collection Endpoint (disabled by default; enable for AMPLS)
//   - Data Collection Rule (kind:Direct) with transformKql + stream declarations
//
// NOT managed by this template (Phase 2 / imperative-only):
//   - AAD App registrations and service principals
//   - Role assignments (RBAC)
//   - Resource group itself
//
// Deploy commands:
//   az deployment group create \
//     --resource-group <rg> \
//     --template-file main.bicep \
//     --parameters @parameters.commercial.bicepparam
//
//   az deployment group what-if \
//     --resource-group <rg> \
//     --template-file main.bicep \
//     --parameters @parameters.commercial.bicepparam

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Cloud profile. Drives endpoint URLs emitted in outputs.')
@allowed(['Commercial', 'AzureGovernmentDoD'])
param cloudProfile string

@description('Storage account name (3-24 lower-case alphanumeric).')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Kill-switch blob container name.')
param containerName string = 'arc-remediator'

@description('Kill-switch blob name.')
param killSwitchBlobName string = 'kill-switch.txt'

@description('Log Analytics workspace name.')
param workspaceName string

@description('Custom table name for telemetry rows.')
param tableName string = 'ArcRemediation_CL'

@description('Data collection rule name.')
param dcrName string

@description('When true, provision a Data Collection Endpoint (required for AMPLS / private link).')
param createDce bool = false

@description('Data Collection Endpoint name (used when createDce=true).')
param dceName string = '${dcrName}-dce'

@description('When true, provision the kill-switch write alert and the four KQL alert rules (requires a Log Analytics workspace and the Storage account to already exist).')
param alertsEnabled bool = false

@description('Optional list of Action Group resource IDs used by alert rules. Ignored when alertsEnabled=false.')
param alertActionGroupIds array = []

@description('Kill-switch SAS token lifetime in hours. Minimum 24.')
@minValue(24)
param sasSasHours int = 8760 // 1 year

// ---------------------------------------------------------------------------
// Storage account + kill-switch infrastructure
// ---------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  name: 'default'
  parent: storageAccount
}

resource killSwitchContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: containerName
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

// ---------------------------------------------------------------------------
// Log Analytics workspace + ArcRemediation_CL custom table
// ---------------------------------------------------------------------------

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource arcRemediationTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  name: tableName
  parent: workspace
  properties: {
    schema: {
      name: tableName
      columns: [
        { name: 'TimeGenerated';        type: 'dateTime' }
        { name: 'EventTimeUtc';         type: 'dateTime' }
        { name: 'SchemaVersion';        type: 'string'   }
        { name: 'Hostname';             type: 'string'   }
        { name: 'Fqdn';                 type: 'string'   }
        { name: 'CloudProfile';         type: 'string'   }
        { name: 'SubscriptionId';       type: 'string'   }
        { name: 'ResourceGroup';        type: 'string'   }
        { name: 'Region';               type: 'string'   }
        { name: 'AzureResourceId';      type: 'string'   }
        { name: 'AgentVersion';         type: 'string'   }
        { name: 'ScriptVersion';        type: 'string'   }
        { name: 'ScriptMode';           type: 'string'   }
        { name: 'RunDurationMs';        type: 'int'      }
        { name: 'Outcome';              type: 'string'   }
        { name: 'OutcomeDetail';        type: 'string'   }
        { name: 'AzureSideState';       type: 'string'   }
        { name: 'AgentReportedState';   type: 'string'   }
        { name: 'ActionsAttempted';     type: 'dynamic'  }
        { name: 'ActionsSuccessful';    type: 'dynamic'  }
        { name: 'ProbeAzcmagentCheck';  type: 'dynamic'  }
        { name: 'ProbeServices';        type: 'dynamic'  }
        { name: 'ProbeCertificate';     type: 'dynamic'  }
        { name: 'ProbeTimeSync';        type: 'dynamic'  }
        { name: 'ProbeAgentVersion';    type: 'dynamic'  }
        { name: 'ConsecutiveFailures';  type: 'int'      }
        { name: 'BreakerTripped';       type: 'boolean'  }
        { name: 'LastRemediationUtc';   type: 'dateTime' }
        { name: 'ErrorMessage';         type: 'string'   }
        { name: 'ErrorType';            type: 'string'   }
        { name: 'StackTraceHash';       type: 'string'   }
        { name: 'ResetByUser';          type: 'string'   }
      ]
    }
    retentionInDays: 90
  }
}

// ---------------------------------------------------------------------------
// Optional Data Collection Endpoint (required for AMPLS / private link)
// ---------------------------------------------------------------------------

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = if (createDce) {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ---------------------------------------------------------------------------
// Data Collection Rule (kind:Direct) - Logs Ingestion API
// ---------------------------------------------------------------------------

var streamName = 'Custom-${tableName}'

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  kind: 'Direct'
  properties: {
    streamDeclarations: {
      '${streamName}': {
        columns: [
          { name: 'TimeGenerated';        type: 'datetime' }
          { name: 'EventTimeUtc';         type: 'datetime' }
          { name: 'SchemaVersion';        type: 'string'   }
          { name: 'Hostname';             type: 'string'   }
          { name: 'Fqdn';                 type: 'string'   }
          { name: 'CloudProfile';         type: 'string'   }
          { name: 'SubscriptionId';       type: 'string'   }
          { name: 'ResourceGroup';        type: 'string'   }
          { name: 'Region';               type: 'string'   }
          { name: 'AzureResourceId';      type: 'string'   }
          { name: 'AgentVersion';         type: 'string'   }
          { name: 'ScriptVersion';        type: 'string'   }
          { name: 'ScriptMode';           type: 'string'   }
          { name: 'RunDurationMs';        type: 'int'      }
          { name: 'Outcome';              type: 'string'   }
          { name: 'OutcomeDetail';        type: 'string'   }
          { name: 'AzureSideState';       type: 'string'   }
          { name: 'AgentReportedState';   type: 'string'   }
          { name: 'ActionsAttempted';     type: 'dynamic'  }
          { name: 'ActionsSuccessful';    type: 'dynamic'  }
          { name: 'ProbeAzcmagentCheck';  type: 'dynamic'  }
          { name: 'ProbeServices';        type: 'dynamic'  }
          { name: 'ProbeCertificate';     type: 'dynamic'  }
          { name: 'ProbeTimeSync';        type: 'dynamic'  }
          { name: 'ProbeAgentVersion';    type: 'dynamic'  }
          { name: 'ConsecutiveFailures';  type: 'int'      }
          { name: 'BreakerTripped';       type: 'boolean'  }
          { name: 'LastRemediationUtc';   type: 'datetime' }
          { name: 'ErrorMessage';         type: 'string'   }
          { name: 'ErrorType';            type: 'string'   }
          { name: 'StackTraceHash';       type: 'string'   }
          { name: 'ResetByUser';          type: 'string'   }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspace.id
          name: 'lawDest'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ streamName ]
        destinations: [ 'lawDest' ]
        transformKql: 'source | extend TimeGenerated = EventTimeUtc'
        outputStream: streamName
      }
    ]
    dataCollectionEndpointId: createDce ? dce.id : null
  }
}

// ---------------------------------------------------------------------------
// Optional alert modules (Phase 2 - alertsEnabled=true)
// ---------------------------------------------------------------------------

module killSwitchAlert 'modules/killswitch-alert.bicep' = if (alertsEnabled) {
  name: 'killswitch-alert'
  params: {
    storageAccountName: storageAccountName
    workspaceId: workspace.id
    containerName: containerName
    blobName: killSwitchBlobName
    location: location
    actionGroupIds: alertActionGroupIds
  }
}

module kqlAlerts 'modules/alerts.bicep' = if (alertsEnabled) {
  name: 'kql-alerts'
  params: {
    workspaceId: workspace.id
    tableName: tableName
    location: location
    actionGroupIds: alertActionGroupIds
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the storage account.')
output storageAccountId string = storageAccount.id

@description('Resource ID of the Log Analytics workspace.')
output workspaceId string = workspace.id

@description('Resource ID of the Data Collection Rule.')
output dcrId string = dcr.id

@description('Immutable ID of the DCR (required for Logs Ingestion API calls).')
output dcrImmutableId string = dcr.properties.immutableId

@description('Logs Ingestion endpoint from the DCR (used when createDce=false).')
output logsIngestionEndpoint string = dcr.properties.logsIngestion != null ? dcr.properties.logsIngestion.endpoint : ''

@description('Stream name for the Logs Ingestion API.')
output streamName string = streamName

@description('DCE resource ID (empty string when createDce=false).')
output dceId string = createDce ? dce.id : ''

@description('DCE Logs Ingestion endpoint (empty string when createDce=false).')
output dceLogsIngestionEndpoint string = createDce ? dce.properties.logsIngestion.endpoint : ''

@description('Kill-switch container resource ID.')
output killSwitchContainerId string = killSwitchContainer.id

@description('Kill-switch blob name.')
output killSwitchBlobName string = killSwitchBlobName
