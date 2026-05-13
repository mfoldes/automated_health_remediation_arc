# Arc Remediator - Design Spec

**Status:** Draft, revised after review
**Date:** 2026-05-12
**MVP target clouds:** Azure Commercial and Azure Government DoD / IL5

---

## 1. Problem

Azure Arc-enabled Windows servers chronically drift into a stale, Disconnected, or Expired state in Azure at fleet scale. Once a server is Expired, Arc-mediated operations fail: Run Command, extensions, policy, and other remote control-plane actions are unavailable. Today the practical recovery path requires local access to disconnect/re-onboard the agent, which does not scale across decentralized operators and mixed management posture.

Known causes include proxy/firewall drift, stopped Arc services, identity certificate renewal failure after long disconnection, time skew, unsupported agent versions, and transient Azure or network failures. The system must identify these causes when possible, avoid destructive action on ambiguous failures, and safely re-onboard only when the machine is confirmed Expired.

## 2. MVP scope

### 2.1 Supported clouds

MVP supports exactly:

1. **Azure Commercial**
2. **Azure Government DoD / IL5**, using the Azure Government control-plane surface and validated in the target IL5 tenant

Both clouds are first-class MVP acceptance targets. Commercial validation does not qualify DoD/IL5. Each cloud must pass the same lab, setup, ingestion, and canary gates before Enforce mode.

### 2.2 Out of scope

- Other air-gapped clouds.
- Linux servers.
- Recreating missing Arc resources automatically on ARM 404.
- A central command/control plane outside Azure Arc.
- Unsigned code auto-update.
- Push-based ad-hoc remediation from the portal.
- Hosts under AppLocker / WDAC enforcement unless code signing is added.

## 3. Goals

- **Self-contained per server.** Each server evaluates its own Arc health once daily and records local state.
- **Commercial + DoD/IL5 parity.** The same codebase supports both MVP clouds with explicit endpoint/token profiles and independent validation.
- **Least privilege.** Use dedicated service principals per cloud and scope boundary, scoped to named Arc resource groups and the per-cloud DCR. Certificate-based authentication is preferred; a single all-fleet secret is not acceptable outside lab/canary validation.
- **Safe remediation.** Non-destructive repair for Disconnected; destructive delete/rejoin only for Azure-side confirmed Expired.
- **Operator visibility.** Emit structured Log Analytics rows when Monitor auth/ingestion is available and local logs always after config load.
- **Fleet safety.** Kill switch, Observe mode, cooldown, circuit breaker, per-machine pause, and independent canaries.
- **Operator-friendly install.** A repeatable installer supports GPO-managed and operator-run deployments.

## 4. Cloud model

Cloud-specific behavior lives in one endpoint/profile table. The implementation must not infer endpoints or hostnames for unsupported clouds.

| Profile | Azure environment | `azcmagent --cloud` | ARM endpoint | Entra authority | Storage suffix | ARM token resource | Monitor token scope |
|---|---|---|---|---|---|---|---|
| `Commercial` | `AzureCloud` | `AzureCloud` | `https://management.azure.com` | `https://login.microsoftonline.com` | `blob.core.windows.net` | `https://management.azure.com/` | `https://monitor.azure.com/.default` |
| `AzureGovernmentDoD` | `AzureUSGovernment` | `AzureUSGovernment` | `https://management.usgovcloudapi.net` | `https://login.microsoftonline.us` | `blob.core.usgovcloudapi.net` | `https://management.usgovcloudapi.net/` | `https://monitor.azure.us/.default` |

DoD/IL5 uses the Azure Government cloud profile unless lab validation proves a different officially supported value is required. The implementation must fail closed if the local `azcmagent show -j` cloud value and configured cloud profile disagree.

Cloud profiles also carry explicit capability flags. The runtime must not infer feature availability from endpoint suffixes.

