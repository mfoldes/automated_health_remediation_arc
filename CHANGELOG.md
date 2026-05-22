# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/).

## [Unreleased]

### Added

- **`Remediation=Paused` per-host tag gate implemented** (previously documented but not
  enforced). `Invoke-OrchestratorDispatch` now checks the Arc resource tag
  `Remediation=Paused` (case-sensitive) before running any probes or taking any
  action. Returns `OutcomeString='MachinePaused'` immediately, which maps to
  exit code 0 via `ConvertTo-RemediatorExitCode`. Property iteration uses an
  explicit `foreach` over `PSObject.Properties` (not `.Properties.Name`) to avoid
  a `Set-StrictMode -Version 3.0` failure on an empty `PSCustomObject` tag bag.
  New tests in `tests/unit/OrchestratorDispatch.Tests.ps1` cover: Paused tag →
  MachinePaused (no probes called), wrong case → not triggered, empty tag bag →
  not triggered.

- **Agent certificate NearExpiry/Expired escalates to NeedsHuman.** In the
  Disconnected branch of `Invoke-OrchestratorDispatch`, if
  `Get-AgentCertificateProbe` returns `Status='Expired'` or `Status='NearExpiry'`
  the outcome is forced to `NeedsHuman` with a detail message that includes
  `DaysUntilExpiry`. A service-restart cannot heal an expired agent cert; this
  prevents futile reconnect attempts and surfaces the host for operator action.
  Honored in both Observe and Enforce modes. Tests added for both cert states.

- **Reconnect-only short cooldown for mid-rejoin failures.** After a failed Expired
  rejoin where the ARM DELETE succeeded but a later step failed (`ConnectFailed`,
  `TagsNotRestored`, or `VerificationFailed`), the next attempt is allowed after a
  configurable window (new config key `ReconnectOnlyCooldownHours`, default 24 h)
  instead of the flat 7-day cooldown. Recognized outcomes map exactly to what
  `Complete-Marker` writes. `DeleteFailed` still earns the full 7-day cooldown
  (the ARM resource is intact; a new attempt is destructive). Tests: within-24h
  ConnectFailed → CooldownSkipped; outside-6h ConnectFailed with 6-h config →
  retry proceeds; `Set-StrictMode -Version 3.0`-safe property checks throughout.

- **Skip-DELETE recovery for mid-rejoin crash.** `Invoke-ExpiredRejoin` now
  detects `Classification='ResourceNotFound'` on the pre-destructive ARM re-read.
  When the resource is already gone (a prior run deleted it but crashed before
  the connect step), the function skips `Remove-ArcResource` and
  `Invoke-AzcmagentDisconnect`, writes the InProgress marker, and resumes from
  `Invoke-AzcmagentConnect`. The synthesized `$deleteResult` carries
  `Skipped=$true` and a `SkipReason`. WhatIf action text is differentiated for
  the skip-delete path. Tests confirm: Remove-ArcResource not called, Disconnect
  not called, Connect called once, marker written, state file outcome = Completed.

- **`ReconnectOnlyCooldownHours` config key** added to `$knownKeys` in
  `Test-ConfigSchema.ps1`. Setting it in the config overrides the default 24-hour
  reconnect-only cooldown. Any positive integer value in hours is valid.

- **Bicep alert modules** in `azure-setup/bicep/modules/`:
  - `killswitch-alert.bicep`: enables `StorageBlobLogs` diagnostic settings on
    the kill-switch storage account blob service (→ LAW) and creates a Scheduled
    Query Rule (severity=Critical) that fires within 10 minutes of any successful
    write to the kill-switch blob. Partially mitigates STRIDE finding R6.
  - `alerts.bicep`: four Scheduled Query Rules over `ArcRemediation_CL`:
    - `arc-remediator-expired-rejoin-failure` (severity=Error, 15-min evaluation)
    - `arc-remediator-needs-human` (severity=Warning, hourly evaluation)
    - `arc-remediator-silent-servers` (severity=Warning, 2-h evaluation; threshold
      38 h = 36 h + 2 h buffer)
    - `arc-remediator-breaker-tripped` (severity=Error, hourly evaluation)
  - Both modules are wired into `main.bicep` behind `alertsEnabled` and
    `alertActionGroupIds` parameters (both default to off/empty; no breaking change).

### Changed

