# ArcRemediator Installation Guide

This guide walks you through installing ArcRemediator from a clean slate. It assumes you have never used PowerShell modules or Azure before. Follow the steps top to bottom.

There are two sides to the install:

1. **Azure side.** One-time, per cloud (Commercial or Government DoD/IL5). Run from your operator workstation.
2. **Server side.** Once per Arc-enabled Windows server. Run on each server.

Allow about 30 to 60 minutes for the first run end to end.

## Table of contents

1. [What you are installing](#1-what-you-are-installing)
2. [Things to have ready](#2-things-to-have-ready)
3. [Set up your operator workstation](#3-set-up-your-operator-workstation)
4. [Get the minimum Azure permissions](#4-get-the-minimum-azure-permissions)
5. [Sign in to Azure](#5-sign-in-to-azure)
6. [Build the release package](#6-build-the-release-package)
7. [Provision the Azure side](#7-provision-the-azure-side)
8. [Fill in the config sample](#8-fill-in-the-config-sample)
9. [Install on a target server](#9-install-on-a-target-server)
10. [Verify the install worked](#10-verify-the-install-worked)
11. [Day one operations](#11-day-one-operations)
12. [Common problems](#12-common-problems)

## 1. What you are installing

ArcRemediator is a small PowerShell tool that runs once a day on each Azure Arc-enabled Windows server and keeps it healthy. The full overview lives in [`README.md`](README.md); this guide is purely the install procedure.

You will end up with:

* Two service principals in Azure Entra ID (one for management, one for telemetry), each scoped tightly.
* A storage account holding a fleet "kill switch" blob.
* A Log Analytics workspace and a custom table called `ArcRemediation_CL`.
* A data collection rule (DCR) that routes telemetry into that table.
* A scheduled task on each target server, running daily as `NT AUTHORITY\SYSTEM`.

## 2. Things to have ready

Before you start, gather:

| Item | Why |
|---|---|
| Your Azure subscription ID | Where everything will be deployed |
| Your Entra (Azure AD) tenant ID | For the service principals |
| The cloud you target: `Commercial` or `AzureGovernmentDoD` | Drives endpoints |
| An Azure region (for example `eastus` or `usgovvirginia`) | Where shared infra lands |
| A globally unique storage account name (3 to 24 lowercase letters/digits) | Holds the kill switch blob |
| The list of resource group names that contain your Arc-enabled servers | Tool is scoped to these only |
| One resource group name for shared infra (storage, workspace, DCR) | Operator-managed bucket |
| Administrator access on each target server | For the per-server installer |

If you do not know your subscription or tenant ID, you will retrieve them in [section 5](#5-sign-in-to-azure).

## 3. Set up your operator workstation

You only need a Windows 10/11 or Windows Server machine. Do this once.

### 3.1 Check your PowerShell version

Open **Windows PowerShell** (not "PowerShell 7" or "pwsh"). The icon says "Windows PowerShell". Right-click it and choose **Run as administrator**.

In the window, type:

```powershell
$PSVersionTable
```

You want `PSVersion` of `5.1.x` or higher and `PSEdition` of `Desktop`. Windows Server and Windows 10/11 ship this by default.

### 3.2 Install the Az PowerShell module

A "module" is just a bundle of commands you import into PowerShell. The Az module gives you Azure commands. Install it once with:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
Install-Module -Name Az -Repository PSGallery -Scope CurrentUser -Force
```

If asked to trust the repository, answer **Y**. Installation can take several minutes; that is normal.

Verify:

```powershell
Get-Module -ListAvailable Az.Accounts | Select-Object Name, Version
```

You want `Az.Accounts` at version `5.x` or higher (the Az meta-module is currently `14.x`).

### 3.3 Clone or copy the source

If you have Git:

```powershell
git clone <repo-url> C:\src\ArcRemediator
cd C:\src\ArcRemediator
```

If you do not have Git, ask whoever gave you the repo for a ZIP, extract it to `C:\src\ArcRemediator`, and `cd` into that folder. The exact path does not matter; just remember it.

## 4. Get the minimum Azure permissions

This is the most important section. **Do not** ask for Owner on the subscription. The tool is built around least privilege; ask only for what you need below. If your Azure admin can scope you to a single subscription and a small set of resource groups, even better.

### 4.1 What the operator (you) needs while running setup

You need these permissions **only while running `Setup-AzureSide.ps1`**. They can be revoked afterward.

**On the shared-infra resource group** (the one that will hold storage, workspace, and DCR):

* `Contributor` (to create the storage account, workspace, and DCR).
* `User Access Administrator` (to assign one role on the DCR).

**On each Arc resource group** the tool will manage (each one in `ScopedArcResourceGroupName`):

* `User Access Administrator` (to assign the two Arc roles to the management service principal). `Owner` works but is broader than needed.

**At the Entra tenant level**, one of:

* The built-in `Application Administrator` Entra role (lets you create the two app registrations).
* Or, if your tenant blocks self-service app creation, have your Entra admin pre-create the apps and skip ahead to [section 4.4](#44-if-you-cannot-create-app-registrations).

**At the subscription level**, just one narrow permission:

* `Microsoft.Authorization/*/read` (built into `Reader`) plus the ability to register resource providers. If your Azure admin can grant just `Microsoft.HybridCompute`, `Microsoft.HybridConnectivity`, `Microsoft.GuestConfiguration`, `Microsoft.Insights`, `Microsoft.OperationalInsights`, and `Microsoft.Storage` as pre-registered, you do not need any subscription-level write permission at all.

> If you are unsure: ask your Azure admin to pre-register those six providers on the subscription. Then you do not need any subscription-level role.

### 4.2 What the management service principal will get (Arc SP)

Created automatically during setup. Roles assigned **only on the Arc resource groups you listed**, never at subscription scope:

* `Azure Connected Machine Resource Administrator`
* `Azure Connected Machine Onboarding`

Blast radius if its credential leaks: an attacker can manage Arc-enabled machines in those specific resource groups. They cannot touch anything else in the subscription.

### 4.3 What the telemetry service principal will get (Logs Ingestion SP)

Created automatically during setup. One role on one resource:

* `Monitoring Metrics Publisher` on the DCR resource.

Blast radius if its credential leaks: an attacker can post fake telemetry rows. They cannot read or modify any Arc resource, the storage account, or the workspace.

### 4.4 If you cannot create app registrations

If tenant policy blocks you from creating apps in Entra, ask your Entra admin to create two empty app registrations (no API permissions, no redirect URIs) with display names like:

* `arc-remediator-prod` (or `-gov`)
* `arc-logs-ingestion-prod` (or `-gov`)

They should send you the **Application (client) ID** for each. Then in [section 7](#7-provision-the-azure-side), pass those display names to `-ArcSpDisplayName` and `-LogsSpDisplayName`. The setup script will reuse the existing apps and just attach credentials and role assignments.

### 4.5 Prefer certificates over secrets

The setup script defaults to certificate credentials, which is the right choice for production. Use `-UseClientSecret` only for short lab or canary runs. Secrets default to a 90-day lifetime; you must rotate them before they expire.

## 5. Sign in to Azure

In the same elevated PowerShell window:

```powershell
# Commercial
Connect-AzAccount -Environment AzureCloud

# Government DoD/IL5
Connect-AzAccount -Environment AzureUSGovernment
```

A browser tab opens. Sign in with your operator account. Back in PowerShell, point at the right subscription:

```powershell
Get-AzSubscription | Select-Object Name, Id
Set-AzContext -Subscription '<your-subscription-id>'
```

Confirm:

```powershell
Get-AzContext | Select-Object Name, Account, Subscription, Tenant
```

The `Tenant` field is your tenant ID. Note it down.

## 6. Build the release package

From inside the repo root (`C:\src\ArcRemediator` or wherever you cloned it):

```powershell
.\package\build.ps1
```

This produces a ZIP at `package\dist\arc-remediator-<version>.zip`. That ZIP is what you copy to each target server later. You do not need it to run the Azure-side setup; that runs straight from the source tree.

## 7. Provision the Azure side

Run this once per cloud. The script is idempotent; re-running with the same parameters is safe.

### 7.1 Commercial

```powershell
.\azure-setup\Setup-AzureSide.ps1 `
    -CloudProfile Commercial `
    -SubscriptionId '<sub-id>' `
    -Location 'eastus' `
    -InfraResourceGroupName 'rg-arc-infra' `
    -ScopedArcResourceGroupName @('rg-arc-prod-1','rg-arc-prod-2') `
    -StorageAccountName 'arcmediator001' `
    -WorkspaceName 'law-arc-commercial' `
    -DcrName 'dcr-arc-commercial' `
    -ConfigOutputPath '.\config.commercial.sample.json'
```

### 7.2 Government DoD/IL5

```powershell
.\azure-setup\Setup-AzureSide.ps1 `
    -CloudProfile AzureGovernmentDoD `
    -SubscriptionId '<sub-id>' `
    -Location 'usgovvirginia' `
    -InfraResourceGroupName 'rg-arc-infra-gov' `
    -ScopedArcResourceGroupName @('rg-arc-gov-1') `
    -StorageAccountName 'arcmediatorgov01' `
    -WorkspaceName 'law-arc-usgov' `
    -DcrName 'dcr-arc-usgov' `
    -ConfigOutputPath '.\config.usgovdod.sample.json'
```

### 7.3 What the script does, in order

You will see 12 numbered lines printed. Each one is a real step:

1. Confirms your Az context matches the cloud profile.
2. Registers required resource providers (or skips if already done).
3. Records the operator prerequisite (your perms from section 4).
4. Creates the two service principals.
5. Assigns the two Arc roles on each scoped resource group.
6. Creates the storage account, private container, kill-switch blob, stored access policy, and read-only SAS.
7. Creates the Log Analytics workspace and the `ArcRemediation_CL` custom table.
8. (Same step, table follows the workspace.)
9. Creates the data collection rule.
10. Creates a data collection endpoint only if you passed `-UseDataCollectionEndpoint`.
11. Assigns `Monitoring Metrics Publisher` on the DCR to the telemetry SP.
12. Writes the config sample to `-ConfigOutputPath`.

The storage account ships with TLS 1.2 minimum, public blob access disabled, and the container private. The SAS is bound to a 365-day read-only stored access policy so you can rotate it by name.

### 7.4 If certificates were generated

When the script runs with the default (certificate) path, a self-signed certificate is created in `Cert:\LocalMachine\My` on your workstation. You must export it and copy it to each target server.

For each cert (one per SP):

```powershell
# List certs with their thumbprints
Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -Like 'CN=sp-arc-*' |
    Select-Object Subject, Thumbprint
```

Export each as a PFX (with a strong password) for transport:

```powershell
$pwd = Read-Host -AsSecureString -Prompt 'PFX password'
Export-PfxCertificate `
    -Cert 'Cert:\LocalMachine\My\<thumbprint>' `
    -FilePath 'C:\Temp\sp-arc-remediator.pfx' `
    -Password $pwd
```

You will import these PFX files on each target server in [section 9](#9-install-on-a-target-server). Treat the PFX files like passwords. Delete them from disk after import.

## 8. Fill in the config sample

Open the file you wrote to `-ConfigOutputPath` (for example `config.commercial.sample.json`). It is plain JSON. Fill in any values that look like placeholders. The important fields:

| Field | What to put |
|---|---|
| `CloudProfile` | Already set by the script. Do not change. |
| `ArcCredential.TenantId` / `ClientId` | Set by the script. |
| `ArcCredential.CredentialType` | `Certificate` (recommended) or `ClientSecret`. |
| `ArcCredential.CertificateThumbprint` | The thumbprint of the cert you exported. |
| `ArcCredential.ClientSecret` | Only if `CredentialType` is `ClientSecret`. |
| `MonitorCredential.*` | Same fields, for the telemetry SP. |
| `SubscriptionId` | Your subscription. |
| `ScopedResourceGroups` | Same list you passed to setup. |
| `LogIngestionEndpoint`, `DcrImmutableId`, `StreamName` | Set by the script. |
| `KillSwitchUrl` | Set by the script. |
| `Mode` | Leave as `Observe` for first installs. |
| `MaxRuntimeMinutes` | Optional. Minutes before the run self-aborts before entering the destructive Expired-rejoin path. Default: 45. Set lower if your task scheduler `ExecutionTimeLimit` is below 60 minutes. |
| `ReconnectOnlyCooldownHours` | Optional. Hours to wait before retrying when the previous attempt's ARM DELETE succeeded but a later step failed (`ConnectFailed`, `TagsNotRestored`, or `VerificationFailed`). Default: 24. The full 7-day cooldown still applies when `DeleteFailed`. |

Keep this file safe and out of source control. The installer encrypts it before storing it on each server, but the plaintext copy is sensitive.

## 9. Install on a target server

Repeat for every Arc-enabled Windows server you want to manage.

### 9.1 Copy files

Copy these to the target server (anywhere local, for example `C:\Temp\arc-remediator`):

* `package\dist\arc-remediator-<version>.zip` (extract it once you arrive).
* Your filled-in config JSON file from [section 8](#8-fill-in-the-config-sample).
* The PFX files you exported in [section 7.4](#74-if-certificates-were-generated).

### 9.2 Import the certificates

On the target server, open **Windows PowerShell as administrator** and run for each PFX:

```powershell
$pwd = Read-Host -AsSecureString -Prompt 'PFX password'
Import-PfxCertificate `
    -FilePath 'C:\Temp\sp-arc-remediator.pfx' `
    -CertStoreLocation 'Cert:\LocalMachine\My' `
    -Password $pwd
```

Then delete the PFX file:

```powershell
Remove-Item 'C:\Temp\sp-arc-remediator.pfx' -Force
```

### 9.3 Run the installer

Still in elevated PowerShell, from inside the extracted ZIP folder:

```powershell
cd C:\Temp\arc-remediator
.\ArcRemediator\Bootstrap\Install.ps1 `
    -ConfigJsonPath 'C:\Temp\config.commercial.sample.json' `
    -Validate
```

The installer:

1. Confirms PowerShell 5.1 Desktop and elevated session.
2. Copies the module to `%ProgramFiles%\ArcRemediator`.
3. Encrypts your config with DPAPI LocalMachine and writes it to `%ProgramData%\ArcRemediator\config.json`. The original plaintext is not copied anywhere.
4. Locks down both folders:
   * Install folder: SYSTEM and Administrators get FullControl; standard users get ReadAndExecute.
   * Data folder: SYSTEM and Administrators only.
5. Registers a scheduled task named `ArcRemediator` that runs as SYSTEM daily at 02:00 plus a random 0 to 60 minute jitter.

### 9.4 Delete the plaintext config

After a successful install:

```powershell
Remove-Item 'C:\Temp\config.commercial.sample.json' -Force
```

The encrypted copy on disk is now the only one. Only SYSTEM or local Administrators on this exact machine can decrypt it.

## 10. Verify the install worked

The `-Validate` flag you passed in [9.3](#93-run-the-installer) already ran five active checks:

1. Config decrypts and the cloud profile loads.
2. An ARM access token can be acquired.
3. A Monitor access token can be acquired.
4. The kill switch blob is reachable and contains the word `enabled`.
5. A sample row posts successfully to the DCR.

If any step failed, read the `Detail` field on that step and fix it before moving on.

If you skipped `-Validate`, run the same checks anytime:

```powershell
Import-Module 'C:\Program Files\ArcRemediator\ArcRemediator.psd1'
Test-ArcRemediator
```

`Test-ArcRemediator` walks the full daily decision tree locked to Observe mode (nothing in Azure or on the host changes).

You can also see the row land in Log Analytics:

```kusto
ArcRemediation_CL
| where OutcomeDetail == 'Test-ArcInstallation probe'
| take 10
```

(Paste that into the **Logs** view of your workspace.)

## 11. Day one operations

### 11.1 Stay in Observe mode at first

Every fresh install defaults to `Mode = Observe`. The tool will log what it *would* do but never restart services, never delete an Arc resource, and never write any tag. Leave it there until you have completed the lab matrix in [`docs/ops-runbook.md`](docs/ops-runbook.md) section 11 for that cloud.

To promote a host to Enforce: edit `Mode` in the source config sample, re-wrap it by re-running `Install.ps1` with the new file, then delete the plaintext again.

### 11.2 The fleet kill switch

The setup script created a blob at `arc-remediator/kill-switch.txt` in your storage account. Its body is the word `enabled`. To pause the entire fleet on the next 02:00 run, change the body to anything else (a single space works). To unpause, set it back to exactly `enabled` (lowercase, no whitespace, no newline).

You can edit the blob through:

* The Azure Portal **Storage browser**, signed in as yourself.
* Azure Storage Explorer.
* `az storage blob upload --auth-mode login`.

Give your operator group `Storage Blob Data Contributor` on that storage account (or just the container) so individuals can flip the switch without sharing the SAS. The remediator reads the blob via the SAS; operators read and write via Entra.

### 11.3 Other commands

| Command | When |
|---|---|
| `Invoke-ArcRemediation` | Runs automatically via the scheduled task. You do not call this directly. |
| `Test-ArcRemediator` | Anytime, interactively. Same flow as the daily run, locked to Observe. |
| `Reset-ArcRemediator` | Elevated. Clears the local circuit breaker after a transient failure. |
| `Reset-ArcRemediator -AlsoClearExpiredAttempt` | Elevated. Also clears the 7-day rejoin cooldown. Treat as the bigger button. |

### 11.4 Where things live on the server

| Path | Contents |
|---|---|
| `%ProgramFiles%\ArcRemediator` | Module code. Read-only for non-admins. |
| `%ProgramData%\ArcRemediator\config.json` | Encrypted config. Admins and SYSTEM only. |
| `%ProgramData%\ArcRemediator\logs\arc-remediator-YYYYMMDD.log` | Local log. One line per run. |
| Scheduled Tasks Library, task `ArcRemediator` | The daily trigger. |

## 12. Common problems

### "Install.ps1: must be run from an elevated session"

You opened PowerShell normally. Close it and right-click the icon, then **Run as administrator**.

### "PowerShell Desktop edition (5.1) is required"

You opened **PowerShell 7** (pwsh). The module targets Windows PowerShell 5.1 Desktop on purpose. Open **Windows PowerShell** instead. On a Windows Server it is always present at `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`.

### "Failed to register required resource providers"

Your Azure admin needs to pre-register these six on the subscription:

* `Microsoft.HybridCompute`
* `Microsoft.HybridConnectivity`
* `Microsoft.GuestConfiguration`
* `Microsoft.Insights`
* `Microsoft.OperationalInsights`
* `Microsoft.Storage`

Then re-run the setup script.

### "Cannot create app registration" during setup

Your tenant blocks self-service app creation. Use the pre-created app path in [section 4.4](#44-if-you-cannot-create-app-registrations).

### Validation step "Kill switch" fails

The target server cannot reach the storage account. Check that the firewall, proxy, or NSG allows outbound HTTPS to your storage account's blob endpoint (`*.blob.core.windows.net` for Commercial, `*.blob.core.usgovcloudapi.net` for Government). The exact network requirements are in [`docs/ops-runbook.md`](docs/ops-runbook.md) section 4.

### Validation step "ArmToken" fails

Usually one of:

* The certificate is not in `Cert:\LocalMachine\My` on the target server. Re-import the PFX.
* The thumbprint in `config.json` does not match the imported cert. Re-check, re-wrap by re-running the installer.
* The target server cannot reach `login.microsoftonline.com` (or `.us` for Government).

### Validation step "LogIngestionPost" fails but everything else works

The remediator will still run; telemetry just will not land in Log Analytics. Check that the DCR exists, that the telemetry SP has `Monitoring Metrics Publisher` on it, and that the server can reach `*.ingest.monitor.azure.com` (or `.us`).

### I lost the plaintext config and need to reinstall

You do not need it. As long as the encrypted `%ProgramData%\ArcRemediator\config.json` is intact and the certificates are still in the local cert store, the host keeps working. To change a setting, regenerate the config from `Setup-AzureSide.ps1` (re-running it is safe) and reinstall.

### I want to remove the tool from a server

Elevated:

```powershell
.\ArcRemediator\Bootstrap\Uninstall.ps1
```

This unregisters the scheduled task, removes both folders, and stops there. It does not touch anything in Azure.

### I want to remove the Azure side

There is no automatic teardown. Delete in this order:

1. The role assignments on the two SPs.
2. The two app registrations in Entra.
3. The DCR, workspace, and storage account in the shared-infra resource group.

Be careful: if any servers are still installed and try to run, they will simply log `ArmForbidden` and exit cleanly. They will not break.