| Profile | Supports Arc Gateway | Supports automatic agent upgrade | Required behavior |
|---|---:|---:|---|
| `Commercial` | Yes | Yes, when enabled by operator and supported agent version | Gateway and automatic upgrade may be used only when explicitly configured and validated. |
| `AzureGovernmentDoD` | No | No | A non-null `ArcGatewayResourceId` is a config mismatch. `EnableAutomaticAgentUpgrade` must be ignored or rejected during validation and must never result in `--enable-automatic-upgrade` being passed. |

### 4.1 Network validation

Arc endpoint validation uses `azcmagent check`, not a homegrown list of HTTPS HEAD probes. `azcmagent check` is the supported, cloud/region/proxy/private-link-aware Arc network diagnostic.

Custom network checks are limited to non-Arc dependencies:

- Kill-switch Storage SAS read.
- Logs Ingestion endpoint reachability.
- Optional setup-time checks for DCR/DCE/private-link paths.

The setup docs must still cite current Microsoft Arc network requirements for firewall teams, including the appropriate Commercial or Azure Government service tags and endpoints.

## 5. Azure-side prerequisites per MVP cloud

| Resource | Purpose | Required notes |
|---|---|---|
| Arc remediation service principal(s) | ARM read/tag/delete operations and onboarding/re-onboarding | One or more SPs per cloud, segmented by resource group, canary ring, or environment boundary. Assign `Azure Connected Machine Resource Administrator` and `Azure Connected Machine Onboarding` only on named Arc RGs that the package is allowed to manage. This credential is high privilege because the built-in role can manage machines, extensions, run commands, gateways, private link scopes, and deployments within scope; production rollout should prefer a constrained custom role when validated. Prefer certificate credentials; client secrets are allowed only for lab/canary or explicitly approved short-lived deployments. |
| Logs ingestion service principal(s) | Logs Ingestion API only | Assign `Monitoring Metrics Publisher` on the DCR. Production must use a separate identity from Arc remediation unless an explicit risk acceptance approves shared credentials for a limited canary. |
| Storage account | Fleet kill switch | Private container `arc-remediator`, blob `kill-switch.txt`, content `enabled` or `paused`, read via Service SAS backed by a stored access policy. Anonymous blob access is not required. |
| Log Analytics workspace | Per-cloud telemetry | Dedicated workspace per cloud or per environment boundary. |
| Custom table `ArcRemediation_CL` | Stores remediator rows | Created before ingestion. Schema in section 10. |
| Data Collection Rule | Direct Logs Ingestion routing | Required. Must declare stream `Custom-ArcRemediation`, transform to the table schema, set `outputStream` to `Custom-ArcRemediation_CL`, route to the workspace, and expose immutable ID. New DCRs should be created with `"kind": "Direct"` so `properties.endpoints.logsIngestion` exists. Reusing an existing DCR is allowed only if it already has either a `logsIngestion` endpoint or a valid `dataCollectionEndpointId` linked to a DCE. If a reused DCR has neither, setup must create a replacement DCR by default or fail if the operator forbids replacement. It must not pretend that a standalone DCE can fix an unlinked DCR. |
| Data Collection Endpoint | Optional ingestion endpoint | Use when private link/network policy requires it, or when reusing an existing DCR that is already linked to a DCE. DCE logs ingestion regionality follows the destination Log Analytics workspace, not Arc machine region. |

`Setup-AzureSide.ps1` must fully provision these resources or fail. It must not leave DCR authoring as a manual README step.

## 6. Server install and configuration

### 6.1 Layout

```text
%ProgramFiles%\ArcRemediator\           ACL: SYSTEM:F, Administrators:F, Users:RX
├─ ArcRemediator.psd1
├─ ArcRemediator.psm1
├─ Public\
│  ├─ Invoke-ArcRemediation.ps1
│  ├─ Test-ArcRemediator.ps1
│  └─ Reset-ArcRemediator.ps1
├─ Private\
├─ Data\
│  ├─ cloud-profiles.psd1
│  └─ version.txt
└─ Bootstrap\
   ├─ Install.ps1
   └─ Uninstall.ps1

%ProgramData%\ArcRemediator\            ACL: SYSTEM:F, Administrators:F (no Users)
├─ config.json                           DPAPI machine-scope wrapped
├─ state.json
└─ logs\
   └─ arc-remediator-YYYYMMDD.log        10 MB cap, 14 day retention
```

