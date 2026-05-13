# ArcRemediator - at a glance

A small PowerShell tool that keeps a fleet of Azure Arc-enabled
Windows servers healthy on its own, with strong safety rails. Built
to run on every server as a daily scheduled task, with one shared
Azure-side setup per cloud.

## The problem

At fleet scale, Arc-enabled Windows servers drift into one of two
unhealthy states over time:

- **Disconnected.** The Arc agent stops checking in. Cause is usually
  local - a service stopped, a proxy moved, a cert expired.
- **Expired.** A server stays disconnected long enough that Azure
  effectively writes it off (~45 days). After that nothing reaches it
  through the Azure control plane: no Run Command, no extensions,
  no policy, no Defender or Update Manager. The only fix is to delete
  the Azure record and re-onboard the agent from the server.

Both fixes are well-understood but tedious, and they don't scale by
hand. In typical Arc deployments there's no central agent to push
commands to (Arc itself is the management plane, and unhealthy hosts
are precisely the ones it can't reach), and interactive remote access
is rarely viable at scale, so the backlog grows.

## What we built

A small PowerShell module that lives on each Arc-enabled Windows
server and runs once a day as `NT AUTHORITY\SYSTEM`. Each run:

1. Checks a fleet-wide **kill switch** (a single Azure Storage blob).
   If the blob doesn't contain the exact word `enabled`, the run
   stops before any Azure authentication happens.
2. Asks Azure what state the machine is in.
3. **Does nothing** if Azure says it's healthy.
4. **Repairs locally** if Azure says it's disconnected (restarts
   stopped Arc services).
5. **Deletes and re-onboards** if Azure confirms it's expired - but
   only under all the safety gates listed below.
6. Writes one row to a Log Analytics custom table so we can see what
   happened across the fleet.

It targets two Microsoft clouds, validated independently:

- **Azure Commercial** (`AzureCloud`).
- **Azure Government DoD / IL5** (`AzureUSGovernment`).

Commercial validation does not qualify Government and vice versa.
Each cloud has its own setup, its own canary, and its own go-live
gate.

## How it stays safe

| Layer | What it does |
|---|---|
| Fleet kill switch | One Storage blob. Anything other than the literal word `enabled` pauses the entire fleet before Azure auth happens. Reachable even with broken credentials. |
| Per-host pause | Tag the Arc resource `Remediation=Paused` to skip that one host. |
| Observe mode | The tool starts in dry-run mode. Nothing changes in Azure or on the host until an operator explicitly promotes that cloud to Enforce after the lab matrix passes. |
| 7-day cooldown | At most one destructive delete + re-onboard per server per week. The cooldown timer is written to disk *before* the destructive call, so a crash mid-rejoin cannot loop. |
| Circuit breaker | After 3 consecutive failed runs on a host, all further destructive actions stop until an operator runs `Reset-ArcRemediator`. |
| Cluster gate | Hosts that look like Azure Stack HCI / cluster-backed machines never get the destructive treatment - they surface as `NeedsHuman`. |
| Cloud-profile gate | A DoD/IL5 config on a Commercial host (or vice versa) fails closed before a single token is acquired. |
| Secret hygiene | Service-principal credentials never appear on command lines or in log lines. Certificates preferred over secrets; secret flows use a restricted-ACL temp file deleted in `finally`. |

## What it deliberately does not do

- Linux servers - not in scope; Windows only.
- Any air-gapped cloud beyond Azure Commercial and Azure Government
  DoD / IL5.
- A central control plane or push-to-server commands. The tool only
  does what is in its scheduled task; nothing reaches into individual
  servers.
- Automatically recreate a missing Arc resource on a 404. That stays
  an operator decision.
- Arc Gateway or automatic agent upgrade on DoD/IL5 - both are
  Commercial-only features.

## Footprint and cost

- **Per cloud, Azure side.** Two service principals, one storage
  account for the kill switch (Standard LRS), one Log Analytics
  workspace, one custom table, one Data Collection Rule. Single-
  digit dollars per month before telemetry.
- **Per server, on-host.** One scheduled task, a DPAPI-wrapped
  config file, a local state file, and a rolling local log. Outbound
  HTTPS only.
- **No new infrastructure.** No new VMs, queues, function apps, or
  central orchestrators.

## Status

The code, installer, packaging, and operator docs are **all
complete**:

- 100+ source files; 292 Pester unit tests; clean PSScriptAnalyzer.
- One-command installer (`Install.ps1 -Validate`) that DPAPI-wraps
  the config, applies the documented ACLs, registers the scheduled
  task, and runs a five-step active probe to confirm the setup.
- One-command Azure-side setup script (`Setup-AzureSide.ps1`) per
  cloud, idempotent, with both Commercial and Government tested.
- Azure Monitor workbook with nine fleet-level tiles (silent
  servers, outcomes by cloud, breaker state, version drift, Observe-
  mode holdouts, etc.).
- Operator runbook with the install, validate, kill-switch, reset,
  and lab-matrix flows.

The remaining step before the first Enforce-mode rollout is the **lab
matrix**: each documented scenario (kill switch, ConfigMismatch,
Connected, Disconnected, Expired, cluster-backed, ARM 403, ARM 429,
…) runs against a real Arc-enabled VM in each target cloud, and we
capture a real ARM response for an Expired machine in each cloud to
pin the destructive-path classifier.

## Open questions to land before Enforce

- Final region selection per cloud (where the LAW, DCR, and storage
  account go).
- The exact Connected Machine agent version we'll treat as the
  supported floor at rollout time - surfaced in telemetry as
  `ProbeAgentVersion.Status`.
- Production credential segmentation model: certificate authority
  source, rotation cadence, and which resource-group rings each
  service principal is scoped to.
- Sign-off path for promoting Commercial and Government from Observe
  to Enforce. Each cloud signs off independently after its own lab
  matrix.
