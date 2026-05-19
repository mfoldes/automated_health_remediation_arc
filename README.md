# ArcRemediator

A small PowerShell tool that keeps a fleet of **Azure Arc-enabled
Windows servers** healthy without anyone touching them by hand.

## What problem does this solve?

[Azure Arc][arc] lets you manage Windows servers in your own data
centers, on the edge, or in other clouds as if they were Azure VMs:
you can apply Azure Policy, run Update Manager, install monitoring
agents, and so on. To do that, each server runs a small agent
(`azcmagent`) that calls home to Azure.

Over time, some of those servers drift away from healthy. The two
states that matter for this tool:

- **Disconnected.** The agent stopped checking in, usually because a
  proxy, firewall, certificate, or service issue blocked it. Once the
  underlying problem is fixed, the agent reconnects on its own.
- **Expired.** A server has been disconnected for so long (~45 days)
  that Azure has effectively given up on it. Once Expired, you can't
  manage the machine from Azure anymore. The only fix is to remove
  the Azure-side record and re-onboard the agent from the server.

At fleet scale, both of these add up to real toil. Someone has to
notice the server is broken, RDP into it (if they can), and run a
sequence of commands. ArcRemediator does that on its own, once a day,
on every server, safely.

[arc]: https://learn.microsoft.com/azure/azure-arc/overview

## What it does, in one paragraph

A scheduled task runs on each Arc-enabled server once a day. It first
checks a fleet-wide kill switch (a blob in Azure Storage) and exits
early if the fleet has been paused. Otherwise it asks Azure what state
the machine is in. If Azure says the machine is healthy, it does
nothing. If Azure says the machine is disconnected, it tries the
non-destructive repairs first (restarting stopped Arc Windows services).
If Azure confirms the machine is expired, it removes the Azure record,
clears the local agent state, re-onboards the agent, and restores the
machine's tags. Every run writes one row to Log Analytics so you can
see what happened across the fleet.

## What it does, with more detail

1. **Kill switch first.** Read a small blob from Azure Storage. The
   blob must contain exactly the word `enabled` for the run to
   proceed. Anything else (or any error reading it) pauses the run
   before any Azure authentication happens. This is the fleet-wide
   emergency stop and it works even when credentials are broken.
2. **Cloud check.** Confirm the local agent's reported cloud matches
   the configured cloud profile. Commercial config on a Government
   host, or vice versa, fails closed with no token acquired.
3. **Two access tokens.** One for ARM (the Azure management plane),
   one for the Logs Ingestion API. Different audiences, different
   credential blocks if you've split them.
4. **Ask Azure for the resource state.** A single ARM GET against
   `Microsoft.HybridCompute/machines/<this-host>`. The response is
   classified into one of:
   `Connected`, `Disconnected`, `Expired`, `AzureMachineError`,
   `ResourceNotFound`, `ArmForbidden`, `ArmThrottled`,
   `ArmTransientFailure`, or `Unknown`.