### 6.2 Config

```json
{
  "CloudProfile": "Commercial",
  "ArcCredential": {
    "TenantId": "00000000-0000-0000-0000-000000000000",
    "ClientId": "00000000-0000-0000-0000-000000000000",
    "CredentialType": "Certificate",
    "ClientSecret": null,
    "CertificateThumbprint": "0000000000000000000000000000000000000000"
  },
  "MonitorCredential": {
    "UseArcCredential": false,
    "TenantId": "00000000-0000-0000-0000-000000000000",
    "ClientId": "00000000-0000-0000-0000-000000000000",
    "CredentialType": "Certificate",
    "ClientSecret": null,
    "CertificateThumbprint": "0000000000000000000000000000000000000000"
  },
  "SubscriptionId": "00000000-0000-0000-0000-000000000000",
  "ScopedResourceGroups": ["rg-arc-prod-1", "rg-arc-prod-2"],
  "LogIngestionEndpoint": "https://<dcr-or-dce-endpoint>",
  "DcrImmutableId": "dcr-...",
  "StreamName": "Custom-ArcRemediation",
  "KillSwitchUrl": "https://<storage>.blob.core.windows.net/arc-remediator/kill-switch.txt?<sas>",
  "PrivateLinkScopeResourceId": null,
  "ArcGatewayResourceId": null,
  "ProxyUrl": null,
  "EnableAutomaticAgentUpgrade": false,
  "CircuitBreakerFailureThreshold": 3,
  "Mode": "Observe",
  "Version": "1.0.0"
}
```

Config is DPAPI LocalMachine-protected because the scheduled task runs as SYSTEM. DPAPI prevents casual disclosure to non-admin users but does not protect against local admins or SYSTEM.

Production configuration should use `CredentialType = Certificate` with a private key protected in the Local Machine certificate store where possible. `ClientSecret` remains supported for lab/canary validation and for environments that explicitly accept the blast radius, but short lifetime, rotation, and scope segmentation are mandatory. `MonitorCredential.UseArcCredential = true` is allowed only for lab/canary or explicit risk acceptance; production should use separate identities for Arc remediation and Logs Ingestion.

### 6.3 Scheduled task

| Property | Value |
|---|---|
| Name | `ArcRemediator` |
| Principal | `NT AUTHORITY\SYSTEM` |
| Trigger | Daily at 02:00 local time, random delay 0-60 min |
| Action | Import module and run `Invoke-ArcRemediation`; translate outcome to process exit code |
| Multiple instances | Ignore new |
| Stop if exceeds | 30 min |
| Restart on failure | Disabled; retry/backoff is handled inside the remediator so fleet-wide ARM throttling is not amplified by Task Scheduler |
| Run only when network available | false |

If Task Scheduler status is used for local triage, the entry script must exit nonzero for real failures such as auth failure, ARM forbidden, remediation failure, and unhandled errors. The exit-code mapping is:

| Exit | Outcomes |
|---|---|
| 0 | `Healthy`, `FleetPaused`, `MachinePaused`, `ObserveOnly`, `CooldownSkipped`, `ServicesRepaired`, `ConnectivityBlocked`, `NeedsHuman`, `BreakerTripped`, `ResourceNotFound`, `LogIngestionFailure` when telemetry is the only failed operation |
| 1 | `ExpiredRejoinFailure` |
| 2 | `AuthFailure`, `ArmForbidden`, `ConfigMismatch`, `AzureMachineError` |
| 3 | `ArmThrottled`, `ArmTransientFailure` |
| 4 | `Error` (unhandled) |

Logs ingestion is best effort. A Logs Ingestion API failure must not cause a scheduled-task retry when the primary health/remediation outcome succeeded.

