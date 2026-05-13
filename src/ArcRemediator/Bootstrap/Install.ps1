#Requires -Version 5.1
<#
    .SYNOPSIS
        Install (or upgrade) ArcRemediator on a target Windows server.

    .DESCRIPTION
        Run this from an elevated PowerShell session on the host that
        will run the remediator. It does five things, in order:

          1. Pre-flight checks. Refuses to run on PowerShell 7+ Core
             (the module targets Desktop edition), on a PowerShell
             version older than 5.1, or in a non-elevated session.

          2. Copies the module files from -SourceModuleRoot to
             -InstallPath (defaults to %ProgramFiles%\ArcRemediator).

          3. Wraps the plaintext config you pass in -ConfigJsonPath
             with DPAPI LocalMachine and writes the encrypted form to
             <DataPath>\config.json. Any process running as SYSTEM
             or a local administrator on this machine can decrypt it;
             standard users cannot.

          4. Tightens directory ACLs so the install path is read-only
             for ordinary users and the data path is reachable only by
             SYSTEM and Administrators. Pass -SkipAclHardening when
             running the installer as a non-admin in a lab.

          5. Registers a scheduled task that runs the bootstrap entry
             script as NT AUTHORITY\SYSTEM, daily at -TaskStartTime
             (02:00 by default) plus a random delay between 0 and
             -TaskRandomDelayMinutes minutes. Task Scheduler retry
             behavior is deliberately disabled - the remediator
             handles its own throttling. The "Start only if any
             network connection is available" flag is also deliberately
             off so the diagnostic still runs when the network is
             degraded.

        Re-running the installer with the same code is safe: it copies
        fresh module files, refreshes the wrapped config, and re-registers
        the scheduled task with the current parameters.

        Pass -Validate to run an active probe of the installed setup
        immediately after install (cloud profile, ARM token, Monitor
        token, kill-switch read, and a sample Logs Ingestion POST).

    .PARAMETER ConfigJsonPath
        Path to the plaintext config sample (the JSON template emitted
        by azure-setup\Setup-AzureSide.ps1, with credentials and URLs
        filled in for the target environment). The installer DPAPI-wraps
        it before writing it to disk; the plaintext file you pass in is
        not copied anywhere.

    .PARAMETER InstallPath
        Where the module files are copied to.
        Defaults to %ProgramFiles%\ArcRemediator.

    .PARAMETER DataPath
        Where the wrapped config, local state, and log files live.
        Defaults to %ProgramData%\ArcRemediator.

    .PARAMETER SourceModuleRoot
        Folder containing the module to install (must contain
        ArcRemediator.psd1). Defaults to the src/ArcRemediator tree
        next to this script, which lets the installer run directly from
        a cloned repo.

    .PARAMETER TaskName
        Scheduled-task name. Defaults to 'ArcRemediator'.

    .PARAMETER TaskStartTime
        Daily trigger time. Defaults to 02:00.

    .PARAMETER TaskRandomDelayMinutes
        Maximum random delay added to the trigger time. Defaults to 60.

    .PARAMETER SkipTaskRegistration
        Skip the scheduled-task registration step. Useful in tests.

    .PARAMETER SkipElevationCheck
        Skip the admin-required gate. For test use only.

    .PARAMETER SkipEditionCheck
        Skip the PowerShell Desktop-edition gate. For test use only
        (the installed module still requires Desktop edition at runtime).

    .PARAMETER SkipAclHardening
        Skip the directory ACL tightening step. Use this when running
        the installer as a non-admin in a lab; the resulting install
        is not production-safe.

    .PARAMETER Validate
        Run Test-ArcInstallation immediately after install. The
        result object includes a Validation field with per-step
        pass/fail and details.

    .PARAMETER ValidateSkipLogIngestion
        With -Validate, skip the sample LAW POST step. Use this in
        air-gapped lab setups where Monitor is unreachable but the
        rest of the stack still needs to be validated.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$ConfigJsonPath,
    [Parameter()] [string]$InstallPath = (Join-Path $env:ProgramFiles 'ArcRemediator'),
    [Parameter()] [string]$DataPath = (Join-Path $env:ProgramData 'ArcRemediator'),
    [Parameter()] [string]$SourceModuleRoot,
    [Parameter()] [string]$TaskName = 'ArcRemediator',
    [Parameter()] [string]$TaskStartTime = '02:00',
    [Parameter()] [int]$TaskRandomDelayMinutes = 60,
    [Parameter()] [switch]$SkipTaskRegistration,
    [Parameter()] [switch]$SkipElevationCheck,
    [Parameter()] [switch]$SkipEditionCheck,
    [Parameter()] [switch]$SkipAclHardening,
    [Parameter()] [switch]$Validate,
    [Parameter()] [switch]$ValidateSkipLogIngestion
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ---- Helpers (declared before main flow uses them) ---------------------

