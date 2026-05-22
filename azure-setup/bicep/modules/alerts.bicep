// ArcRemediator - KQL Scheduled Query Alert rules
//
// Creates four Scheduled Query Rules over ArcRemediation_CL:
//
//   1. ExpiredRejoinFailure  – any host with a failed delete-and-rejoin attempt
//      in the past 4 h (outcome=ExpiredRejoinFailure). Fires immediately on the
//      first failure so an operator can intervene before the circuit breaker trips.
//
//   2. NeedsHuman            – any host stuck in NeedsHuman status for the last
//      4 h. These hosts require operator attention and will never self-heal.
//
//   3. SilentServers         – any host that has not sent a telemetry row for
//      >38 h (threshold is 36 h + 2 h evaluation buffer). May indicate the Task
//      Scheduler job is broken, the host is offline, or the DCR pipeline is down.
//
//   4. BreakerTripped        – any host whose circuit breaker is currently tripped
//      (ConsecutiveFailures >= threshold). The fleet blob reset is the normal
//      remedy; this alert fires so the operator knows to investigate root cause.
//
// Called by main.bicep when alertsEnabled=true.

@description('Resource ID of the Log Analytics workspace containing ArcRemediation_CL.')
param workspaceId string

@description('Custom table name (default: ArcRemediation_CL).')
param tableName string = 'ArcRemediation_CL'

@description('Azure region for the alert rules.')
param location string = resourceGroup().location

@description('''
Optional list of Action Group resource IDs to notify on alert.
Example: ['/subscriptions/.../resourceGroups/.../providers/Microsoft.Insights/actionGroups/ops-team']
''')
param actionGroupIds array = []

// ---------------------------------------------------------------------------
// 1. ExpiredRejoinFailure alert
// ---------------------------------------------------------------------------

resource expiredRejoinFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'arc-remediator-expired-rejoin-failure'
  location: location
  properties: {
    description: 'One or more Arc machines had a failed delete-and-rejoin attempt (outcome=ExpiredRejoinFailure) in the past 4 hours. Investigate before the circuit breaker trips and blocks further automated remediation.'
    severity: 1 // Error
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT4H'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '${tableName}\n| where TimeGenerated > ago(4h)\n| where Outcome == "ExpiredRejoinFailure"\n| summarize Count = count(), FailedHosts = make_set(Hostname) by bin(TimeGenerated, 4h)\n'
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
// 2. NeedsHuman alert
// ---------------------------------------------------------------------------

resource needsHumanAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'arc-remediator-needs-human'
  location: location
  properties: {
    description: 'One or more Arc machines are in NeedsHuman status. These hosts require operator intervention and will never self-heal via automated remediation. Common causes: cluster-backed machine, config mismatch, agent cert expired.'
    severity: 2 // Warning
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT4H'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '${tableName}\n| where TimeGenerated > ago(4h)\n| summarize arg_max(TimeGenerated, Outcome, OutcomeDetail) by Hostname\n| where Outcome == "NeedsHuman"\n'
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
// 3. SilentServers alert
// ---------------------------------------------------------------------------

resource silentServersAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'arc-remediator-silent-servers'
  location: location
  properties: {
    description: 'One or more Arc machines have not sent a telemetry row in over 36 hours. Possible causes: Task Scheduler job broken, host offline, DCR/LAW ingestion pipeline down.'
    severity: 2 // Warning
    enabled: true
    evaluationFrequency: 'PT2H'
    windowSize: 'PT2H'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          // Look back 38 h (36 h silence threshold + 2 h evaluation window buffer)
          // to avoid false positives when the evaluation window edges fall on the
          // boundary of the 36-hour silence window.
          query: '${tableName}\n| summarize LastSeen = max(TimeGenerated) by Hostname\n| where LastSeen < ago(38h)\n'
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
    autoMitigate: false // Silence persists; don't auto-resolve until someone investigates.
    actions: {
      actionGroups: actionGroupIds
    }
  }
}

// ---------------------------------------------------------------------------
// 4. BreakerTripped alert
// ---------------------------------------------------------------------------

resource breakerTrippedAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'arc-remediator-breaker-tripped'
  location: location
  properties: {
    description: 'One or more Arc machines have their circuit breaker tripped (BreakerTripped=true). No further automated remediation will run on these hosts until the fleet-wide breaker reset blob is updated by an operator.'
    severity: 1 // Error
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT2H'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '${tableName}\n| where TimeGenerated > ago(2h)\n| summarize arg_max(TimeGenerated, BreakerTripped, ConsecutiveFailures, Outcome) by Hostname\n| where BreakerTripped == true\n'
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

@description('Resource ID of the ExpiredRejoinFailure alert rule.')
output expiredRejoinFailureAlertId string = expiredRejoinFailureAlert.id

@description('Resource ID of the NeedsHuman alert rule.')
output needsHumanAlertId string = needsHumanAlert.id

@description('Resource ID of the SilentServers alert rule.')
output silentServersAlertId string = silentServersAlert.id

@description('Resource ID of the BreakerTripped alert rule.')
output breakerTrippedAlertId string = breakerTrippedAlert.id
