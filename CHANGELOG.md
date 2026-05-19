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

### Changed

- `ArcRemediator.psd1` now has populated `Author`, `CompanyName`, `Copyright`,
  `ProjectUri`, `ReleaseNotes`, and `Prerelease = 'preview'` metadata.
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
- `src/ArcRemediator/Private/Invoke-Azcmagent.ps1`: Added blocking
  `$proc.WaitForExit()` in the non-timeout code path. On Windows PowerShell
  5.1, the timed `WaitForExit(ms)` overload may return `$true` before async
  stdout/stderr handles are fully flushed, causing `$proc.ExitCode` to return
  `$null`. The no-arg overload guarantees all handles are closed before
  `ExitCode` is read.

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
