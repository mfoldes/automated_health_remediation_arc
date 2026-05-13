#Requires -Version 5.1

function Repair-AgentServices {
    <#
        .SYNOPSIS
            Mutating repair for the Azure Arc agent Windows services.
            Enforce-mode only. Restarts stopped required services.

        .DESCRIPTION
             the Disconnected
            remediation path may restart stopped Arc services. This
            function performs that restart; it must not be called in
            Observe mode (the caller enforces that). The function:

              * Calls Test-AgentServices to take a current snapshot.
              * For each required service in StoppedRequired, invokes
                Start-Service.
              * Re-probes after each restart attempt and records whether
                the service reached Running.
              * Never tries to *install* a missing service; missing
                services are NeedsHuman, not auto-installable.

            Supports -WhatIf via SupportsShouldProcess for dry runs.

            The function never touches non-Arc services. ServiceNames is
            validated against the same default list as Test-AgentServices
            so a caller cannot widen the blast radius.

        .PARAMETER GatewayRequired
            Forwarded to Test-AgentServices. See that function.

        .PARAMETER ServiceNames
            Same default as Test-AgentServices. Lists the services this
            function is allowed to restart.

        .PARAMETER ArcProxyServiceName
            Same default as Test-AgentServices.

        .PARAMETER MaxAttempts
            Max Start-Service attempts per service. Default 1; the
            orchestrator handles longer retry windows separately so it
            can interleave probes.

        .OUTPUTS
            PSCustomObject with:
              Before / After (Test-AgentServices snapshots)
              Restarted (string[]) services that reached Running
              FailedToRestart (string[]) services that did not
              NeedsHuman (bool)
              NeedsHumanReason (string|null)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Restarts N services in one call; renaming to Repair-AgentService would mislead callers. ')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()] [bool]$GatewayRequired = $false,
        [Parameter()] [string[]]$ServiceNames = @('himds', 'GCArcService', 'ExtensionService'),
        [Parameter()] [string]$ArcProxyServiceName = 'ArcProxy',
        [Parameter()] [ValidateRange(1, 5)] [int]$MaxAttempts = 1
    )

    $before = Test-AgentServices -GatewayRequired:$GatewayRequired -ServiceNames $ServiceNames -ArcProxyServiceName $ArcProxyServiceName

    $restarted = New-Object System.Collections.Generic.List[string]
    $failedToRestart = New-Object System.Collections.Generic.List[string]

    $candidates = $before.Services | Where-Object { $_.Required -and $_.Installed -and -not $_.IsRunning }

    foreach ($svc in $candidates) {
        if (-not $PSCmdlet.ShouldProcess($svc.Name, 'Start-Service')) { continue }

        $ok = $false
        for ($i = 1; $i -le $MaxAttempts -and -not $ok; $i++) {
            try {
                Start-Service -Name $svc.Name -ErrorAction Stop
                $ok = $true
            } catch {
                # Retry within MaxAttempts; surface the final failure via the structured result.
                $null = $_
            }
        }

        # Re-read status from the service after the attempt(s).
        $post = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if ($post -and [string]$post.Status -ieq 'Running') {
            $restarted.Add($svc.Name)
        } else {
            $failedToRestart.Add($svc.Name)
        }
    }

    $after = Test-AgentServices -GatewayRequired:$GatewayRequired -ServiceNames $ServiceNames -ArcProxyServiceName $ArcProxyServiceName

    $needsHuman = $after.NeedsHuman
    $reasonParts = New-Object System.Collections.Generic.List[string]
    if ($after.NeedsHumanReason) { $reasonParts.Add($after.NeedsHumanReason) }
    if ($failedToRestart.Count -gt 0) {
        $needsHuman = $true
        $reasonParts.Add("Services that could not be restarted: $([string]::Join(', ', $failedToRestart.ToArray()))")
    }

    return [PSCustomObject]@{
        Before = $before
        After = $after
        Restarted = $restarted.ToArray()
        FailedToRestart = $failedToRestart.ToArray()
        NeedsHuman = $needsHuman
        NeedsHumanReason = if ($reasonParts.Count -gt 0) { [string]::Join('; ', $reasonParts.ToArray()) } else { $null }
    }
}