- GitHub Actions CI (`.github/workflows/ci.yml`) with three jobs on
  `windows-latest`:
  - `static`: Parser sweep + PSScriptAnalyzer on Windows PowerShell 5.1
    (the module's target runtime). This is the gate that prevents
    PS 7-only syntax from leaking into the source.
  - `pester`: Pester 5 on PowerShell 7.
  - `pester51`: Pester 5 on Windows PowerShell 5.1 Desktop — validates
    the actual deployment target (Arc-enabled Windows servers ship PS 5.1).
- `SECURITY.md` with the project's vulnerability-reporting policy.
- `CHANGELOG.md` (this file) and `tests/unit/Changelog.Tests.ps1`
  asserting structure and version alignment with the module manifest.
- **Orchestrator dispatch extracted to `Invoke-OrchestratorDispatch`** (Gap 14):
  The 140-line action-dispatch switch (probes + classification branch + breaker
  accounting, formerly lines 243-381 of `Invoke-ArcRemediation.ps1`) has been
  extracted into a dedicated private helper
  `src/ArcRemediator/Private/Invoke-OrchestratorDispatch.ps1`.
  `Invoke-ArcRemediation` now delegates phases 7 and 8 to this helper and unpacks
  the result. Behavior is identical; existing `InModuleScope` mocks continue to
  work. New unit tests in `tests/unit/OrchestratorDispatch.Tests.ps1` cover
  Connected→Healthy, Disconnected+Observe→ObserveOnly, and
  Expired+MaxRuntimeMinutes=0→Aborted.
- **`New-RemediatorRow` Context parameter set** (Gap 15):
  `New-RemediatorRow` now accepts a `[hashtable]$Context` parameter set as an
  alternative to the original 23-parameter explicit call. The function unpacks the
  hashtable via an allowlisted `foreach`; existing callers are unaffected
  (`DefaultParameterSetName='Explicit'`). The orchestrator can pass its run-context
  hashtable directly after the Gap 14 refactor lands.
- **Bicep Phase 1 infrastructure template** (Gap 11):
  New `azure-setup/bicep/main.bicep` declares Storage account, private container,
  Log Analytics workspace + `ArcRemediation_CL` custom table, optional DCE, and
  DCR (kind:Direct) with `transformKql`. Cloud-specific parameter files for
  Commercial and DoD are included. `Setup-AzureSide.ps1` gains a
  `-DeploymentMode Bicep` parameter that runs `az deployment group create` for
  steps 6-9 instead of the imperative Az PowerShell path. The imperative path
  remains the default until lab parity is confirmed.
- **ARM Expired fixture files** (Gap 16):
  `tests/fixtures/arm-expired-commercial.json` and `tests/fixtures/arm-expired-dod.json`
  capture realistic ARM GET shapes for Expired `Microsoft.HybridCompute/machines`
  resources in AzureCloud and AzureUSGovernment respectively. Gold-fixture tests in
  `tests/unit/Get-AzureResourceState.Tests.ps1` assert the classifier returns
  `Classification='Expired'` for both fixtures.
- **Bicep structure tests** in `azure-setup/tests/Bicep.WhatIf.Tests.ps1`: validate
  required parameters, expected resource types, column schema, and TLS/security
  properties without a live Azure connection. A live what-if context exists but is
  skipped unless `$env:ARC_BICEP_WHATIF_RG` and `$env:ARC_BICEP_WHATIF_SUB` are set.


  entering the destructive Expired-rejoin path, the orchestrator now checks
  `$sw.Elapsed.TotalMinutes` against a configurable `MaxRuntimeMinutes`
  (config-file key, default 45 min). If the deadline has passed, the run
  returns `Outcome='Aborted'` with `OutcomeDetail` starting with
  `SelfDeadlineHit:`. No cooldown marker is written; the next scheduled
  invocation will retry normally. This prevents Task Scheduler from killing
  the process mid-rejoin when the `ExecutionTimeLimit` (1 hr) is reached.
- **`SchemaVersion` column in `ArcRemediation_CL` LAW table** (Gap 6):
  `azure-setup/private/New-LawAndTable.ps1` now declares `SchemaVersion`
  (type `string`) immediately after `EventTimeUtc`. New rows have
  `SchemaVersion = '1'`; historical rows will have `$null`. KQL workbook
  queries can filter `SchemaVersion == '1'` to gate on the current schema.
  The DCR `transformKql` (`source | extend TimeGenerated = EventTimeUtc`)
  passes `SchemaVersion` through untouched — no DCR change required.
- **`SchemaVersion` in local `state.json`** (Gap 7):
  `New-DefaultRemediatorState` now includes `SchemaVersion = 1` as the
  first property. `Get-RemediatorState` upcasts legacy state files that
  predate versioning: a missing `SchemaVersion` is treated as `0` and
  stamped to `1` on next read. No data is lost; the upcast is additive.

### Changed

- `ArcRemediator.psd1` now has populated `Author`, `CompanyName`, `Copyright`,
  `ProjectUri`, `ReleaseNotes`, and `Prerelease = 'preview'` metadata.
- `ArcRemediator.psd1` `FunctionsToExport` now includes `Test-ArcInstallation`,
  promoting it from a Bootstrap dot-sourced script to a first-class exported
  Public function discoverable via `Get-Command` and `Get-Help`.
- `Test-ArcInstallation.ps1` moved from `src/ArcRemediator/Bootstrap/` to
  `src/ArcRemediator/Public/`. Callers that previously had to dot-source
  `Bootstrap\Test-ArcInstallation.ps1` should now use
  `Import-Module ArcRemediator; Test-ArcInstallation` instead.
- `Bootstrap/Install.ps1` `-Validate` path now imports the freshly-installed
  module (via `Import-Module $installedManifest -Force`) instead of dot-sourcing
  the Bootstrap copy of `Test-ArcInstallation.ps1`.
- `README.md` no longer claims a `tests/integration/` tree (none exists in
  this preview) and no longer quotes a specific Pester test count.
- Internal helper rename for PSScriptAnalyzer `PSUseApprovedVerbs` compliance:
  `Build-Row` → `Resolve-RemediationRow` (private to `Invoke-ArcRemediation.ps1`);
  `Build-ServiceRow` → `ConvertTo-AgentServiceRow` (private to `Test-AgentServices.ps1`).
  Both functions were file-local; no public surface is affected.
- `azure-setup/tests/AzStubs.ps1`: Removed conditional guards so stubs are
  always defined, shadowing any installed Az module cmdlets. This prevents
  Pester from binding mock parameters against the real cmdlets' strongly-typed
  signatures (e.g. `[guid]$ApplicationId`, `[IStorageContext]$Context`).
- `tests/unit/RemediatorConfig.Tests.ps1`: Replaced `$IsWindows` (PS 6+ only)
  with `$env:OS -eq 'Windows_NT'` for cross-edition DPAPI guard.
- `tests/unit/Build.Tests.ps1`: Normalize ZIP entry path separators via
  `-replace '\\','/'` before `Should -Contain` assertions. On PS 5.1 Desktop,
  `ZipEntry.FullName` uses backslashes; PS 7 always uses forward slashes.
- `src/ArcRemediator/Private/Invoke-RestMethodWithTls.ps1` and
  `Invoke-WebRequestWithTls.ps1`: Added `.NOTES` sections documenting why the
  two TLS wrappers must not be collapsed. `IRM` auto-deserializes the response
  body; `IWR` exposes raw headers (`Azure-AsyncOperation`, `Retry-After`,
  `ETag`, `Location`) needed for ARM async-op polling and conditional PUTs.
- `src/ArcRemediator/Private/Invoke-Azcmagent.ps1`: Replaced `Start-Process
  -PassThru -RedirectStandard*` with direct `[System.Diagnostics.Process]::Start()`
  via `ProcessStartInfo`. On Windows PowerShell 5.1 Desktop (.NET Framework),
  `Start-Process -PassThru` combined with stream redirection returns a process
  handle where `ExitCode` is always `$null`. Using the .NET class directly
  bypasses that PS 5.1 bug. Async `ReadToEndAsync()` tasks are explicitly
  `Wait()`ed after `WaitForExit()` to drain buffered output before reading
  results.
- **`Invoke-ExpiredRejoin` `$DeleteTimeoutSec` default lowered from 1800 s to
  900 s** (15 min) (Gap 8). Microsoft's documented p99 for
  `hybridCompute/machines` ARM DELETE is under 5 min; 900 s provides three
  times that margin for transient retries while leaving room for the 1-hr
  task budget.
- **`Install.ps1` scheduled-task `ExecutionTimeLimit` raised from 30 min to
  1 hour** (Gap 8). The previous 30-min limit was shorter than the 30-min
  ARM-delete timeout, making it possible for Task Scheduler to kill the
  process before the rejoin sequence completed.

## [1.0.0-preview] - 2026-05-19

### Added

- Initial public preview. PowerShell 5.1 Desktop module for per-server
  Arc remediation on Windows Server.
- Observe and Enforce modes, gated by a literal-string kill switch read from
  Azure Storage SAS.
- DPAPI LocalMachine config wrap, SID-based ACL hardening, SYSTEM-context
  scheduled task installer.
- Manual RS256 JWT signing for client-assertion auth (no MSAL dependency).
- Dual-cloud support: `AzureCloud` and `AzureUSGovernment` (DoD/IL5).
- ARM async-op polling with `Retry-After`, `Azure-AsyncOperation`, and
  `Location`-header fallback.
- Log Analytics ingestion via Logs Ingestion API (DCE + DCR + custom table).
- Five fail-closed gates on the destructive Expired-rejoin path:
  kill switch, mode, cluster, cloud profile, 7-day cooldown.
- Pre-destructive ARM re-read so a transient mis-read can't trigger delete.
- Cooldown marker is written to disk BEFORE the destructive call so a
  mid-rejoin crash cannot loop.
- Azure Monitor workbook for fleet visibility.
- `package/build.ps1` producing `dist/arc-remediator-<version>.zip` with
  module + samples + README.
- Comprehensive Pester 5 unit coverage of the module and the `azure-setup`
  driver helpers.

[Unreleased]: https://github.com/mfoldes/automated_health_remediation_arc/compare/v1.0.0-preview...HEAD
[1.0.0-preview]: https://github.com/mfoldes/automated_health_remediation_arc/releases/tag/v1.0.0-preview