5. **Act.** What happens next depends on the state and the mode:
   - In **Observe** mode the tool never changes anything in Azure
     or on the host. It just records what it would have done.
   - In **Enforce** mode:
     - `Disconnected` triggers a service restart attempt
       (himds / GCArcService / ExtensionService / ArcProxy).
     - `Expired`, and only `Expired`, can trigger the destructive
       delete-and-rejoin sequence. There are several gates in front
       of this; see [Safety controls](#safety-controls) below.
6. **Telemetry.** One row goes to a Log Analytics custom table
   (`ArcRemediation_CL`). A LAW POST failure does not change the
   primary outcome; the local log file is always the source of truth.

## Safety controls

The destructive path (delete + rejoin) is the one that needs the most
care. Several layers gate it:

| Layer | What it does |
|---|---|
| **Fleet pause** | A SAS-read kill switch. Anything other than the exact word `enabled` in the blob (including network errors) pauses the run before Azure auth. |
| **Per-machine pause** | An Arc tag `Remediation=Paused` skips remediation on that one host. |
| **Observe mode** | Non-mutating dry run. The default for new deployments and the only mode any host can use before its cloud passes the lab matrix. |
| **Cooldown** | One Expired delete-and-rejoin attempt per server per 7 days. The cooldown timer is written to disk **before** the first destructive call, so a crash mid-rejoin cannot loop. |
| **Circuit breaker** | After 3 consecutive failed runs the breaker trips and blocks destructive actions until an operator runs `Reset-ArcRemediator`. |
| **Cluster gate** | Hosts that look like they are part of an Azure Stack HCI cluster (`clusterResourceId`, `extendedLocation`, host-type strings) never get the destructive treatment. They surface as `NeedsHuman`. |
| **Cloud-profile gate** | A DoD/IL5 host with Arc Gateway configured is a config mismatch. Arc Gateway and automatic agent upgrade are Commercial-only. |
| **Secret hygiene** | Service-principal secrets, certificate private keys, and SAS query strings never appear on command lines, in exception messages, or in log lines. Certificates are preferred over secrets. Secret-flow paths write a temp config file with restricted ACLs and delete it in a `finally` block. |

## Two clouds, validated independently

The tool targets two Microsoft commercial cloud surfaces:

- **Azure Commercial** (`AzureCloud`): management.azure.com,
  login.microsoftonline.com, *.ingest.monitor.azure.com,
  *.blob.core.windows.net.
- **Azure Government DoD / IL5** (`AzureUSGovernment`):
  management.usgovcloudapi.net, login.microsoftonline.us,
  *.ingest.monitor.azure.us, *.blob.core.usgovcloudapi.net.

Commercial validation does **not** qualify DoD/IL5. The two environments
have different endpoints, different service tag requirements, and
different capability flags. Each cloud has its own lab matrix that
must pass before any host in that cloud can move to Enforce.

## Repository layout

```text
src/ArcRemediator/        the PowerShell 5.1 module (Desktop edition)
  Public/                 the three exported commands (Invoke / Test / Reset)
  Private/                helpers: tokens, ARM REST, agent wrappers, probes
  Data/                   cloud-profiles.psd1, version.txt
  Bootstrap/              Install.ps1, Uninstall.ps1, scheduled-task entry,
                          and Test-ArcInstallation post-install validator

azure-setup/              operator-workstation tooling: provisions the
                          shared Azure infra (storage, SAS blob, Log
                          Analytics workspace, DCR, service principals)

package/                  build.ps1 -> dist/arc-remediator-<version>.zip
workbook/                 Azure Monitor workbook JSON for fleet visibility

docs/
  ops-runbook.md          how to install, validate, and operate the tool
  tldr.md                 one-page summary for leadership / meetings

tests/
  unit/                   Pester 5 unit tests, run on every commit

build/Run-Tests.ps1       local CI gate (parser sweep + analyzer + Pester)
```

## The three commands you'll actually run

| Command | Where | What it does |
|---|---|---|
| `Invoke-ArcRemediation` | Daily, as SYSTEM, from the scheduled task | One real remediation run. Returns an outcome string and an exit code. |
| `Test-ArcRemediator` | Interactively, from an operator session | Same flow as the daily run, locked to Observe mode. Nothing changes in Azure or on the host. |
| `Reset-ArcRemediator` | Interactively, elevated | Clears the local circuit breaker. With `-AlsoClearExpiredAttempt`, also clears the 7-day cooldown (treat that as the bigger button). |

Two more scripts run during install / upgrade:

| Script | Where | What it does |
|---|---|---|
| `Bootstrap\Install.ps1` | Target host, elevated | Copies the module, DPAPI-wraps the config, tightens ACLs, registers the scheduled task. `-Validate` runs an active 5-step probe after install. |
| `azure-setup\Setup-AzureSide.ps1` | Operator workstation | Provisions the shared Azure resources for one cloud. Run once per cloud. |

## Build and test

```powershell
# Local CI gate (parser sweep + PSScriptAnalyzer + Pester 5).
# Must pass before every commit.
.\build\Run-Tests.ps1

# Build a release ZIP under package/dist/.
# Contains the module, the operator-setup tooling, both cloud config
# samples, and a README. This is what you hand to an operator.
.\package\build.ps1
```

The gate has three passes:

1. **Parser sweep.** Every `.ps1` file is parsed with
   `[System.Management.Automation.Language.Parser]::ParseFile()` on
   Windows PowerShell 5.1. Catches PowerShell 7-only syntax that the
   analyzer wouldn't.
2. **PSScriptAnalyzer.** Run with `-Severity Warning -EnableExit`.
   Findings are treated as build errors.
3. **Pester 5.** Unit tests under `tests/unit/` and
   `azure-setup/tests/` provide comprehensive coverage of the module's
   primitives and the azure-setup helpers.

## Compatibility

The module runs on **Windows PowerShell 5.1, Desktop edition**, on
Windows Server. That's intentional:

- Most Arc-enabled Windows fleets standardize on Windows PowerShell.
- The DPAPI features the config-wrap layer uses are only available
  on the .NET Framework runtime.
- Requiring a separate PowerShell 7 install on every managed server
  is a non-starter.

Concretely:

- No `??`, no ternary `? :`, no `?.`, no PowerShell 7-only cmdlets.
- `Set-StrictMode -Version 3.0` is enforced everywhere.
- Pester 5.7.1 for tests.

## Next steps

The code, installer, packaging, and docs are all in place. The one
remaining step before any cloud can move to Enforce is the lab
matrix: run each documented scenario in each target cloud against
a real Arc-enabled VM and capture a real Expired ARM response from
each cloud (see [`docs/ops-runbook.md`](docs/ops-runbook.md) for the
matrix). That step is operator-driven; this tool's part is done.
