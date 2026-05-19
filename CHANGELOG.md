# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/).

## [Unreleased]

### Added

- GitHub Actions CI (`.github/workflows/ci.yml`) running `build/Run-Tests.ps1`
  on `windows-latest` for every push and pull request to `master`.
- `SECURITY.md` with the project's vulnerability-reporting policy.
- `CHANGELOG.md` (this file).

### Changed

- `ArcRemediator.psd1` now has populated `Author`, `CompanyName`, `Copyright`,
  `ProjectUri`, `ReleaseNotes`, and `Prerelease = 'preview'` metadata.
- `README.md` no longer claims a `tests/integration/` tree (none exists in
  this preview) and no longer quotes a specific Pester test count.

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
