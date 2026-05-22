// ArcRemediator - Kill-switch write alert
//
// Creates two resources:
//   1. Diagnostic settings on the storage account blob service → sends
//      StorageBlobLogs to the Log Analytics workspace so the query alert
//      below has data to evaluate against.
//   2. A Scheduled Query Rule (severity=Critical) that fires within 10 minutes
//      of any successful write to the kill-switch blob. This guards the R6
//      STRIDE threat: an attacker with Storage Blob Data Contributor can
//      silently lock out the fleet by writing "Disabled" to the blob.
//
// Called by main.bicep when alertsEnabled=true.

@description('Name of the storage account that holds the kill-switch blob (not the resource ID).')
param storageAccountName string

@description('Resource ID of the Log Analytics workspace that receives StorageBlobLogs.')
param workspaceId string

@description('Kill-switch blob container name.')
param containerName string = 'arc-remediator'

@description('Kill-switch blob name.')
param blobName string = 'kill-switch.txt'

@description('Azure region for the alert rule.')
param location string = resourceGroup().location

@description('Friendly name for the scheduled query alert rule.')
param alertName string = 'arc-remediator-killswitch-write'

@description('''
Optional list of Action Group resource IDs to notify on alert.
Example: ['/subscriptions/.../resourceGroups/.../providers/Microsoft.Insights/actionGroups/ops-team']
''')
param actionGroupIds array = []

// ---------------------------------------------------------------------------
// Existing references
// ---------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' existing = {
  name: 'default'
  parent: storageAccount
}

// ---------------------------------------------------------------------------
// Diagnostic settings: stream StorageBlobLogs → LAW
// ---------------------------------------------------------------------------

resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'arc-remediator-blob-diag'
  scope: blobService
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        category: 'StorageWrite'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
    metrics: []
  }
}

// ---------------------------------------------------------------------------
// Scheduled Query Rule: alert on any write to the kill-switch blob
// ---------------------------------------------------------------------------

resource killSwitchWriteAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: alertName
  location: location
  properties: {
    description: 'Fires when the ArcRemediator kill-switch blob receives a successful write. Any unexpected write should be investigated immediately — an attacker with Storage Blob Data Contributor can disable fleet remediation by writing "Disabled" to this blob.'
    severity: 0 // Critical
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''StorageBlobLogs
| where OperationName in ("PutBlob", "PutBlock", "PutBlockList", "CopyBlob")
| where ObjectKey has '${containerName}/${blobName}'
| where StatusCode < 400
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: actionGroupIds
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the blob diagnostic settings.')
output blobDiagnosticsId string = blobDiagnostics.id

@description('Resource ID of the kill-switch write alert rule.')
output killSwitchAlertId string = killSwitchWriteAlert.id
