# Security Policy

ArcRemediator is a per-server remediator that runs as `NT AUTHORITY\SYSTEM`
on Azure Arc-enabled Windows servers. It handles credentials (service-principal
secret or client-assertion certificate) and writes telemetry to Azure Log
Analytics. We take security reports seriously.

## Supported versions

| Version          | Supported          |
| ---------------- | ------------------ |
| 1.0.x-preview    | :white_check_mark: |
| < 1.0.0-preview  | :x:                |

This is a preview project. Once we ship 1.0.0 GA, this table is replaced
with a rolling N / N-1 support window.

## Reporting a vulnerability

Please **do not** open public GitHub issues for security reports.

Use **[GitHub Private Vulnerability Reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)**
on this repository (Security tab → "Report a vulnerability").

### What to include

- A description of the issue and the impact.
- Reproduction steps or a proof-of-concept (PowerShell snippet, ARM call,
  installer flag, etc.).
- The version of ArcRemediator (from `ArcRemediator.psd1`'s `ModuleVersion`).
- Whether the issue requires a particular cloud profile (Commercial or
  AzureUSGovernment), agent version, or Windows Server build.

### What to expect

- **Acknowledgement:** within 72 hours of report.
- **Triage decision:** within 7 business days.
- **Fix target:** within 30 days for High/Critical, on a best-effort basis
  for Medium and Low. We may extend on coordinated disclosure with the
  reporter.

## Scope

**In scope:**

- The PowerShell module under `src/ArcRemediator/`
- The installer (`src/ArcRemediator/Bootstrap/Install.ps1`)
- The `azure-setup/` provisioning code
- The packaging script (`package/build.ps1`)
- The Azure Monitor workbook (data exposure / KQL safety)

**Out of scope:**

- Operator-controlled configuration files (your responsibility to protect
  the plaintext config before passing it to the installer).
- Lab test harnesses (`tests/unit/`, `azure-setup/tests/`).
- Documentation typos or wording.
- Issues already documented as known POC limitations in `docs/` or
  `INSTALLATION.md`.

## Known POC limitations

- The scheduled task currently runs with `-ExecutionPolicy Bypass`. Code
  signing of module files is a planned hardening step before GA and is
  tracked outside the public issue tracker. Until then, ACLs on the install
  path are the primary tamper-resistance control.
- The DPAPI LocalMachine scope means any process running as `SYSTEM` or as
  a local Administrator on the same machine can decrypt the wrapped config.
  DPAPI is not a defense against admin-level adversaries; protection
  there is the host hardening story (BitLocker, Defender, Just-Enough-Admin),
  not the remediator.
