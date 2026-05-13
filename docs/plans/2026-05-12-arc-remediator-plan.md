# Arc Remediator Implementation Plan

This plan implements the revised design in `docs/specs/2026-05-12-arc-remediator-design.md`. It intentionally removes earlier unsupported cloud assumptions, unsupported Disconnected reconnect behavior, manual Arc endpoint HEAD probes, and ARM 404 == Expired classification.

## MVP boundaries

MVP supports exactly two cloud profiles:

1. `Commercial`
2. `AzureGovernmentDoD`

Both are release-blocking. Commercial validation does not qualify DoD/IL5. Air-gapped support is future work.

## Core design decisions to preserve during implementation

- Disconnected machines are handled with non-destructive repair only: service restart in Enforce mode, `azcmagent check`, re-query, then `ConnectivityBlocked` or `NeedsHuman` if still disconnected.
- Delete/rejoin is allowed only for confirmed Expired from a validated Azure-side evidence path. Do not assume ARM `properties.status == Expired`; the classifier must be pinned to a real Expired machine response in each MVP cloud before Enforce.
- ARM 404 is `ResourceNotFound`, not Expired.
- ARM 403, 429, 5xx, DNS, timeout, and parsing failures are separate outcomes and never trigger destructive remediation.
- `azcmagent check` is the primary Arc network probe.
- ARM and Monitor use separate tokens and audiences.
- Logs Ingestion uses the DCR logs ingestion endpoint by default. DCE is optional for private-link/network-policy requirements or for existing DCRs that are already DCE-backed.
- The DCR maps stream `Custom-ArcRemediation` to output stream `Custom-ArcRemediation_CL`.
- Service principal secrets must not appear in process arguments, exceptions, local logs, or LAW rows.
- Production credentials are certificate-based where possible and segmented by cloud/resource group/ring; no all-fleet broad secret. Arc remediation and Logs Ingestion identities are separate in production unless explicitly risk-accepted for canary.
- Expired delete/rejoin writes a durable attempt marker before the first destructive call.
- Expired reconnect preserves proxy, private link scope, supported Arc Gateway, resource name, location, cloud, and tags, or logs `NeedsHuman`.
- Cloud profile capability flags gate preview/unsupported features: Arc Gateway and automatic agent upgrade are commercial-only for MVP and must not be used in DoD/IL5.
- Task Scheduler retries are disabled; the remediator owns retry/backoff so ARM throttling is not amplified across the fleet.
- Observe mode is non-mutating.
- PowerShell 5.1 compatibility is required unless the spec is explicitly changed to require PowerShell 7.

## File structure

```text
automated_health_remediation_arc/
├─ docs/
│  ├─ specs/2026-05-12-arc-remediator-design.md
│  ├─ plans/2026-05-12-arc-remediator-plan.md
│  └─ ops-runbook.md
├─ src/ArcRemediator/
│  ├─ ArcRemediator.psd1
│  ├─ ArcRemediator.psm1
│  ├─ Public/
│  │  ├─ Invoke-ArcRemediation.ps1
│  │  ├─ Test-ArcRemediator.ps1
│  │  └─ Reset-ArcRemediator.ps1
│  ├─ Private/
│  │  ├─ Get-CloudProfile.ps1
│  │  ├─ Get-AzureToken.ps1
│  │  ├─ Invoke-Azcmagent.ps1
│  │  ├─ Invoke-AzcmagentCheck.ps1
│  │  ├─ Get-KillSwitchState.ps1
│  │  ├─ Get-AzureResourceState.ps1
│  │  ├─ Set-AzureResourceTags.ps1
│  │  ├─ Remove-AzureResource.ps1
│  │  ├─ Send-LogAnalytics.ps1
│  │  ├─ Test-AgentServices.ps1
│  │  ├─ Repair-AgentServices.ps1
│  │  ├─ Test-AgentCertificate.ps1
│  │  ├─ Test-TimeSync.ps1
│  │  ├─ Test-AgentVersion.ps1
│  │  ├─ Invoke-ExpiredRejoin.ps1
│  │  ├─ Get-ArcConnectivitySettings.ps1
│  │  ├─ New-RemediatorRow.ps1
│  │  ├─ Get-DecryptedConfig.ps1
│  │  ├─ Set-EncryptedConfig.ps1
│  │  ├─ Get-RemediatorState.ps1
│  │  ├─ Set-RemediatorState.ps1
│  │  └─ Write-LocalLog.ps1
│  ├─ Data/
│  │  ├─ cloud-profiles.psd1
│  │  └─ version.txt
│  └─ Bootstrap/
│     ├─ Install.ps1
│     └─ Uninstall.ps1
├─ azure-setup/
│  └─ Setup-AzureSide.ps1
├─ package/
│  ├─ build.ps1
│  ├─ config.commercial.sample.json
│  └─ config.usgovdod.sample.json
├─ workbook/
│  └─ arc-remediator-workbook.json
└─ tests/
   ├─ unit/
   └─ integration/
```

