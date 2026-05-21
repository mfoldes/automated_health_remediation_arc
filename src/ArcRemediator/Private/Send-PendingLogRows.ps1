#Requires -Version 5.1

function Send-PendingLogRows {
    <#
        .SYNOPSIS
            Attempt to re-send any LAW rows that were queued during previous
            failed Send-LogAnalytics calls.

        .DESCRIPTION
            When Send-LogAnalytics fails, Invoke-ArcRemediation writes the
            serialized row to a pending\ subdirectory. This function sweeps
            that directory and attempts one send per file per run.

            Files that send successfully are deleted. Files that fail are
            left for the next run. Files older than -RetentionDays are pruned
            regardless of send success. When the pending file count exceeds
            -MaxFiles, the oldest files are pruned first to stay within the
            cap before any re-send is attempted.

        .PARAMETER PendingDir
            Path to the pending directory.
            Defaults to %ProgramData%\ArcRemediator\pending.

        .PARAMETER LogIngestionEndpoint
            The logs ingestion URL (from config.LogIngestionEndpoint).

        .PARAMETER DcrImmutableId
            DCR immutable ID (from config.DcrImmutableId).

        .PARAMETER StreamName
            Stream declaration name (from config.StreamName).

        .PARAMETER AccessToken
            Monitor bearer token.

        .PARAMETER RetentionDays
            Prune files older than this many days. Default 30.

        .PARAMETER MaxFiles
            Cap on the number of pending files. Oldest are pruned first when
            the cap is exceeded before re-send is attempted. Default 500.

        .OUTPUTS
            PSCustomObject with:
              Attempted (int) — files for which a send was attempted
              Succeeded (int) — files successfully sent and deleted
              Pruned    (int) — files pruned by age or cap
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Rows is the correct plural for the LAW row objects being sent.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string]$PendingDir = (Join-Path $env:ProgramData 'ArcRemediator\pending'),

        [Parameter(Mandatory)]
        [string]$LogIngestionEndpoint,

        [Parameter(Mandatory)]
        [string]$DcrImmutableId,

        [Parameter(Mandatory)]
        [string]$StreamName,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter()]
        [int]$RetentionDays = 30,

        [Parameter()]
        [int]$MaxFiles = 500
    )

    $attempted = 0
    $succeeded = 0
    $pruned = 0

    if (-not (Test-Path -LiteralPath $PendingDir)) {
        return [PSCustomObject]@{ Attempted = 0; Succeeded = 0; Pruned = 0 }
    }

    $files = @(Get-ChildItem -LiteralPath $PendingDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime)

    if ($files.Count -eq 0) {
        return [PSCustomObject]@{ Attempted = 0; Succeeded = 0; Pruned = 0 }
    }

    # Prune by age first.
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    foreach ($f in $files) {
        if ($f.LastWriteTime -lt $cutoff) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
            $pruned++
        }
    }

    # Refresh list after age pruning.
    $files = @(Get-ChildItem -LiteralPath $PendingDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime)

    # Prune oldest if above cap.
    while ($files.Count -gt $MaxFiles) {
        $oldest = $files[0]
        try { Remove-Item -LiteralPath $oldest.FullName -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        $pruned++
        $files = $files[1..($files.Count - 1)]
    }

    # Attempt one send per remaining file.
    foreach ($f in $files) {
        $attempted++
        try {
            $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop
            $row = $raw | ConvertFrom-Json -ErrorAction Stop
            $send = Send-LogAnalytics `
                -LogIngestionEndpoint $LogIngestionEndpoint `
                -DcrImmutableId $DcrImmutableId `
                -StreamName $StreamName `
                -AccessToken $AccessToken `
                -Rows @($row)
            if ($send.Success) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                $succeeded++
            }
        } catch {
            # Leave file for next run; do not let a single corrupt file block others.
            $null = $_
        }
    }

    return [PSCustomObject]@{
        Attempted = $attempted
        Succeeded = $succeeded
        Pruned    = $pruned
    }
}

function Add-PendingLogRow {
    <#
        .SYNOPSIS
            Persist a LAW row to the pending queue on ingestion failure.

        .DESCRIPTION
            Writes the serialized row to <PendingDir>\<utc>-<guid>.json.
            Called by Invoke-ArcRemediation when Send-LogAnalytics returns
            Success=$false. Silently swallows all errors — persistence is
            best-effort and must never affect the primary run outcome.

        .PARAMETER Row
            The hashtable row to queue.

        .PARAMETER PendingDir
            Path to the pending directory.
            Defaults to %ProgramData%\ArcRemediator\pending.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort helper called with no user-facing side-effect gate.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Row,

        [Parameter()]
        [string]$PendingDir = (Join-Path $env:ProgramData 'ArcRemediator\pending')
    )

    try {
        if (-not (Test-Path -LiteralPath $PendingDir)) {
            New-Item -Path $PendingDir -ItemType Directory -Force | Out-Null
        }
        $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssZ')
        $id = [guid]::NewGuid().ToString('N')
        $file = Join-Path $PendingDir "$ts-$id.json"
        ($Row | ConvertTo-Json -Depth 10 -Compress) | Set-Content -LiteralPath $file -Encoding UTF8 -NoNewline
    } catch {
        # Silently ignore — pending queue write failure must not affect run outcome.
        $null = $_
    }
}