### 6.4 TLS

The module must ensure `[Net.ServicePointManager]::SecurityProtocol` includes `Tls12` (and `Tls13` when the enum value is available) immediately before each outbound REST call. Logs Ingestion API has enforced TLS 1.2 or higher since 2026-03-01 (see `learn.microsoft.com/azure/azure-monitor/fundamentals/best-practices-security`); Windows PowerShell 5.1's default protocol set is not sufficient on all OS builds. A wrapper function around `Invoke-RestMethod` is responsible for this so the setting is scoped to the remediator's own requests rather than applied globally at module load.

## 7. Runtime flow

1. Acquire local mutex.
2. Load DPAPI config and local state.
3. Read kill-switch blob by SAS with retries. Anything other than exact `enabled` pauses the run. This occurs before Azure auth, so the run is logged locally; LAW logging is best effort only after Monitor token acquisition.
4. Run `azcmagent show -j` and validate the configured cloud profile matches the local agent cloud. Parse the local Azure resource ID and fail closed with `ConfigMismatch` / `NeedsHuman` before Azure auth if the subscription or resource group is outside `SubscriptionId` and `ScopedResourceGroups`.
5. Acquire **separate** tokens:
   - ARM token for ARM GET/PATCH/DELETE.
   - Monitor token for Logs Ingestion API.
6. ARM GET the local Arc machine resource and classify the result:
   - 200 + implementation-validated Azure-side Expired evidence -> `Expired`
   - 200 + `properties.status == Connected` -> `Connected`
   - 200 + `properties.status == Disconnected` -> `Disconnected`
   - 200 + `properties.status == Error` without validated Expired evidence -> `AzureMachineError`
   - 404 -> `ResourceNotFound`
   - 403 -> `ArmForbidden`
   - 429 -> `ArmThrottled`
   - 5xx/network/timeout -> `ArmTransientFailure`
   - Other 200/parse results -> `Unknown`

   `Expired` is a documented Azure-side state. The Arc-enabled servers overview (`learn.microsoft.com/azure/azure-arc/servers/overview#supported-cloud-operations`) states that a machine that remains disconnected for 45 days "might change to **Expired**," and Connected Machine agent release notes v1.32 (July 2023) explicitly note that the Azure portal and API report `Expired` for these machines. The implementation must still pin the classifier to a lab-captured Azure-side response from a real Expired machine in each MVP cloud before Enforce, because the exact JSON shape (whether the signal appears as `properties.status == "Expired"`, a nested `errorDetails`/`detectedProperties` field, or a Resource Graph-only projection) is not currently documented in the public REST reference and is the failure surface most likely to produce destructive false positives. If the lab-captured signal is unavailable for a cloud, Expired remediation is disabled there and the outcome is `NeedsHuman` or `AzureMachineError`.
7. Consume `Remediation=ResetBreaker` only when ARM is reachable and mode permits tag writes.
8. Exit on local breaker or `Remediation=Paused` tag.
9. Run probes:
   - `azcmagent check` for Arc network readiness.
   - Arc service state check, including Azure Arc Proxy when installed or when Arc Gateway is configured.
   - Agent certificate status (best effort). If `azcmagent show -j` exposes certificate metadata, include it. If not, set `ProbeCertificate` to null. Do not attempt to read HIMDS internal certificate stores directly; those are implementation details and vary by agent version.
   - Time sync status.
   - Agent version support window check.
   - Existing Arc connectivity settings needed for reconnect, including proxy, private link scope, and Arc Gateway only when the cloud profile supports Arc Gateway.
   - Kill-switch and Logs Ingestion endpoint checks.
10. Act by classified state and mode.
11. Write state, local log, and best-effort LAW row.
12. Release mutex and exit with outcome-appropriate code.

## 8. Remediation policy

### 8.1 Observe mode

Observe mode is non-mutating. It must not restart services, PATCH tags, disconnect, connect, delete resources, or clear breakers. It records what would have happened.