function Set-InstallPathAcl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal helper to Install.ps1; that script gates the call via its own SupportsShouldProcess.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $admins = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $system = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $users = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, 'FullControl', $inherit, $prop, $allow)))
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, 'FullControl', $inherit, $prop, $allow)))
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users, 'ReadAndExecute', $inherit, $prop, $allow)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-DataPathAcl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal helper to Install.ps1; that script gates the call via its own SupportsShouldProcess.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $admins = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $system = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, 'FullControl', $inherit, $prop, $allow)))
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, 'FullControl', $inherit, $prop, $allow)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Register-RemediatorScheduledTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Caller (Install.ps1) gates this via SupportsShouldProcess.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TaskName,
        [Parameter(Mandatory)] [string]$TaskStartTime,
        [Parameter(Mandatory)] [int]$TaskRandomDelayMinutes,
        [Parameter(Mandatory)] [string]$TaskEntryScript
    )
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$TaskEntryScript`""
    $trigger = New-ScheduledTaskTrigger -Daily -At $TaskStartTime
    $trigger.RandomDelay = (New-TimeSpan -Minutes $TaskRandomDelayMinutes)
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
                    -MultipleInstances IgnoreNew `
                    -StartWhenAvailable `
                    -DontStopOnIdleEnd `
                    -DontStopIfGoingOnBatteries `
                    -AllowStartIfOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
                    -RestartCount 0
    $settings.RestartInterval = $null
    $settings.RestartCount = 0
    $settings.RunOnlyIfNetworkAvailable = $false

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null
}

# ---- Pre-flight ----------------------------------------------------------

if (-not $SkipEditionCheck -and $PSVersionTable.PSEdition -ne 'Desktop') {
    throw "Install.ps1: PowerShell Desktop edition (5.1) is required; current edition is '$($PSVersionTable.PSEdition)'. The module is pinned to Desktop in the manifest. -SkipEditionCheck is permitted only in test contexts."
}
if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    throw "Install.ps1: PowerShell 5.1 or higher is required; current version is $($PSVersionTable.PSVersion)."
}

if (-not $SkipElevationCheck) {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator
    if (-not $principal.IsInRole($adminRole)) {
        throw 'Install.ps1: must be run from an elevated session (administrator). Use -SkipElevationCheck only in test contexts.'
    }
}

if (-not (Test-Path -LiteralPath $ConfigJsonPath)) {
    throw "Install.ps1: ConfigJsonPath '$ConfigJsonPath' does not exist."
}

# Discover the source module root. Default = sibling of this script
# (src/ArcRemediator) so the installer can run directly from the repo
# without packaging. The packaged build.ps1 lays out the same shape.
if (-not $SourceModuleRoot) {
    $SourceModuleRoot = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $SourceModuleRoot 'ArcRemediator.psd1'))) {
    throw "Install.ps1: source module not found at '$SourceModuleRoot' (looking for ArcRemediator.psd1)."
}

# ---- 1. Copy module files to InstallPath --------------------------------

if (-not (Test-Path -LiteralPath $InstallPath)) {
    if ($PSCmdlet.ShouldProcess($InstallPath, 'Create install path')) {
        New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($InstallPath, 'Copy module files')) {
    Get-ChildItem -LiteralPath $SourceModuleRoot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $InstallPath -Recurse -Force
    }
}

$installedManifest = Join-Path $InstallPath 'ArcRemediator.psd1'
$installedTaskEntry = Join-Path $InstallPath 'Bootstrap\Invoke-RemediatorTask.ps1'
if (-not (Test-Path -LiteralPath $installedManifest)) { throw "Install.ps1: post-copy manifest missing at '$installedManifest'." }
if (-not (Test-Path -LiteralPath $installedTaskEntry)) { throw "Install.ps1: post-copy task entry missing at '$installedTaskEntry'." }

# ---- 3. DataPath ---------------------------------------------------------

if (-not (Test-Path -LiteralPath $DataPath)) {
    if ($PSCmdlet.ShouldProcess($DataPath, 'Create data path')) {
        New-Item -Path $DataPath -ItemType Directory -Force | Out-Null
    }
}
$logsDir = Join-Path $DataPath 'logs'
if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
}

# ---- 4. DPAPI-wrap config (BEFORE applying the restrictive ACL, so the
# current process still has Write access to the directory) -------

if ($PSCmdlet.ShouldProcess('config.json', 'DPAPI-wrap operator config')) {
    # Inline DPAPI wrap. This intentionally does NOT import the module --
    # the install path is a bootstrap context and the test harness may
    # already have the source module loaded under the same name; touching
    # module state here would yank it out from under the test scope.
    Add-Type -AssemblyName System.Security
    $plainText = Get-Content -LiteralPath $ConfigJsonPath -Raw
    # Re-serialize via ConvertFrom-Json + ConvertTo-Json so the wrapped
    # bytes match what Get-DecryptedConfig later expects (round-trips
    # through PSCustomObject -> JSON, dropping operator whitespace).
    $configJson = ($plainText | ConvertFrom-Json | ConvertTo-Json -Depth 10)
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($configJson)
    try {
        $protected = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $configPath = Join-Path $DataPath 'config.json'
        $tempCfg = "$configPath.tmp"
        [System.IO.File]::WriteAllBytes($tempCfg, $protected)
        Move-Item -LiteralPath $tempCfg -Destination $configPath -Force
    } finally {
        for ($i = 0; $i -lt $plainBytes.Length; $i++) { $plainBytes[$i] = 0 }
    }
}

# ---- 5. ACLs (after config write so the writer kept its write access) ----

if (-not $SkipAclHardening) {
    if ($PSCmdlet.ShouldProcess($InstallPath, 'Apply InstallPath ACL')) {
        Set-InstallPathAcl -Path $InstallPath
    }
    if ($PSCmdlet.ShouldProcess($DataPath, 'Apply DataPath ACL (Admins+SYSTEM only)')) {
        Set-DataPathAcl -Path $DataPath
    }
}

# ---- 5. Scheduled task --------------------------------------------------

if (-not $SkipTaskRegistration) {
    Register-RemediatorScheduledTask -TaskName $TaskName -TaskStartTime $TaskStartTime `
        -TaskRandomDelayMinutes $TaskRandomDelayMinutes -TaskEntryScript $installedTaskEntry
}

# ---- 6. -Validate (optional active probe) ----------------------------

$validation = $null
if ($Validate) {
    # Dot-source the installed validator so Test-ArcInstallation is callable
    # in this same shell. The validator imports the freshly-installed module
    # itself; we do not pre-import here to avoid the multi-module-load tangle
    # the same way the DPAPI block does.
    . (Join-Path $InstallPath 'Bootstrap\Test-ArcInstallation.ps1')
    $validation = Test-ArcInstallation `
        -ConfigPath (Join-Path $DataPath 'config.json') `
        -ModulePath $installedManifest `
        -SkipLogIngestion:$ValidateSkipLogIngestion
}

return [PSCustomObject]@{
    InstallPath = $InstallPath
    DataPath = $DataPath
    ConfigPath = (Join-Path $DataPath 'config.json')
    TaskName = $TaskName
    TaskRegistered = (-not $SkipTaskRegistration.IsPresent)
    ManifestPath = $installedManifest
    Validation = $validation
}