## Phase 1 — Scaffolding and compatibility

### Task 1: Repo/module scaffolding

Create `.gitignore`, module manifest, module loader, version file, Pester configuration, and module smoke tests.

Acceptance criteria:

- Module imports on Windows PowerShell 5.1.
- No PowerShell 7-only syntax (`??`, ternary `? :`, null-conditional operators) is used.
- Tests fail fast on syntax incompatible with PowerShell 5.1.
- A CI/test step runs `Invoke-ScriptAnalyzer -Path src/ -EnableExit -Severity Warning` and fails on warnings or errors.
- A second pass parses every `.ps1` file with `[System.Management.Automation.Language.Parser]::ParseFile()` under Windows PowerShell 5.1 and asserts zero parse errors. This catches PS7-only syntax that ScriptAnalyzer may miss.

### Task 1.5: TLS 1.2 enforcement helper

Add `Private/Invoke-RestMethodWithTls.ps1` exporting one wrapper function that ensures `[Net.ServicePointManager]::SecurityProtocol` includes `Tls12` (and `Tls13` when the enum value exists on the host) immediately before each `Invoke-RestMethod` call, then invokes the request and returns the response. This keeps the TLS setting scoped to the remediator's own requests rather than applied globally at module load.

Acceptance criteria:

- Function updates `SecurityProtocol` to include `Tls12` immediately before the request even when the host default is `Tls`/`Ssl3`/`Tls11`.
- Idempotent — calling twice does not throw and does not flap the setting.
- Never downgrades — if `Tls13` (or any higher protocol) is already enabled, it remains enabled.
- Test confirms the setting is updated when the wrapper is called under a synthetic starting state of `Tls`, and that the module loader does not modify global `SecurityProtocol`.

### Task 2: Local config, state, and local logs

Implement DPAPI LocalMachine config write/read, state read/write, destructive-attempt state, and local rolling logs.

Acceptance criteria:

- Config round-trips under LocalMachine DPAPI and does not contain plaintext secret on disk.
- State handles missing files but does not silently accept corrupt JSON.
- Local logs enforce daily files, 10 MB cap, and 14-day retention.
- Top-level failures after state load increment the appropriate failure counter when safe to do so.
- Observe mode does not increment destructive failure counters, trip breakers, set cooldowns, or write Expired attempt markers.
- Expired remediation writes `LastExpiredAttemptStartedUtc`, attempt ID, and intended resource ID before ARM DELETE; this marker enforces cooldown even if the process crashes.
- Circuit breaker threshold defaults to 3 consecutive primary failures after state load and uses the exact failure-counting outcomes defined in the spec.
- `Write-LocalLog` `-Directory` parameter defaults to `%ProgramData%\ArcRemediator\logs\` so callers in the pre-config-load failure handler can log without prior config knowledge.
- When called with no `-Directory`, the function creates the fallback directory if absent and logs there.
- `Invoke-ArcRemediation`'s top-level catch logs to the fallback path even if config load fails.

## Phase 2 — Cloud profiles

### Task 3: `cloud-profiles.psd1` and `Get-CloudProfile`

Implement only `Commercial` and `AzureGovernmentDoD`.

Required profile fields:

- `AzEnvironment`
- `AzcmagentCloud`
- `ArmEndpoint`
- `EntraAuthority`
- `StorageSuffix`
- `ArmTokenResource`
- `MonitorTokenScope`
- `ExpectedAgentCloudValues`
- `SupportsArcGateway`
- `SupportsAutomaticAgentUpgrade`

Acceptance criteria:

- Tests prove `Commercial` uses `AzureCloud`, `https://management.azure.com`, and `https://monitor.azure.com/.default`.
- Tests prove `AzureGovernmentDoD` uses `AzureUSGovernment`, `https://management.usgovcloudapi.net`, and `https://monitor.azure.us/.default`.
- Tests prove `Commercial` supports Arc Gateway and automatic agent upgrade, while `AzureGovernmentDoD` supports neither.
- Unknown profiles throw.
- No unsupported cloud profile strings exist in runtime profile data.