Observe mode may update local last-run metadata and write logs, but it must not increment destructive failure counters, trip breakers, set cooldowns, or write an Expired attempt marker.

### 8.2 Connected

No remediation. Reset consecutive remediation failures to 0 only when the server is verified Connected.

### 8.3 Disconnected

Disconnected is not a destructive state. Official Arc behavior is that a machine returns to Connected when heartbeats resume.

Allowed in Enforce mode:

1. Restart stopped Arc services (`himds`, `GCArcService`, `ExtensionService`, and Azure Arc Proxy when installed or gateway-configured).
2. Run `azcmagent check` and capture proxy/private-link/network failures.
3. Wait briefly and re-query local/ARM state.
4. If still Disconnected, log `ConnectivityBlocked` or `NeedsHuman`.

Not allowed in MVP for Disconnected:

- `azcmagent disconnect --force-local-only` followed by connect.
- Delete/rejoin.
- Treating ARM transient failures as Disconnected or Expired.

A specific Disconnected variant is the **cloned-machine 429** pattern: multiple servers sharing one Arc resource ID after a VM was cloned post-onboarding. The Microsoft-documented fix is `azcmagent disconnect --force-local-only` followed by `azcmagent connect` with a unique resource name — the same destructive sequence MVP forbids for ordinary Disconnected. MVP does not auto-detect cloning or 429 throttling, so cloned hosts fall through to `ConnectivityBlocked` / `NeedsHuman`. The `ProbeAzcmagentCheck` output may surface the 429; operators apply the Microsoft fix manually. Accepted limitation for v1.

### 8.4 Expired

Delete/rejoin is allowed only when Expired is confirmed by an implementation-validated Azure-side Expired evidence path. A local `azcmagent show -j` Expired signal is useful for diagnostics but is not sufficient to unlock destructive remediation. If ARM is unreachable, forbidden, throttled, transiently failing, returns `properties.status == Error` without the validated Expired evidence, or returns anything ambiguous, the run must not delete or reconnect.

MVP must fail closed for Azure Local or other cluster-backed hosts. If `azcmagent show`, ARM metadata, Resource Graph, or any other supported source exposes Azure Local evidence such as a cluster resource ID, host type, extended location, or parent resource relationship, the run logs `NeedsHuman` and never deletes the machine resource. Operators must still exclude Azure Local Arc-enabled VMs from remediator scope via `ScopedResourceGroups` or tag them with `Remediation=Paused`. If Azure Local support is required after explicit validation, the spec must be updated with documented safe delete semantics.

Before delete/rejoin:

- Kill switch must be enabled.
- Mode must be `Enforce`.
- Cooldown must be inactive.
- Breaker must not be tripped.
- Cloud profile must be validated.
- Azure Local / cluster-backed evidence must be absent.
- Subscription and resource group must match the configured scope.
- Current tags, ETag, location, and resource name must be read from ARM immediately before action.
- Existing connectivity settings required for reconnect must be known: proxy, private link scope, Arc Gateway when supported, and cloud. If the current machine uses private link or supported gateway and the required IDs cannot be determined from local config or remediator config, log `NeedsHuman` rather than reconnecting through public defaults. In DoD/IL5, Arc Gateway is unsupported and a non-null gateway config is a config mismatch.
- Automatic agent upgrade may be enabled during reconnect only when the cloud profile supports it; it is unsupported for DoD/IL5.
- A durable Expired attempt marker must be written before the first destructive call. The 7-day cooldown starts at marker write, not at successful completion.

The recovery sequence uses ARM as the only cloud deletion path:

1. Re-read ARM state, tags, location, resource name, and relevant connectivity settings.
2. Abort unless Azure-side Expired evidence is still confirmed by the validated classifier.
3. Write `LastExpiredAttemptStartedUtc`, attempt ID, and intended resource ID to local state.
4. ARM DELETE the `Microsoft.HybridCompute/machines` resource. A `204 No Content` is terminal success. If the response is `202 Accepted`, poll the `Azure-AsyncOperation` or `Location` header until the operation reaches a terminal state (`Succeeded` or `Failed`), honoring `Retry-After` when present and using bounded exponential backoff when absent. The default delete timeout is 30 minutes and is configurable. Only after the async operation succeeds, verify with ARM GET that the resource returns 404.
5. Run `azcmagent disconnect --force-local-only` to clear local agent state after the cloud resource is gone. Never run `azcmagent disconnect` without `--force-local-only` in MVP.
6. Reconnect with `azcmagent connect`, preserving subscription, resource group, location, cloud, resource name, proxy/private-link/gateway settings, and enabling automatic agent upgrade only when configured and supported. Prefer `--service-principal-cert-thumbprint` for certificate credentials in the Windows certificate store. Use a secret-safe `--config` file only for client-secret or file-certificate flows that require it; do not export private key material unless explicitly configured and cleaned up.
7. Restore tags with an ARM tag PATCH after the resource is recreated, using ETag/`If-Match` when available. Do not rely on `azcmagent connect --tags` for complete tag restoration because comma-delimited tag encoding is brittle for arbitrary tag names and values.
8. Verify the recreated ARM resource, resource identity, and restored tags.
9. Mark the attempt completed with final outcome.

The SP secret or certificate private key material must not appear in process arguments, thrown exceptions, local logs, or LAW rows.

Delete/rejoin has known side effects. Even when the same subscription/resource group/name/location are reused, the managed identity principal and certificate are recreated, Arc extension child resources or queued extension operations may be lost, and services such as Azure Policy machine configuration, Defender for Cloud, Update Manager, Azure Monitor/VM Insights, and SQL Server enabled by Azure Arc may need policy redeployment or time to reassociate. The runbook must document these effects before Enforce rollout.

### 8.5 ResourceNotFound

A 404 is not Expired. It may indicate wrong config, deleted resource, wrong subscription/RG, or stale local agent metadata. MVP logs `ResourceNotFound` / `NeedsHuman` and does not recreate automatically. Operators may choose the Microsoft-documented `azcmagent disconnect --force-local-only` plus reconnect path manually when the Azure resource was intentionally deleted.

## 9. Safety controls

| Layer | Mechanism |
|---|---|
| Fleet pause | SAS-read kill switch. Unreachable or not `enabled` means paused. |
| Per-machine pause | `Remediation=Paused` tag. |
| Observe mode | Non-mutating dry run. |
| Cooldown | No more than one Expired delete/rejoin attempt per 7 days. Starts before the first destructive call. |
| Circuit breaker | Trips after `CircuitBreakerFailureThreshold` consecutive primary failures after state load. Default threshold is 3. Failure-counting outcomes are `AuthFailure`, `ConfigMismatch`, `ArmForbidden`, `AzureMachineError`, `ExpiredRejoinFailure`, and `Error`; paused, connectivity-blocked, human-needed, resource-not-found, throttled, and transient outcomes do not increment the breaker. |
| Cloud gates | Commercial and DoD/IL5 validate independently before Enforce. |
| Destructive gate | Delete/rejoin only for Azure-side confirmed Expired using the validated evidence path. |
| Secret hygiene | No SP secret, certificate private key material, or SAS query string in command lines or logs. |

The breaker does not protect against failures that occur before config/state load. The docs and runbook must not claim otherwise.

## 10. Telemetry

### 10.1 Log availability

Local log is authoritative for runs after config load. LAW rows are best effort and require a Monitor token plus reachable ingestion endpoint. Fleet-paused-before-auth and auth failures may not reach LAW; absence-of-heartbeat queries remain important.

Before config load, a bootstrap path writes to a fixed location `%ProgramData%\ArcRemediator\logs\arc-remediator-YYYYMMDD.log` using the same rolling rules. This ensures pre-config-load failures (DPAPI error, file-permission error, missing config, parse failure) still leave a local trace. The local logger's `-Directory` parameter defaults to this path so callers in the top-level failure handler can write without prior config knowledge.

