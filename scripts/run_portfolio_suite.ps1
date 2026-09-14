<#
.SYNOPSIS
Runs the portfolio evidence suite with adversarial AXI timing and fault injection.
.DESCRIPTION
The default eleven tests run for seeds 1, 7, 42 with independent AW/W and random
stall timing. Read- and write-response injection each run for the same seeds.
The suite JSON/JUnit aggregate the three isolated child regressions (39 runs by
default). Any setup, compile, missing result, timeout or test failure exits nonzero.
#>
[CmdletBinding()]
param(
    [int[]]$Seeds = @(1, 7, 42),
    [string]$VsimPath,
    [string]$UvmPath,
    [string]$PythonPath,
    [ValidateSet('Auto','Enabled','Disabled')][string]$DpiExportMode = 'Auto',
    [switch]$EnableCoverage,
    [switch]$EnableSva,
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 180
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RegressionTools.psm1') -Force -DisableNameChecking
$projectRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $projectRoot 'run_regression.ps1'
if (-not $PythonPath) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCommand) { throw 'Python 3 is required to validate requirement coverage; pass -PythonPath.' }
    $PythonPath = $pythonCommand.Source
}
$suiteId = 'portfolio-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$suiteDirectory = Join-Path $projectRoot ('output\' + $suiteId)
New-Item -ItemType Directory -Path $suiteDirectory -Force | Out-Null
$phases = @(
    [pscustomobject]@{ Name = 'adversarial'; Tests = @(); PlusArgs = @('+AXI_AW_WAIT_W=1', '+AXI_STALL_MAX=7') },
    [pscustomobject]@{ Name = 'read-error'; Tests = @('read_error_test'); PlusArgs = @('+AXI_AW_WAIT_W=1', '+AXI_STALL_MAX=7', '+AXI_RERR_ADDR=100') },
    [pscustomobject]@{ Name = 'write-error'; Tests = @('write_error_test'); PlusArgs = @('+AXI_AW_WAIT_W=1', '+AXI_STALL_MAX=7', '+AXI_BERR_ADDR=8000') }
)
$childRuns = @()
$allResults = @()
$firstReport = $null
$failed = $false
foreach ($phase in $phases) {
    $runOptions = @{ Seeds = $Seeds; PlusArgs = $phase.PlusArgs; TimeoutSeconds = $TimeoutSeconds; EnableCoverage = $EnableCoverage; EnableSva = $EnableSva; DpiExportMode = $DpiExportMode }
    if ($phase.Tests.Count) { $runOptions.Tests = $phase.Tests }
    if ($VsimPath) { $runOptions.VsimPath = $VsimPath }
    if ($UvmPath) { $runOptions.UvmPath = $UvmPath }
    Write-Host "Portfolio phase: $($phase.Name)"
    $phaseDirectory = $null
    & $runner @runOptions 6>&1 | ForEach-Object {
        $line = $_.ToString()
        Write-Host $line
        if ($line.StartsWith('Output: ')) { $phaseDirectory = $line.Substring(8).Trim() }
    }
    $phaseExitCode = $LASTEXITCODE
    if ($phaseExitCode -ne 0) { $failed = $true }
    if ($phaseDirectory -and (Test-Path -LiteralPath (Join-Path $phaseDirectory 'summary.json'))) {
        $childReport = Get-Content -LiteralPath (Join-Path $phaseDirectory 'summary.json') -Raw | ConvertFrom-Json
        if (-not $firstReport) { $firstReport = $childReport }
        $allResults += @($childReport.Results)
        $childRuns += [pscustomobject]@{ Phase = $phase.Name; ExitCode = $phaseExitCode; OutputDirectory = $phaseDirectory; Count = @($childReport.Results).Count; SourceManifestPath = $childReport.SourceManifestPath }
    } else {
        $failed = $true
        $allResults += [pscustomobject]@{ Test = $phase.Name + '_setup'; Seed = 0; PlusArgs = $phase.PlusArgs; Result = 'FAIL'; Reason = 'Child runner failed before writing its summary.'; RuntimeSeconds = 0.0; LogPath = [string]$phaseDirectory }
        $childRuns += [pscustomobject]@{ Phase = $phase.Name; ExitCode = $phaseExitCode; OutputDirectory = $phaseDirectory; Count = 0; SourceManifestPath = $null }
    }
}
$suiteReport = [pscustomobject]@{
    SchemaVersion = 1; Mode = 'portfolio-suite'; RunId = $suiteId; CompletedUtc = [DateTime]::UtcNow.ToString('o')
    GitRevision = 'unavailable'; GitDirty = $null; ToolVersion = ''; VsimPath = $VsimPath; UvmPath = $UvmPath
    DpiExportModeRequested = $DpiExportMode; DpiExportModeResolved = 'unavailable'; DpiExportModeReason = 'No child report available.'; UvmNoDpiEnabled = $true
    CoverageEnabled = [bool]$EnableCoverage; SvaEnabled = [bool]$EnableSva; Seeds = $Seeds
    RequirementCoverageMetric = 'observed_requirement_bins'; RequirementCoveragePath = (Join-Path $suiteDirectory 'coverage\coverage_summary.json')
    ChildRuns = $childRuns; Results = $allResults; OutputDirectory = $suiteDirectory
}
if ($firstReport) {
    foreach ($name in @('GitRevision', 'GitDirty', 'ToolVersion', 'VsimPath', 'UvmPath', 'DpiExportModeRequested', 'DpiExportModeResolved', 'DpiExportModeReason', 'UvmNoDpiEnabled')) { $suiteReport.$name = $firstReport.$name }
}
Write-RegressionReports $suiteReport $suiteDirectory
& $PythonPath -B (Join-Path $PSScriptRoot 'merge_coverage.py') --reports (Join-Path $suiteDirectory 'summary.json') --output (Join-Path $suiteDirectory 'coverage')
$coverageExitCode = $LASTEXITCODE
if ($coverageExitCode -ne 0) { $failed = $true }
# Keep the input summary immutable after the merger hashes it.
[pscustomobject]@{ Metric = 'observed_requirement_bins'; ExitCode = $coverageExitCode; ReportPath = $suiteReport.RequirementCoveragePath } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $suiteDirectory 'coverage_gate.json') -Encoding UTF8
$passedCount = @($allResults | Where-Object { $_.Result -eq 'PASS' }).Count
Write-Host "Portfolio: $passedCount/$($allResults.Count) passed. Aggregate reports: $suiteDirectory"
if ($failed -or $passedCount -ne $allResults.Count) { exit 3 }
exit 0
