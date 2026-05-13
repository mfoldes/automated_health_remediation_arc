# ArcRemediator operator runbook

This runbook is for the operator. If you're a developer reading the
code, start with the top-level [`README.md`](../README.md) instead.

The job is the same regardless of cloud: stand up the shared Azure
infrastructure once, install the remediator on the target Windows
servers, validate a canary, and graduate to Enforce only after the
documented lab matrix has passed in that cloud.

> **Commercial validation does not qualify Azure Government DoD/IL5.**
> The two clouds have different endpoints, different firewall service
> tags, and different capability flags (Arc Gateway and automatic
> agent upgrade are Commercial-only). Run the lab matrix in
> [section 11](#11-lab-matrix-before-enabling-enforce) independently
> for each cloud.

## Table of contents

1. [What you need before you start](#1-what-you-need-before-you-start)
2. [Provision the Commercial Azure infra](#2-provision-the-commercial-azure-infra)
3. [Provision the Azure Government DoD/IL5 infra](#3-provision-the-azure-government-dodil5-infra)
4. [Network requirements](#4-network-requirements)
5. [Operate the kill switch](#5-operate-the-kill-switch)
6. [Install on a target server](#6-install-on-a-target-server)
7. [Day-to-day operations](#7-day-to-day-operations)
8. [Side effects of an Expired delete + rejoin](#8-side-effects-of-an-expired-delete--rejoin)
9. [Pre-created app registrations](#9-pre-created-app-registrations)
10. [Credential model](#10-credential-model)
11. [Lab matrix before enabling Enforce](#11-lab-matrix-before-enabling-enforce)

## 1. What you need before you start

To do the Azure-side provisioning you need:

- The ability to create **two app registrations** in your Entra
  tenant, or two app IDs that someone else has already created for
  you. Section 9 covers the pre-created case.
- **Owner** or **User Access Administrator** on each Arc resource
  group you intend the remediator to manage. The setup tooling
  assigns Arc Connected Machine roles scoped to those resource
  groups.
- **Monitoring Contributor** (or higher) on the resource group that
  will hold the Log Analytics workspace, the data collection rule,
  and the kill-switch storage account.
- The **Az PowerShell module** installed on your workstation
  (Az.Accounts 5.x or Az 14.x, for the SecureString access-token
  shape).

You will also need to make a couple of choices up front:

- **Where the operator-managed Azure resources go.** One resource
  group per cloud. Typical names: `rg-arc-infra` for Commercial,
  `rg-arc-infra-gov` for Government.
- **Which Arc resource groups you actually want the tool to act on.**
  These are the groups containing the Arc-enabled servers. The
  remediator service principal is scoped to those groups specifically;
  the tool refuses to act on hosts whose Arc resource lives outside
  the configured scope.

## 2. Provision the Commercial Azure infra

From an elevated PowerShell session on your workstation:

```powershell
Connect-AzAccount -Environment AzureCloud
Set-AzContext -Subscription '<your-commercial-subscription-id>'

.\azure-setup\Setup-AzureSide.ps1 `
    -CloudProfile Commercial `
    -SubscriptionId '<sub>' `
    -Location 'eastus' `
    -InfraResourceGroupName 'rg-arc-infra' `
    -ScopedArcResourceGroupName @('rg-arc-prod-1','rg-arc-prod-2') `
    -StorageAccountName 'arcmediator001' `
    -WorkspaceName 'law-arc-commercial' `
    -DcrName 'dcr-arc-commercial' `
    -ConfigOutputPath '.\config.commercial.sample.json'
```

What this provisions:

- Two service principals: one for ARM remediation (scoped to the
  resource groups you listed), one for Logs Ingestion (scoped only
  to the data collection rule).
- A storage account with the kill-switch container and a Service SAS
  with a stored access policy. Public-blob access is off; the
  remediator reads via SAS only.
- A Log Analytics workspace and the custom table `ArcRemediation_CL`.
- A direct-ingestion data collection rule (DCR) targeting that table.
- All the role assignments the two service principals need
  (Resource Administrator + Onboarding on each Arc resource group,
  Monitoring Metrics Publisher on the DCR).

The `-ConfigOutputPath` file is a starter config you copy to each
target server. Edit it to point the credential blocks at the certs
or thumbprints the SPs were issued.

## 3. Provision the Azure Government DoD/IL5 infra

Same flow, different cloud:

```powershell
Connect-AzAccount -Environment AzureUSGovernment
Set-AzContext -Subscription '<your-government-subscription-id>'

.\azure-setup\Setup-AzureSide.ps1 `
    -CloudProfile AzureGovernmentDoD `
    -SubscriptionId '<sub>' `
    -Location 'usgovvirginia' `
    -InfraResourceGroupName 'rg-arc-infra-gov' `
    -ScopedArcResourceGroupName @('rg-arc-gov-1') `
    -StorageAccountName 'arcmediatorgov01' `
    -WorkspaceName 'law-arc-usgov' `
    -DcrName 'dcr-arc-usgov' `
    -ConfigOutputPath '.\config.usgovdod.sample.json'
```

The emitted config has two values forced and locked:

```json
"ArcGatewayResourceId": null,
"EnableAutomaticAgentUpgrade": false
```

Arc Gateway and automatic agent upgrade are Commercial-only features.
A DoD config with a non-null `ArcGatewayResourceId` will produce
`ConfigMismatch` on the host and the remediator will refuse to act.

## 4. Network requirements

Each target server needs outbound HTTPS to the Arc data-plane
endpoints for its cloud. Firewall / proxy / NSG rules below.

### 4.1 Commercial

Service tags (preferred):

- `AzureArcInfrastructure`
- `AzureFrontDoor.Frontend` - required as of April 2026 per
  [Microsoft Learn][arc-network]
- `Storage` (or `Storage.<region>`) - for the kill-switch SAS endpoint
- `AzureMonitor` - for the Logs Ingestion endpoint

Endpoints (use these if service tags aren't available):

- `management.azure.com`
- `login.microsoftonline.com`
- `*.his.arc.azure.com`
- `*.guestconfiguration.azure.com`
- `*.ingest.monitor.azure.com` - your DCR / DCE
- `<your-storage-account>.blob.core.windows.net` - your kill switch

[arc-network]: https://learn.microsoft.com/azure/azure-arc/network-requirements-consolidated#azure-arc-enabled-servers

### 4.2 Azure Government DoD/IL5

Service tags (you need **both** sets):

- `AzureArcInfrastructure` for the Government ranges
- `AzureArcInfrastructure` for the public-cloud ranges as well - as
  of October 28, 2025 the Government agent reaches some
  public-cloud Arc infrastructure ranges. Allow both.
- `AzureFrontDoor.Frontend` - April 2026 requirement, same as
  Commercial

Endpoints:

- `management.usgovcloudapi.net`
- `login.microsoftonline.us`
- `pasff.usgovcloudapi.net` - Arc passthrough
- `*.his.arc.azure.us`
- `*.guestconfiguration.azure.us`
- `*.ingest.monitor.azure.us` - your DCR / DCE
- `<your-storage-account>.blob.core.usgovcloudapi.net` - your kill switch

> Do not mix Commercial and Government endpoints in a single host's
> config. The remediator validates that `azcmagent show -j` reports
> the matching cloud and fails closed before acquiring any access
> token if it doesn't.

## 5. Operate the kill switch

The kill switch is a single blob in the storage account from section
2 or 3: container `arc-remediator`, blob name `kill-switch.txt`.

### To pause the entire fleet

Edit the blob and replace its body with anything other than the exact
word `enabled`. A single space works; deleting the blob entirely also
works. On the next scheduled run each host will record `FleetPaused`,
exit 0, and stop before acquiring any Azure token.

### To unpause

Set the blob body back to the exact lowercase string `enabled`
(no whitespace, no trailing newline; the comparison is
case-sensitive).

### How operators reach the blob without making it public

The storage account has public-blob access disabled and the container
is private. You don't need to enable anonymous access to operate the
kill switch. Use any of these:

- **Storage RBAC.** Give your operator group `Storage Blob Data
  Contributor` on the storage account or the kill-switch container.
- **Storage Explorer** with your Entra account.
- **Azure Portal** "Storage browser" with your Entra account.
- **`az storage blob upload`** from a session signed in with
  Azure CLI.

The remediator on each server reads via a Service SAS bound to a
stored access policy (`arc-remediator-readonly`). Operators do not
share that SAS; they use Storage RBAC on the storage account itself.

## 6. Install on a target server

Build a release ZIP from the repo (`.\package\build.ps1` produces it
under `package/dist/`), copy it to the target server, extract, and run
the installer in an elevated PowerShell session:

```powershell
# 1. Extract somewhere local, e.g. C:\Temp\arc-remediator
# 2. Open samples\config.<cloud>.sample.json and fill in your real
#    tenant ID, subscription ID, certificate thumbprint, DCR
#    immutable ID, kill-switch SAS URL, etc.
# 3. Install and validate:
.\ArcRemediator\Bootstrap\Install.ps1 `
    -ConfigJsonPath .\samples\config.commercial.sample.json `
    -Validate
```

What `Install.ps1` does:

1. Pre-flight checks (PowerShell 5.1 Desktop edition, elevated session).
2. Copies the module to `%ProgramFiles%\ArcRemediator`.
3. DPAPI-wraps your plaintext config and writes the encrypted form
   to `%ProgramData%\ArcRemediator\config.json`. The original
   plaintext file is not copied anywhere.
4. Tightens ACLs:
   - Install path: SYSTEM + Administrators have FullControl;
     standard users have ReadAndExecute.
   - Data path: SYSTEM + Administrators only.
5. Registers the `ArcRemediator` scheduled task: runs as SYSTEM,
   daily at 02:00 with a random 0-60 minute delay, no task-level
   retries, no "start only if network is available" requirement.

With `-Validate`, the installer then runs `Test-ArcInstallation`,
which actively exercises the five things that can go wrong between
"install ran" and "first scheduled run will succeed":

1. The config decrypts and the cloud profile loads.
2. An ARM token can be acquired.
3. A Monitor token can be acquired.
4. The kill switch is reachable and contains `enabled`.
5. A sample row POSTs to the DCR successfully.

Each step reports Passed + Detail. Fix whichever step failed before
promoting the host to Enforce.

## 7. Day-to-day operations

### 7.1 The daily run

The scheduled task fires at 02:00 plus a random 0-60 minute delay.
Each run writes:

- One row to `ArcRemediation_CL` in your Log Analytics workspace.
- One line to `%ProgramData%\ArcRemediator\logs\arc-remediator-YYYYMMDD.log`.

The Azure Monitor workbook under `workbook/arc-remediator-workbook.json`
is the easiest way to see fleet-level signal. Import it into Azure
Monitor → Workbooks → New → Advanced Editor → paste the JSON.

### 7.2 Manually run the diagnostic

From an interactive session on the target server:

```powershell
Test-ArcRemediator
```

This walks the same decision tree as the scheduled task but locked
to Observe mode. Nothing changes in Azure, no services are restarted,
no tags are written. The return value tells you what the real run
*would* do.

### 7.3 Reset the local circuit breaker

If a host's circuit breaker tripped during a transient outage and you
want it to retry sooner than the next 02:00 cycle:

```powershell
Reset-ArcRemediator
```

This clears `BreakerTripped` and `ConsecutiveFailures` and records
who ran the reset. The 7-day Expired-rejoin cooldown marker is
preserved by default: it guards destructive remediation, and you
don't want to silently re-arm it.

If the cooldown also needs clearing (only when you've confirmed the
previous failure was a transient and not a real rejoin that crashed
mid-flight):

```powershell
Reset-ArcRemediator -AlsoClearExpiredAttempt
```

This is `ConfirmImpact='High'`. Run with `-WhatIf` first if you
want to preview the change.

### 7.4 What to do when you see ResourceNotFound

A `ResourceNotFound` outcome means ARM returned 404 when the
remediator asked about its own Arc resource. The remediator does
**not** auto-recreate the resource on a 404 - there are too many
ways for that to be wrong.

When you see it, work through this checklist:

1. Look at `azcmagent show -j` on the host.
2. **Local resource ID is `null`** → the host has lost its Arc
   identity entirely. Reonboard with `azcmagent connect` against a
   fresh resource name. (Note: this is not an Expired condition;
   delete + rejoin would have nothing to delete.)
3. **Local resource ID is populated but points outside the configured
   scope** → the config on this host is wrong. Fix the
   `SubscriptionId` or `ScopedResourceGroups` value in the source
   config sample, re-wrap, and reinstall.
4. **Local resource ID is inside the configured scope but ARM still
   returns 404** → the Arc resource was deleted by something else.
   Decide case by case whether to reonboard or retire the host.

## 8. Side effects of an Expired delete + rejoin

When the destructive path runs successfully, the Arc resource keeps
its name, location, and tags. The resource record itself is recreated,
though, which has several knock-on effects you should tell dependent
teams about **before** enabling Enforce:

- **Managed identity recreation.** The Arc resource's system-assigned
  managed identity gets a new `principalId`. Any role assignment or
  policy assignment that was scoped to the old principalId must be
  redeployed against the new one.
- **Extension child resources.** Arc extensions are children of the
  machine resource; deleting the parent drops them. They re-enroll
  when the extension manager reconnects, but anything queued at the
  moment of the delete is lost. Re-trigger your extension policy
  evaluation after the rejoin completes.
- **Defender for Cloud reassociation** may take up to 24 hours.
- **Update Manager** assignments that were bound to the old resource
  ID do not migrate to the new one; they are re-applied via policy
  evaluation.
- **Azure Monitor / VM Insights.** DCRs that target the resource ID
  via Resource Graph queries need to re-discover the new resource;
  DCRs scoped to subscription or resource group are unaffected.
- **SQL Server enabled by Azure Arc.** SQL instance child resources
  are re-discovered; license assignments may need to be re-applied.
- **Resource history.** The recreated resource has a new
  `properties.vmUuid` and activation timestamp. Anything keyed off
  those will see a discontinuity.

The runbook for each dependent system (Defender plan onboarding,
machine configuration policy redeployment, SQL Arc license
assignment) needs to cover these before Enforce goes on.

## 9. Pre-created app registrations

If tenant policy stops you from creating apps, ask your Entra admin
to create two:

**Arc remediator SP** (display name like `arc-remediator-prod`):

- Authentication: federated credential or a certificate you upload
  (preferred over a secret).
- Role assignments on each scoped Arc resource group:
  - `Azure Connected Machine Resource Administrator`
    (built-in role ID `cd570a14-e51a-42ad-bac8-bafd67325302`)
  - `Azure Connected Machine Onboarding`
    (built-in role ID `b64e21ea-ac4e-4cdf-9dc9-5b892992bee7`)

**Logs Ingestion SP** (display name like `arc-logs-ingestion-prod`):

- Same authentication options.
- One role assignment on the DCR resource:
  - `Monitoring Metrics Publisher`
    (built-in role ID `3913510d-42f4-4e42-8a64-420c390055eb`)

Then pass `-ArcSpDisplayName` and `-LogsSpDisplayName` to
`Setup-AzureSide.ps1` so it reuses your existing apps instead of
creating new ones.

## 10. Credential model

The production model:

- **Two service principals, not one.** The remediator SP has
  ARM-write permission scoped to specific resource groups. The Logs
  Ingestion SP has only DCR-publish permission and cannot read or
  modify any Arc resource. If the Logs Ingestion credential leaks,
  the worst case is fake telemetry; ARM remains untouched.
- **Resource-group scope, not subscription scope.** Role assignments
  for the Arc SP are scoped to the resource groups containing Arc
  machines the tool is allowed to manage. The setup tooling refuses
  to assign subscription-level scope.
- **Certificates by default.** Cert thumbprints live in the Local
  Machine certificate store; the secret never appears on a command
  line or in a log line. Pass `-UseClientSecret` to `Setup-AzureSide.ps1`
  only for lab or canary runs. Production should be on cert.
- **Short-lived credentials.** `Setup-AzureSide.ps1` defaults secret
  validity to 90 days. Rotate via the same script before expiry.

## 11. Lab matrix before enabling Enforce

Run this matrix in each cloud (Commercial and Government) against a
real Arc-enabled VM before you let any host in that cloud move to
Enforce. Each row should produce the expected outcome and no others.

| Scenario | Expected outcome |
|---|---|
| Connected machine, mode = Observe | `Healthy`, no changes anywhere |
| Connected machine, mode = Enforce | `Healthy`, no changes anywhere |
| Disconnected (Arc services stopped), mode = Enforce | Services restarted, outcome = `ServicesRepaired` |
| Disconnected, services already running | `ConnectivityBlocked` or `NeedsHuman` |
| Expired confirmed by a real ARM response, mode = Enforce | `ExpiredRejoinSuccess` after delete + rejoin |
| Expired confirmed, mode = Observe | `ObserveOnly` (no destructive call) |
| Expired confirmed, within the 7-day cooldown | `CooldownSkipped` |
| Cluster-backed host classified Expired | `NeedsHuman`, no destructive call |
| Config says one cloud, host reports the other | `ConfigMismatch`, no token acquired |
| DoD config with a non-null Arc Gateway | `ConfigMismatch` |
| Kill switch blob is not `enabled` | `FleetPaused`, no token acquired |
| ARM returns HTTP 403 | `ArmForbidden`, exit 2 |
| ARM returns HTTP 429 | `ArmThrottled`, exit 3 |
| Logs Ingestion POST fails on an otherwise successful run | `Healthy`, exit 0, `LogIngestionFailed=$true` |

Two extra items to capture once per cloud during the matrix:

- A real ARM GET response for an Expired Arc machine. The remediator
  classifies on the documented `properties.status == "Expired"`
  signal; verify against a real response for that cloud before letting
  the destructive path run.
- A screenshot or saved query of the Azure Monitor workbook tiles
  populated by the matrix's runs. That confirms the telemetry side
  works end to end before you sign off on Enforce.