### 10.2 Table: `ArcRemediation_CL`

One row per completed scheduled run when ingestion is available.

| Column | Type | Description |
|---|---|---|
| `TimeGenerated` | datetime | Set by the DCR transform from `EventTimeUtc`. |
| `EventTimeUtc` | datetime | Script start time. |
| `Hostname` | string | Local hostname. |
| `Fqdn` | string | Best-effort FQDN. |
| `CloudProfile` | string | `Commercial` or `AzureGovernmentDoD`. |
| `SubscriptionId` | string | Subscription from config/local resource. |
| `ResourceGroup` | string | Actual Arc resource group when known. |
| `Region` | string | Arc resource location when known. |
| `AzureResourceId` | string | Full ARM resource ID when known. |
| `AgentVersion` | string | Connected Machine agent version. |
| `ScriptVersion` | string | Remediator version. |
| `ScriptMode` | string | `Observe` or `Enforce`. |
| `RunDurationMs` | int | Runtime duration. |
| `Outcome` | string | See outcome list below. |
| `OutcomeDetail` | string | One-line detail. |
| `AzureSideState` | string | Connected, Disconnected, Expired, ResourceNotFound, Unknown, etc. |
| `AgentReportedState` | string | Local agent state. |
| `ActionsAttempted` | dynamic | Array. |
| `ActionsSuccessful` | dynamic | Array. |
| `ProbeAzcmagentCheck` | dynamic | Parsed `azcmagent check` result or raw summary. |
| `ProbeServices` | dynamic | Service states and whether repair was attempted. |
| `ProbeCertificate` | dynamic | Source, expiry, days remaining. |
| `ProbeTimeSync` | dynamic | Skew and Windows Time state. |
| `ProbeAgentVersion` | dynamic | Current, supported floor, supported boolean. |
| `ConsecutiveFailures` | int | Post-run value. |
| `BreakerTripped` | bool | Post-run value. |
| `LastRemediationUtc` | datetime | From state. |
| `ErrorMessage` | string | Truncated error. |
| `ErrorType` | string | Categorical. |
| `StackTraceHash` | string | Hash of local full trace. |
| `ResetByUser` | string | Populated when the breaker was reset this run. `local:<upn>` for `Reset-ArcRemediator`; `tag` for the `Remediation=ResetBreaker` tag path (origin of the tag write is not knowable from the agent). |

Outcomes include:

- `Healthy`
- `FleetPaused`
- `MachinePaused`
- `ObserveOnly`
- `ServicesRepaired`
- `ConnectivityBlocked`
- `NeedsHuman`
- `CooldownSkipped`
- `BreakerTripped`
- `ExpiredRejoinSuccess`
- `ExpiredRejoinFailure`
- `ResourceNotFound`
- `AuthFailure`
- `ConfigMismatch`
- `AzureMachineError`
- `ArmForbidden`
- `ArmThrottled`
- `ArmTransientFailure`
- `LogIngestionFailure` (secondary status; not a reason to retry an otherwise successful run)
- `Error`

## 11. Azure setup, validation, and rollout

### 11.1 Setup script requirements

`Setup-AzureSide.ps1` must be idempotent and complete for both MVP clouds:

