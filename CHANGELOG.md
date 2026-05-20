# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/).

## [Unreleased]

### Added

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
- **Self-deadline guard in `Invoke-ArcRemediation`** (Gap 8): before
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
