#Requires -Version 5.1
<#
    .SYNOPSIS
        Local CI gate for ArcRemediator: Parser sweep, PSScriptAnalyzer, Pester.

    .DESCRIPTION
        Hard fails the build if any gate produces findings. Run before commit.
        Each gate can be skipped individually for iteration.

    .EXAMPLE
        ./build/Run-Tests.ps1

    .EXAMPLE
        ./build/Run-Tests.ps1 -SkipPester
#>
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer,
    [switch]$SkipParser,
    [switch]$SkipPester
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$srcPath = Join-Path $repoRoot 'src'
$testsPath = Join-Path $repoRoot 'tests'
$azureSetupPath = Join-Path $repoRoot 'azure-setup'

$failures = New-Object 'System.Collections.Generic.List[string]'

# ---- Gate 1: Parser sweep (PS 5.1 compatibility) ----
if (-not $SkipParser) {
    Write-Host '==> Parser sweep across src/, tests/, azure-setup/, build/ ...' -ForegroundColor Cyan
    $sweepRoots = @($srcPath, $testsPath, $azureSetupPath, $PSScriptRoot) | Where-Object { Test-Path $_ }
    $files = foreach ($root in $sweepRoots) {
        Get-ChildItem -Path $root -Include '*.ps1', '*.psm1', '*.psd1' -Recurse -File -ErrorAction SilentlyContinue
    }
    $parseErrorCount = 0
    foreach ($file in $files) {
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref]$null, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            foreach ($err in $parseErrors) {
                Write-Host (' {0}({1},{2}): {3}' -f `
                    $file.FullName, `
                    $err.Extent.StartLineNumber, `
                    $err.Extent.StartColumnNumber, `
                    $err.Message) -ForegroundColor Red
            }
            $parseErrorCount += $parseErrors.Count
        }
    }
    if ($parseErrorCount -gt 0) {
        $failures.Add("Parser sweep: $parseErrorCount error(s)")
    } else {
        Write-Host (' OK ({0} files, 0 parse errors)' -f $files.Count) -ForegroundColor Green
    }
}

# ---- Gate 2: PSScriptAnalyzer on src/ + azure-setup/ ----
if (-not $SkipAnalyzer) {
    Write-Host '==> PSScriptAnalyzer on src/ + azure-setup/ ...' -ForegroundColor Cyan
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        Write-Host ' PSScriptAnalyzer not installed. Installing for current user ...' -ForegroundColor Yellow
        Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
    }
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $analyzerResults = @()
    $analyzerRoots = @(
        $srcPath,
        (Join-Path $azureSetupPath 'private')
    ) | Where-Object { Test-Path $_ }
    foreach ($scanRoot in $analyzerRoots) {
        $analyzerResults += @(Invoke-ScriptAnalyzer -Path $scanRoot -Recurse -Severity @('Warning', 'Error') -ErrorAction Stop)
    }
    # Scan the setup driver (root-level azure-setup/*.ps1) without descending
    # into azure-setup/tests, which is excluded from analyzer scope by design.
    $driverScripts = @(Get-ChildItem -Path $azureSetupPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    foreach ($drv in $driverScripts) {
        $analyzerResults += @(Invoke-ScriptAnalyzer -Path $drv.FullName -Severity @('Warning', 'Error') -ErrorAction Stop)
    }
    if ($analyzerResults.Count -gt 0) {
        foreach ($r in $analyzerResults) {
            Write-Host (' [{0}] {1}({2}): {3} ({4})' -f `
                $r.Severity, $r.ScriptName, $r.Line, $r.Message, $r.RuleName) -ForegroundColor Red
        }
        $failures.Add("PSScriptAnalyzer: $($analyzerResults.Count) finding(s)")
    } else {
        Write-Host ' OK (0 warnings, 0 errors)' -ForegroundColor Green
    }
}

# ---- Gate 3: Pester ----
if (-not $SkipPester) {
    Write-Host '==> Pester on tests/unit + azure-setup/tests ...' -ForegroundColor Cyan
    $pesterModule = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 } | Select-Object -First 1
    if (-not $pesterModule) {
        Write-Host ' Pester >= 5 not installed. Installing for current user ...' -ForegroundColor Yellow
        Install-Module -Name Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.5.0 -ErrorAction Stop
    }
    Import-Module Pester -MinimumVersion 5.5.0 -ErrorAction Stop

    $pesterPaths = @((Join-Path $testsPath 'unit'), (Join-Path $azureSetupPath 'tests')) |
        Where-Object { Test-Path $_ }

    $config = [PesterConfiguration]::Default
    $config.Run.Path = $pesterPaths
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = (Join-Path $repoRoot 'TestResults/pester.xml')

    $pesterResult = Invoke-Pester -Configuration $config
    if ($pesterResult.FailedCount -gt 0) {
        $failures.Add("Pester: $($pesterResult.FailedCount) failed of $($pesterResult.TotalCount)")
    } else {
        Write-Host (' OK ({0} passed of {1})' -f $pesterResult.PassedCount, $pesterResult.TotalCount) -ForegroundColor Green
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'FAILED:' -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host " - $f" -ForegroundColor Red
    }
    exit 1
}

Write-Host ''
Write-Host 'All gates passed.' -ForegroundColor Green
exit 0