## Phase 3 — Azure setup

### Task 4: Complete `Setup-AzureSide.ps1`

Build an idempotent setup script for both MVP clouds.

Required behavior:

1. Verify current Az context environment matches `Commercial` or `AzureGovernmentDoD`.
2. Create/reuse infrastructure resource group.
3. Verify setup operator prerequisites: app-registration permission or pre-created app registrations, plus Owner/User Access Administrator equivalent permissions for role assignments on target scopes.
4. Create/reuse dedicated scoped Arc remediation service principal(s) and Logs Ingestion service principal(s), and create/emit usable certificate credentials by default. Short-lived client secrets are allowed only with an explicit `-UseClientSecret`/lab flag and must support rotation.
5. Assign `Azure Connected Machine Resource Administrator` and `Azure Connected Machine Onboarding` on named Arc RGs.
6. Create/reuse Storage account, private container, kill-switch blob, stored access policy, and SAS.
7. Create/reuse Log Analytics workspace.
8. Create/reuse `ArcRemediation_CL` custom table.
9. Create/reuse direct-ingestion DCR with stream declaration `Custom-ArcRemediation`, a transform that projects `TimeGenerated = EventTimeUtc` and maps dynamic columns to `ArcRemediation_CL`, `outputStream = Custom-ArcRemediation_CL`, destination mapping, immutable ID, and logs ingestion endpoint. **New DCRs must be created with `"kind": "Direct"` and the response must include `properties.endpoints.logsIngestion`.** If a reused DCR lacks this property but already has a valid DCE association, configure the generated config to use the DCE endpoint. If it lacks both, create a replacement DCR by default or fail when replacement is disabled.
10. Create optional DCE only when `-UseDataCollectionEndpoint` is supplied or an existing DCR is already DCE-backed.
11. Assign `Monitoring Metrics Publisher` on the DCR to the Logs Ingestion SP.
12. Emit working `config.commercial.sample.json` or `config.usgovdod.sample.json`.

Acceptance criteria:

- No README placeholder is required to finish DCR creation.
- A generated config can authenticate to ARM and post a sample row to Logs Ingestion in that same cloud.
- The script fails if run against the wrong Az environment.
- The setup script handles both `Get-AzAccessToken` return shapes: pre-Az 14 / `Az.Accounts` < 5 returns `String`; Az 14+ / `Az.Accounts` 5+ returns `SecureString` by default. The setup script must accept either shape, convert `SecureString` to a plain bearer string only inside a try/finally that zeroes the unmanaged buffer (`Marshal.ZeroFreeBSTR`), and never log either form. Tested by mocking both shapes.
- Resource provider validation includes `Microsoft.HybridConnectivity` and includes `Microsoft.AzureArcData` when SQL Server enabled by Azure Arc is in scope.
- Missing required resource provider registration fails setup when the caller cannot register it.
- Generated DoD/IL5 config has no Arc Gateway ID and does not enable automatic agent upgrade.

## Phase 4 — Azure and storage primitives

### Task 5: `Get-AzureToken`

Implement client credentials token acquisition for explicit audiences.

Acceptance criteria:

- ARM token uses profile `ArmTokenResource`.
- Logs token uses profile `MonitorTokenScope`.
- Token acquisition explicitly handles ARM v1 resource requests versus Monitor v2 `/.default` scope requests; implementation must not silently reuse one token shape for both.
- Supports certificate credential flow and short-lived client-secret flow without logging credential material.
- Accepts a credential purpose (`Arc` or `Monitor`) and uses the corresponding credential block. Production samples use separate Arc and Monitor credentials.
- Tokens are not logged.
- Commercial and DoD/IL5 token tests cover both audiences.

### Task 6: `Get-KillSwitchState`

Read the SAS blob before Azure auth.

Acceptance criteria:

- Exact trimmed `enabled` means proceed.
- Anything else, including 403/404/timeout, pauses.
- Local detail records the state/error without leaking SAS query string.
- Tests confirm that when `Invoke-RestMethod` throws with the full URL in the exception message, the `LastError` field and any local log entry written by `Get-KillSwitchState` redact everything from `?` onward (i.e., do not contain `sig=`, `se=`, `sp=`, or other SAS query parameters).

### Task 7: `Get-AzureResourceState`

ARM GET must return typed classifications.

Required classifications:

- `Connected`
- `Disconnected`
- `Expired`
- `AzureMachineError`
- `ResourceNotFound`
- `ArmForbidden`
- `ArmThrottled`
- `ArmTransientFailure`
- `Unknown`

Acceptance criteria:

- `Expired` is a Microsoft-documented Azure-side state (Arc-enabled servers overview, agent release notes v1.32). However, the exact JSON shape returned by ARM GET for an Expired machine is not pinned in the public REST reference, so the classifier must be validated against a real Expired Arc machine response captured for each MVP cloud before Enforce. `properties.status == Expired` alone is not assumed or mocked as sufficient; the lab-captured fixture is the source of truth.
- 200 + `properties.status == Error` without validated Expired evidence maps to `AzureMachineError` or `Unknown`, never `Expired`.
- 404 maps to `ResourceNotFound`.
- 403/429/5xx/timeout are distinct and never return `Expired`.
- Unit tests include synthetic fixtures for Connected, Disconnected, Error, Unknown, and malformed 200 responses; integration validation captures a real Expired response per MVP cloud before Enforce is allowed.

### Task 8: Tag update helper

Implement tag updates by reading current tags, applying a minimal merge/removal, and PATCHing only the intended result.

Acceptance criteria:

- `Remediation=ResetBreaker` removal preserves unrelated tags.
- Concurrent tag changes are mitigated with ETag/`If-Match` when available. If an ETag conflict occurs, re-read and retry once; after a second conflict, return a typed tag conflict result instead of overwriting blindly.
- Tag helper is never called in Observe mode.

### Task 9: `Send-LogAnalytics`

Post rows to the DCR logs ingestion endpoint with a Monitor token.

Acceptance criteria:

- URI is `{LogIngestionEndpoint}/dataCollectionRules/{DcrImmutableId}/streams/{StreamName}?api-version=2023-01-01`.
- Authorization token is acquired for Monitor, not ARM.
- A failed POST records `LogIngestionFailure` locally and does not fail the remediation action.
- Scheduled-task exit code follows the primary remediation outcome; ingestion failure alone exits 0.

## Phase 5 — Agent wrappers and probes

### Task 10: `Invoke-Azcmagent`

Wrap `azcmagent.exe` with timeout, stdout/stderr capture, and secret-safe error handling.

Acceptance criteria:

- Error messages do not include command arguments that may contain secrets.
- Timeout kills only the child process it started.
- Tests cover nonzero exit and timeout.

### Task 11: `Invoke-AzcmagentCheck`

Use `azcmagent check` as the Arc network probe.

Acceptance criteria:

- Supports cloud/location arguments from profile and agent state.
- Captures enough structured or raw output for telemetry.
- Does not use manual HEAD probes for Arc endpoints.
- Output schema: `{ rawOutput: string, connectionType: string?, reachableUrls: string[], unreachableUrls: string[], usesProxy: bool?, usesPrivateLink: bool?, usesGateway: bool?, sawAny429: bool? }`.
- Parser uses tolerant regex against the table format, but exact table columns are not treated as a stable contract. On parse failure, `rawOutput` is preserved verbatim and the other fields are null. The run does not fail on parse failure.
- `sawAny429` is advisory only and must not override ARM state classification.
- When SQL Server enabled by Azure Arc or extension endpoint readiness is in scope, tests cover `azcmagent check --extensions sql` or `--extensions all` where supported.

### Task 11.5: Record cloned-VM 429 signal (DEFERRED — not in feat-initial)

**Status:** Deferred for MVP. Cloned VMs fall through to `ConnectivityBlocked` / `NeedsHuman` per spec §8.3. Operators apply the Microsoft-documented disconnect/reconnect-with-new-name fix manually. Revisit after Commercial canary clean.

If reintroduced, the orchestration may set `OutcomeDetail` to include the literal token `possibleClonedMachine` when `azcmagent check` output contains `429` near the ARM endpoint reachability section. This signal is advisory and must not replace ARM classifications such as `ArmThrottled` or confirmed `Expired`. The destructive Expired gate still depends on validated Azure-side Expired evidence; advisory 429 parsing never authorizes destructive action.

### Task 11.6: `Get-ArcConnectivitySettings`

Capture reconnect-affecting local configuration before any Expired remediation.

Acceptance criteria:

- Captures proxy configuration, Arc private link scope, Arc Gateway resource ID when the profile supports gateway, configured cloud, and resource name/location where available.
- If a machine uses private link or supported gateway and the required values cannot be determined, Expired remediation resolves to `NeedsHuman`.
- DoD/IL5 with a non-null Arc Gateway value is a config mismatch. DoD/IL5 automatic upgrade is unsupported and must not pass `--enable-automatic-upgrade`.
- Does not infer public connectivity defaults over an existing private-link/gateway configuration.

### Task 12: Service probe and repair split

Implement `Test-AgentServices` as read-only and `Repair-AgentServices` as mutating.

Acceptance criteria:

- Observe mode calls only `Test-AgentServices`.
- Enforce mode may call `Repair-AgentServices` for Disconnected service repair.
- Missing services produce `NeedsHuman`, not silent success.
- Azure Arc Proxy is included when installed or when gateway is configured. Missing Arc Proxy is `NeedsHuman` only when gateway is required by a supported cloud profile.

### Task 13: Certificate, time, and version probes

Implement probes compatible with Windows PowerShell 5.1.

Acceptance criteria:

- Agent version check uses a configurable supported floor chosen at implementation time from Microsoft guidance, not the stale `1.42.0` value.
- Time sync probe reports unknown rather than swallowing parsing failures.
- Certificate probe is best effort only: if `azcmagent show -j` does not expose certificate metadata, the probe returns null without error and does not attempt to read HIMDS internal stores.

## Phase 6 — Remediation primitives

### Task 14: `Invoke-ExpiredRejoin`

Implement delete/rejoin for confirmed Expired only.

Required behavior:

1. Re-read ARM state and tags immediately before action.
2. Abort unless state is still confirmed Expired by validated Azure-side evidence.
3. Prefer `--service-principal-cert-thumbprint` for certificate credentials in the Windows certificate store. Create a temporary azcmagent config file only for client-secret or file-certificate flows that require non-echoing input.
4. Write the durable Expired attempt marker before the first destructive call.
5. ARM DELETE the `Microsoft.HybridCompute/machines` resource. Treat `204 No Content` as terminal success. If the response is `202 Accepted`, poll the `Azure-AsyncOperation` or `Location` header until the operation reaches a terminal state (`Succeeded` or `Failed`), honoring `Retry-After` and using bounded exponential backoff when absent. Default timeout is 30 minutes and configurable. Only after the async operation succeeds, verify with ARM GET that the resource returns 404.
6. Run `azcmagent disconnect --force-local-only` to clear local state. Never run `azcmagent disconnect` without `--force-local-only`.
7. Reconnect with subscription, resource group, location, cloud, resource name, proxy/private-link/supported gateway settings, optional automatic-upgrade flag only when profile-supported, and auth config.
8. Restore the complete tag set with ARM PATCH using ETag/`If-Match` after the resource is recreated. Do not rely on `azcmagent connect --tags` for complete tag restoration.
9. Verify the recreated ARM resource and confirm tags were restored.
10. Mark the attempt completed and delete temporary secret material.