1. Verify the current Az context matches the requested cloud (`AzureCloud` or `AzureUSGovernment`).
2. Verify and register if missing: `Microsoft.HybridCompute`, `Microsoft.HybridConnectivity`, `Microsoft.GuestConfiguration`, `Microsoft.Insights`, `Microsoft.OperationalInsights`, `Microsoft.Storage`, and `Microsoft.AzureArcData` when SQL Server enabled by Azure Arc is in scope. If a required provider is missing and the setup identity cannot register it, setup fails.
3. Verify setup operator prerequisites: ability to create app registrations or use pre-created app registrations, and Owner/User Access Administrator equivalent permissions for role assignment on the target scopes.
4. Create/reuse dedicated scoped Arc remediation SPs and Logs Ingestion SPs, and always emit or rotate usable certificate credentials by default, or short-lived secrets only when explicitly requested.
5. Assign Arc RBAC roles on named Arc RGs.
6. Create/reuse Storage + kill-switch blob + stored access policy + SAS.
7. Create/reuse LAW and `ArcRemediation_CL`.
8. Create/reuse direct-ingestion DCR with stream declaration `Custom-ArcRemediation`, a transform that projects `TimeGenerated = EventTimeUtc` and maps dynamic columns to the table schema, `outputStream = Custom-ArcRemediation_CL`, destination, immutable ID, and logs ingestion endpoint. If an existing DCR has neither `properties.endpoints.logsIngestion` nor an existing valid DCE association, create a replacement DCR by default or fail when replacement is disabled.
9. Create optional DCE only when requested for private-link/network policy or when reusing an existing DCR that is already DCE-backed.
10. Assign `Monitoring Metrics Publisher` on the DCR to the Logs Ingestion SP.
11. Emit a working cloud-specific config sample.

### 11.2 Required lab matrix per cloud

Each MVP cloud must pass independently:

| Scenario | Expected behavior |
|---|---|
| Healthy Connected | Logs Healthy; no action. |
| Kill switch paused | Local FleetPaused; no Azure auth required. |
| Observe mode with Disconnected | Logs would-repair; no mutation. |
| Enforce mode with stopped Arc services | Restarts services; rechecks state. |
| Persistent Disconnected | Logs ConnectivityBlocked/NeedsHuman; no disconnect/reconnect. |
| Confirmed Expired | Performs delete/rejoin only after a real Azure-side Expired evidence path has been validated for that cloud and all gates pass. |
| ARM 404 | Logs ResourceNotFound; no rejoin. |
| ARM 403 | Logs ArmForbidden; no rejoin. |
| ARM 429 | Logs ArmThrottled; no rejoin. |
| ARM 5xx/timeout | Logs ArmTransientFailure; no rejoin. |
| ARM machine status Error without validated Expired evidence | Logs AzureMachineError/NeedsHuman; no rejoin. |
| Bad credential / secret / certificate | Local AuthFailure; no destructive action. |
| Logs ingestion unavailable | Run continues; local LogIngestionFailure. |
| Wrong cloud profile | Fail closed; no remediation. |
| Local resource outside configured scope | Logs ConfigMismatch/NeedsHuman before Azure auth; no remediation. |
| Expired crash/retry | Cooldown marker prevents repeated destructive attempts. |
| Expired with private link/proxy/supported gateway | Reconnect preserves required connectivity settings or logs NeedsHuman. |
| DoD/IL5 config with Arc Gateway or automatic upgrade enabled | Fails validation or ignores unsupported automatic-upgrade flag; never passes unsupported flags to `azcmagent`. |

### 11.3 Canary rollout

Commercial and DoD/IL5 have separate promotion tracks:

1. Lab validation.
2. 5-10 hosts Observe.
3. Same hosts Enforce.
4. 5% cloud-specific fleet.
5. 25% -> 50% -> 100% only after clean telemetry.

Commercial success must not promote DoD/IL5 automatically.

## 12. Packaging and operations

The ZIP package includes the module, bootstrap scripts, README, and cloud-specific config samples:

```text
ArcRemediator-1.0.0.zip
├─ ArcRemediator\
├─ Bootstrap\
│  ├─ Install.ps1
│  └─ Uninstall.ps1
├─ config.commercial.sample.json
├─ config.usgovdod.sample.json
└─ README.md
```

The operator runbook must include separate Commercial and DoD/IL5 setup commands, including `Connect-AzAccount -Environment AzureUSGovernment` for DoD/IL5.

## 13. Future work

- Air-gapped cloud support after enclave-specific validation.
- Linux support.
- Certificate-based or per-machine auth.
- Signed code and AppLocker/WDAC support.
- Optional operator-approved resource recreation for `ResourceNotFound`.
- Automatic replay of locally logged rows after ingestion outage.
- Bicep equivalent for Azure setup.
