#Requires -Version 5.1

function Test-AgentServices {
    <#
        .SYNOPSIS
            Read-only probe of the Azure Arc agent Windows services. Safe
            to call in Observe mode.

        .DESCRIPTION
             the remediator must be
            able to inspect the state of:

              * himds (Hybrid Instance Metadata Service)
              * GCArcService (Guest Configuration / Arc agent)
              * ExtensionService (Arc extension manager)

            and - when the host has Azure Arc Proxy installed OR when the
            cloud profile requires Arc Gateway - the optional service:

              * ArcProxy

            This function does NOT start, stop, restart, or change service
            configuration. We forbid mutating actions in
            Observe mode; keeping the probe read-only is what lets the
            orchestrator call it unconditionally.

            Missing required services produce NeedsHuman, not silent
            success (the requirement). Missing ArcProxy is
            NeedsHuman only when the active cloud profile supports Arc
            Gateway AND -GatewayRequired was passed by the caller (the
            orchestrator knows from Get-ArcConnectivitySettings whether
            a gateway resource is configured).

        .PARAMETER GatewayRequired
            Set by the caller when local config or cloud profile indicates
            an Arc Gateway is in use. Causes a missing ArcProxy service to
            count as a NeedsHuman condition rather than informational.

        .PARAMETER ServiceNames
            Override the required service-name list. Defaults to the
            three core Arc services. Tests inject placeholders here.

        .PARAMETER ArcProxyServiceName
            Override the Arc Proxy service name. Default: 'ArcProxy'.

        .OUTPUTS
            PSCustomObject with:
              Services (object[]) one row per inspected service
                                             { Name, Required, Installed,
                                               Status, IsRunning, IsStopped }
              MissingRequired (string[])
              StoppedRequired (string[])
              NeedsHuman (bool)
              NeedsHumanReason (string|null)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Inspects N Windows services in one call; renaming to Test-AgentService would mislead callers. ')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()] [bool]$GatewayRequired = $false,
        [Parameter()] [string[]]$ServiceNames = @('himds', 'GCArcService', 'ExtensionService'),
        [Parameter()] [string]$ArcProxyServiceName = 'ArcProxy'
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $missingReq = New-Object System.Collections.Generic.List[string]
    $stoppedReq = New-Object System.Collections.Generic.List[string]

    foreach ($name in $ServiceNames) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        $row = New-AgentServiceRow -Name $name -Required $true -Service $svc
        $rows.Add($row)
        if (-not $row.Installed) { $missingReq.Add($name) }
        elseif (-not $row.IsRunning -and -not $row.IsStopped) {
            # In a transient state (StartPending, StopPending, etc.) - treat as stopped for caller's purposes
            $stoppedReq.Add($name)
        }
        elseif ($row.IsStopped) { $stoppedReq.Add($name) }
    }

    # Arc Proxy is optional unless gateway is required.
    $proxySvc = Get-Service -Name $ArcProxyServiceName -ErrorAction SilentlyContinue
    $proxyRow = New-AgentServiceRow -Name $ArcProxyServiceName -Required:$GatewayRequired -Service $proxySvc
    $rows.Add($proxyRow)

    $needsHuman = $false
    $reasonParts = New-Object System.Collections.Generic.List[string]

    if ($missingReq.Count -gt 0) {
        $needsHuman = $true
        $reasonParts.Add("Missing required services: $([string]::Join(', ', $missingReq.ToArray()))")
    }

    if ($GatewayRequired -and -not $proxyRow.Installed) {
        $needsHuman = $true
        $reasonParts.Add("Arc Gateway is required by the active cloud profile but the $ArcProxyServiceName service is not installed")
    }

    return [PSCustomObject]@{
        Services = $rows.ToArray()
        MissingRequired = $missingReq.ToArray()
        StoppedRequired = $stoppedReq.ToArray()
        NeedsHuman = $needsHuman
        NeedsHumanReason = if ($reasonParts.Count -gt 0) { [string]::Join('; ', $reasonParts.ToArray()) } else { $null }
    }
}

function New-AgentServiceRow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [bool]$Required,
        [Parameter()] $Service
    )

    if (-not $Service) {
        return [PSCustomObject]@{
            Name = $Name
            Required = $Required
            Installed = $false
            Status = $null
            IsRunning = $false
            IsStopped = $false
        }
    }

    $status = [string]$Service.Status
    return [PSCustomObject]@{
        Name = $Name
        Required = $Required
        Installed = $true
        Status = $status
        IsRunning = ($status -ieq 'Running')
        IsStopped = ($status -ieq 'Stopped')
    }
}