Acceptance criteria:

- No command line includes SP secret, certificate private key material, or other credential material.
- Function cannot be called for Disconnected or ResourceNotFound states.
- Resource name/location/RG are preserved from the confirmed resource where possible.
- Local `azcmagent show` Expired without validated Azure-side Expired evidence cannot call this function.
- Covers `202 Accepted` responses with bounded polling that honors `Retry-After`; aborts to `ExpiredRejoinFailure` if the async operation does not reach `Succeeded` within the timeout.
- A crash after the marker is written but before completion prevents another destructive attempt until cooldown/reset.
- Azure Local or cluster-backed evidence blocks the function and returns `NeedsHuman`.

## Phase 7 — Main orchestration

### Task 15: `Invoke-ArcRemediation`

Implement the runtime decision tree from the spec.

Acceptance criteria:

- Kill switch is evaluated before Azure auth.
- Separate ARM and Monitor tokens are acquired.
- Cloud profile mismatch fails closed.
- Subscription/resource group outside configured scope fails closed before Azure auth when local resource ID is available.
- Breaker reset tag is consumed only when mode permits mutation and ARM is reachable.
- Observe mode performs no mutation.
- Disconnected never calls disconnect/connect/delete.
- ResourceNotFound never calls connect/delete.
- Expired delete/rejoin requires validated Azure-side Expired evidence and all destructive gates.
- Logs ingestion failure does not convert a successful primary outcome into a scheduled-task failure.
- Outcomes map to intentional process exit codes through the scheduled-task entry point per the table in spec §6.3.
- Cloud-profile mismatch fixture: config `CloudProfile=AzureGovernmentDoD` while mocked `azcmagent show -j` reports cloud `AzureCloud`. The run fails closed: no destructive action, no token acquisition for the configured cloud's ARM resource. Assertion verifies that no ARM or Monitor token request was made for either cloud.

### Task 16: `New-RemediatorRow`

Create telemetry rows matching the spec.

Acceptance criteria:

- `Region` is actual resource/agent region, not agent version.
- `AzureResourceId` is populated when known.
- `ResourceGroup` is actual RG when known.
- FQDN lookup is best-effort and cannot crash the run.
- Error messages are truncated; full traces stay local with hash in LAW.

## Phase 8 — Installer and packaging

### Task 17: `Install.ps1`

Implement idempotent install/upgrade/config refresh.

Acceptance criteria:

- Validates OS and PowerShell 5.1 compatibility.
- `-Validate` actively tests cloud profile, ARM token, Monitor token, kill-switch read, and Logs Ingestion sample POST.
- Same code version refreshes config instead of exiting before config update.
- Scheduled task translates outcomes to process exit codes.
- Scheduled task does not configure task-level retries; throttling/transient retry behavior is internal to the remediator.
- Scheduled task does not require Windows "network available" status; diagnostics must run even when NLA is wrong or connectivity is degraded.
- ACLs match spec.

### Task 18: `Uninstall.ps1`

Remove scheduled task and install path; preserve data path by default.

### Task 19: `build.ps1`

Build ZIP with module, bootstrap scripts, README, and both cloud config samples.

## Phase 9 — Operator tools and docs

### Task 20: `Test-ArcRemediator`

Operator diagnostic that runs non-mutating probes only.

Acceptance criteria:

- No service repair, tag write, connect, disconnect, or delete.
- Can target Commercial or AzureGovernmentDoD profile.

### Task 21: `Reset-ArcRemediator`

Local breaker reset helper.

Acceptance criteria:

- Uses ShouldProcess/Confirm.
- Records local audit with best-effort user identity.
- Does not claim LAW logging if Monitor auth is unavailable.

### Task 22: README and runbook

Write operator-facing docs.

Required content:

- Separate Commercial and DoD/IL5 setup paths.
- `Connect-AzAccount -Environment AzureUSGovernment` for DoD/IL5 setup.
- Kill switch operations without requiring anonymous blob access.
- Clear warning that Commercial validation does not qualify DoD/IL5.
- `ResourceNotFound` requires operator decision.
- Azure Government endpoint/service-tag requirements, including `pasff.usgovcloudapi.net`, `*.his.arc.azure.us`, `*.guestconfiguration.azure.us`, `*.blob.core.usgovcloudapi.net`, and current AzureArcInfrastructure service-tag guidance.
- Current Azure Arc network guidance for both clouds, including the `AzureFrontDoor.Frontend` service tag (required as of April 2026 per `learn.microsoft.com/azure/azure-arc/network-requirements-consolidated#azure-arc-enabled-servers` — Service tags section), the Azure Government requirement (since October 28, 2025) to also allow the public-cloud `AzureArcInfrastructure` service-tag ranges in addition to the Azure Government one, the remediator Storage SAS endpoint, and the DCR or DCE Logs Ingestion endpoint.
- Expired delete/rejoin side effects: managed identity recreation, extension/resource redeployment, policy reassignment delay, Defender/Update Manager/SQL Arc reassociation, and telemetry/resource-history caveats.
- Credential blast-radius guidance and approved segmentation model for production.
- Setup operator prerequisites for app registration and role assignment, plus guidance for pre-created app registrations when tenant policy blocks app creation.

### Task 23: Workbook

Create workbook tiles for:

- Silent servers.
- Outcomes by cloud profile.
- ConnectivityBlocked/NeedsHuman.
- ResourceNotFound.
- ArmForbidden/ArmThrottled/ArmTransientFailure.
- Expired rejoin attempts.
- Breakers.
- Version drift.
- Observe mode hosts.

## Phase 10 — Tests and validation

### Task 24: Unit test coverage

Every helper and public command has Pester tests. Tests must include Commercial and AzureGovernmentDoD cloud profiles.

### Task 25: Integration lab matrix per cloud

Run the required matrix in the spec for each MVP cloud:

- Healthy Connected.
- Kill switch paused.
- Observe Disconnected.
- Enforce stopped services.
- Persistent Disconnected.
- Confirmed Expired with real Azure-side Expired evidence captured for that MVP cloud.
- ARM machine status Error without validated Expired evidence.
- ARM 404.
- ARM 403.
- ARM 429.
- ARM 5xx/timeout.
- Bad credential / secret / certificate.
- Logs ingestion failure.
- Wrong cloud profile.
- Local resource outside configured scope.
- Expired crash/retry after attempt marker.
- Expired with proxy/private-link/supported gateway settings.
- DoD/IL5 config with unsupported Arc Gateway and automatic-upgrade settings.
- Logs ingestion failure after otherwise successful run.

### Task 26: Canary rollout gates

Commercial and DoD/IL5 must promote independently:

1. Lab pass.
2. 5-10 hosts Observe.
3. Same hosts Enforce.
4. 5% fleet.
5. 25% -> 50% -> 100%.

Do not start DoD/IL5 Enforce based solely on Commercial success.

## Explicit removals from the previous plan

- Remove unsupported cloud tests, config, and endpoint rows.
- Remove guessed unsupported cloud endpoints.
- Remove Disconnected `disconnect --force-local-only` + `connect --resource-id` remediation.
- Remove manual Arc endpoint HEAD probing as the primary network probe.
- Remove fixed minimum agent version `1.42.0`.
- Remove reuse of ARM token for Logs Ingestion.
- Remove DCR creation placeholders.
- Remove claims that every run reaches LAW.
- Remove blast-radius language that says a bad config is bounded to three days.
- Remove local `azcmagent show` Expired as a destructive gate without Azure-side confirmation.
- Remove ARM `properties.status == Expired` as an assumed destructive gate without real Expired evidence validation.
- Remove all-fleet broad service-principal secret as an acceptable production default.
- Remove scheduled-task dependency on Windows network-available status.
- Remove task-level retries that can amplify fleet-wide ARM throttling.
