<#
.SYNOPSIS
Runs isolated ModelSim/Questa UVM regressions or simulator feature probes.
.DESCRIPTION
Each invocation preserves logs, work library, seed/provenance metadata, JSON and
JUnit under output/uvm_<unique id>. UTC times remain in report metadata.
-ProbeCapabilities runs only feature probes; unsupported features are reported as
UNSUPPORTED/UNAVAILABLE and never represented as DUT coverage or signoff.
Exit codes: 0 all tests passed / probes completed; 1 setup error; 2 compile failure;
3 test failure or timeout; 4 unexpected capability probe failure.
.EXAMPLE
.\run_regression.ps1 -Tests copy_test -Seeds 1,7 -PlusArgs '+AXI_STALL_MAX=5'
.EXAMPLE
.\run_regression.ps1 -ProbeCapabilities
#>
[CmdletBinding()]
param(
    [string[]]$Tests = @('smoke_test', 'copy_test', 'len_zero_test', 'unaligned_addr_test', 'out_of_range_test', 'csr_access_test', 'descriptor_corner_test', 'irq_test', 'busy_start_test', 'reset_mid_transfer_test', 'seeded_copy_test'),
    [int[]]$Seeds = @(1),
    [string]$VsimPath,
    [string]$UvmPath,
    [string[]]$PlusArgs = @(),
    [ValidateSet('Auto','Enabled','Disabled')][string]$DpiExportMode = 'Auto',
    [switch]$EnableCoverage,
    [switch]$EnableSva,
    [switch]$ProbeCapabilities,
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 180
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\RegressionTools.psm1') -Force -DisableNameChecking
$projectRoot = $PSScriptRoot
$runDirectory = $null
$report = $null
try {
    if ($Tests.Count -eq 0 -or $Seeds.Count -eq 0) { throw 'Tests and Seeds must be nonempty.' }
    foreach ($testName in $Tests) { if ($testName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Invalid test name: $testName" } }
    foreach ($argument in $PlusArgs) {
        if ($argument -notmatch '^\+[^\r\n{}]+$') { throw "PlusArgs must contain simulator plusargs, for example +AXI_STALL_MAX=5." }
        if ($argument -match '^\+(UVM_TESTNAME|TEST_SEED|COVERAGE_FILE)=') { throw 'Test, stimulus seed, and coverage output are managed by the runner.' }
    }
    $simulator = Resolve-Simulator $VsimPath $UvmPath
    $runId = 'uvm_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $runDirectory = Join-Path $projectRoot ('output\' + $runId)
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $versionProcess = Invoke-BoundedProcess -Executable $simulator.VsimPath -Arguments @('-version') -WorkingDirectory $runDirectory -LogPrefix (Join-Path $runDirectory 'version') -TimeoutSeconds 30
    $toolVersion = (Read-Logs @($versionProcess.StdoutPath, $versionProcess.StderrPath)).Trim()
    if ($versionProcess.TimedOut -or $versionProcess.ExitCode -ne 0) { throw "Simulator version query failed. See $runDirectory" }
    # The runner compiles all UVM code with UVM_NO_DPI. Bundled UVM 1.2 still
    # declares an unused reporting export. This old Windows simulator can crash
    # loading its generated export DLLs; bypass only that unused wrapper path.
    $usesUvmNoDpi = $true
    $dpiExportModeResolved = $DpiExportMode
    $dpiExportModeReason = 'Explicit user selection.'
    if ($DpiExportMode -eq 'Auto') {
        $knownLegacySimulator = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
            $toolVersion -match 'ModelSim - INTEL FPGA STARTER EDITION vsim 2020\.1(?:\s|$)'
        if ($usesUvmNoDpi -and $knownLegacySimulator) {
            $dpiExportModeResolved = 'Disabled'
            $dpiExportModeReason = 'Pure-SV UVM_NO_DPI build on Windows ModelSim Intel FPGA Starter 2020.1: avoid unused generated export DLL loading.'
        } else {
            $dpiExportModeResolved = 'Enabled'
            $dpiExportModeReason = 'Auto mode preserves the default export loader on other simulator configurations.'
        }
    }
    $dpiLoadOption = ''
    if ($dpiExportModeResolved -eq 'Disabled') { $dpiLoadOption = '-nodpiexports' }
    $gitRevision = 'unavailable'
    $gitDirty = $null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $revisionOutput = & git -C $projectRoot rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) { $gitRevision = [string]$revisionOutput }
        $statusOutput = & git -C $projectRoot status --porcelain 2>$null
        if ($LASTEXITCODE -eq 0) { $gitDirty = -not [string]::IsNullOrWhiteSpace(($statusOutput -join "`n")) }
    }
    $report = [pscustomobject]@{
        SchemaVersion = 1; Mode = 'regression'; RunId = $runId; StartedUtc = [DateTime]::UtcNow.ToString('o')
        CompletedUtc = $null; GitRevision = $gitRevision; GitDirty = $gitDirty; ToolVersion = $toolVersion
        VsimPath = $simulator.VsimPath; UvmPath = $simulator.UvmPath; CoverageEnabled = [bool]$EnableCoverage
        SvaEnabled = [bool]$EnableSva; UvmNoDpiEnabled = $usesUvmNoDpi; DpiExportModeRequested = $DpiExportMode; DpiExportModeResolved = $dpiExportModeResolved; DpiExportModeReason = $dpiExportModeReason; Tests = $Tests; Seeds = $Seeds; PlusArgs = $PlusArgs
        TimeoutSeconds = $TimeoutSeconds; OutputDirectory = $runDirectory; SourceManifestPath = (Join-Path $runDirectory 'source_manifest.json'); SourceManifestSha256 = ''; RequirementCoverageMetric = 'observed_requirement_bins'; Compile = $null; Results = @()
    }
    # Freeze all repository HDL and runner inputs before compilation. The manifest
    # identifies the exact copied bytes even when the checkout is dirty or edited later.
    $snapshotDirectory = Join-Path $runDirectory 'source'
    New-Item -ItemType Directory -Path $snapshotDirectory -Force | Out-Null
    foreach ($sourceName in @('filelist.f', 'run_regression.ps1', 'rtl', 'tb', 'scripts')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $sourceName) -Destination $snapshotDirectory -Recurse
    }
    $sourceHashes = @(Get-ChildItem -LiteralPath $snapshotDirectory -Recurse -File | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName.Substring($snapshotDirectory.Length + 1).Replace('\', '/'); Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    $uvmHashes = @(Get-ChildItem -LiteralPath $simulator.UvmPath -Recurse -File | Where-Object { $_.Extension -in @('.sv', '.svh') } | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName.Substring($simulator.UvmPath.Length + 1).Replace('\', '/'); Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    [pscustomobject]@{ GitRevision = $gitRevision; GitDirty = $gitDirty; SnapshotDirectory = $snapshotDirectory; Sources = $sourceHashes; UvmSourceDirectory = $simulator.UvmPath; UvmSources = $uvmHashes } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $report.SourceManifestPath -Encoding UTF8
    $report.SourceManifestSha256 = (Get-FileHash -LiteralPath $report.SourceManifestPath -Algorithm SHA256).Hash
    Write-Host "Output: $runDirectory"
    Write-Host $toolVersion
    Write-Host "DPI exports: $dpiExportModeResolved ($DpiExportMode). $dpiExportModeReason"
    $uvmInclude = ConvertTo-TclWord ('+incdir+' + $simulator.UvmPath)
    $uvmSource = ConvertTo-TclWord (Join-Path $simulator.UvmPath 'uvm_pkg.sv')

    if ($ProbeCapabilities) {
        $report.Mode = 'capability-probes'
        $report.Tests = @('uvm_probe', 'constrained_random_probe', 'covergroup_probe', 'assertion_probe')
        $report.Seeds = @(1)
        $report.PlusArgs = @()
        foreach ($probeName in @('uvm_probe', 'constrained_random_probe', 'covergroup_probe', 'assertion_probe')) {
            $probeDirectory = Join-Path $runDirectory $probeName
            $iniPath = New-SimulationDirectory $probeDirectory $simulator.VendorIni
            $logPath = Join-Path $probeDirectory 'probe.log'
            $source = ConvertTo-TclWord (Join-Path $snapshotDirectory ('scripts\probes\' + $probeName + '.sv'))
            $uvmCompile = ''
            if ($probeName -eq 'uvm_probe') { $uvmCompile = "vlog -sv +define+UVM_NO_DPI $uvmInclude $uvmSource" }
            $loadOptions = $dpiLoadOption
            if ($probeName -eq 'covergroup_probe') { $loadOptions += ' -coverage' }
            $probeDo = @"
onerror {quit -f -code 4}
onbreak {resume}
transcript file $(ConvertTo-TclWord $logPath)
vlib $(ConvertTo-TclWord (Join-Path $probeDirectory 'work'))
$uvmCompile
vlog -sv +define+UVM_NO_DPI $uvmInclude $source
vsim -onfinish stop -sv_seed 1 $loadOptions work.$probeName
run -all
quit -f -code 0
"@
            $process = Invoke-SimulationDo $simulator $probeDirectory $iniPath 'probe' $probeDo $TimeoutSeconds
            $text = Read-Logs @($logPath, $process.StdoutPath, $process.StderrPath)
            $reason = Get-SimulationFailure -Process $process -Text $text -PassMarker ($probeName + ' PASSED') -RequireUvmSummary:($probeName -eq 'uvm_probe')
            $result = 'PASS'
            if ($reason) {
                $result = 'FAIL'
                if ($text -match '(?i)license|licensing|checkout failed|no valid feature') { $result = 'UNAVAILABLE'; $reason = 'Feature could not run because a simulator license/feature was unavailable.' }
                elseif ($text -match '(?i)PROBE_FEATURE_INACTIVE|not supported|unsupported|not available in|disabled in this|feature is disabled') { $result = 'UNSUPPORTED'; $reason = 'Simulator rejected or did not execute the feature; inspect the probe log.' }
            }
            $entry = [pscustomobject]@{ Test = $probeName; Seed = 1; PlusArgs = @(); GitRevision = $gitRevision; GitDirty = $gitDirty; ToolVersion = $toolVersion; Result = $result; Reason = $reason; ExitCode = $process.ExitCode; TimedOut = $process.TimedOut; RuntimeSeconds = $process.RuntimeSeconds; LogPath = $logPath }
            $report.Results += $entry
            $entry | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $probeDirectory 'result.json') -Encoding UTF8
            Write-Host "$probeName : $result $reason"
        }
        $report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Write-RegressionReports $report $runDirectory
        if (@($report.Results | Where-Object { $_.Result -eq 'FAIL' }).Count -gt 0) { exit 4 }
        exit 0
    }

    $fileListPath = Join-Path $snapshotDirectory 'filelist.f'
    $sourceLines = @(Get-Content -LiteralPath $fileListPath | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^(#|//)' })
    $resolvedSources = foreach ($line in $sourceLines) {
        $sourcePath = $line.Trim()
        if ($sourcePath.StartsWith('+')) { throw "Unsupported filelist option '$sourcePath'; keep source files in filelist.f." }
        if ([IO.Path]::IsPathRooted($sourcePath) -or $sourcePath -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Use repository-relative paths without traversal in filelist.f so compiled sources can be frozen.' }; $sourcePath = Join-Path $snapshotDirectory $sourcePath
        $sourcePath = (Resolve-Path -LiteralPath $sourcePath).Path
        '"' + $sourcePath.Replace('\', '/') + '"'
    }
    $resolvedFileList = Join-Path $runDirectory 'sources.f'
    Set-Content -LiteralPath $resolvedFileList -Value $resolvedSources -Encoding ASCII
    $iniPath = New-SimulationDirectory $runDirectory $simulator.VendorIni
    $compileLog = Join-Path $runDirectory 'compile.log'
    $defines = '+define+UVM_NO_DPI'
    if ($EnableCoverage) { $defines += ' +define+ENABLE_SV_COV' }
    if ($EnableSva) { $defines += ' +define+ENABLE_SVA' }
    $compileDo = @"
onerror {quit -f -code 2}
onbreak {quit -f -code 2}
transcript file $(ConvertTo-TclWord $compileLog)
vlib $(ConvertTo-TclWord (Join-Path $runDirectory 'work'))
vlog -sv +define+UVM_NO_DPI $uvmInclude $uvmSource
vlog -sv $defines $uvmInclude -f $(ConvertTo-TclWord $resolvedFileList)
puts {COMPILE PASSED}
quit -f -code 0
"@
    $compileProcess = Invoke-SimulationDo $simulator $runDirectory $iniPath 'compile' $compileDo $TimeoutSeconds
    $compileText = Read-Logs @($compileLog, $compileProcess.StdoutPath, $compileProcess.StderrPath)
    $compileReason = Get-SimulationFailure $compileProcess $compileText 'COMPILE PASSED'
    $compileResult = 'PASS'
    if ($compileReason) { $compileResult = 'FAIL' }
    $report.Compile = [pscustomobject]@{ Result = $compileResult; Reason = $compileReason; ExitCode = $compileProcess.ExitCode; TimedOut = $compileProcess.TimedOut; RuntimeSeconds = $compileProcess.RuntimeSeconds; LogPath = $compileLog }
    if ($compileReason) {
        $report.Results = @([pscustomobject]@{ Test = 'compile'; Seed = 0; PlusArgs = @(); Result = 'FAIL'; Reason = $compileReason; ExitCode = $compileProcess.ExitCode; TimedOut = $compileProcess.TimedOut; RuntimeSeconds = $compileProcess.RuntimeSeconds; LogPath = $compileLog })
        $report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Write-RegressionReports $report $runDirectory
        Write-Host "COMPILE FAIL: $compileReason See $compileLog"
        exit 2
    }
    Write-Host 'COMPILE PASS'
    foreach ($testName in $Tests) {
        foreach ($seed in $Seeds) {
            $testDirectory = Join-Path $runDirectory ($testName + '_seed_' + $seed)
            New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
            $logPath = Join-Path $testDirectory 'simulation.log'
            $coveragePath = Join-Path $testDirectory 'requirement_coverage.tsv'
            $testPlusArgs = @(('+UVM_TESTNAME=' + $testName), '+UVM_NO_RELNOTES', ('+TEST_SEED=' + $seed), ('+COVERAGE_FILE=' + $coveragePath.Replace('\', '/')))
            $testPlusArgs += $PlusArgs
            if (-not @($PlusArgs | Where-Object { $_ -match '^\+AXI_STALL_SEED=' }).Count) { $testPlusArgs += ('+AXI_STALL_SEED=' + $seed) }
            $loadOptions = ('-sv_seed ' + $seed + ' ' + $dpiLoadOption).Trim()
            $coverageCommands = ''
            if ($EnableCoverage) {
                $loadOptions += ' -coverage'
                $coverageCommands = 'coverage save ' + (ConvertTo-TclWord (Join-Path $testDirectory 'coverage.ucdb'))
            }
            $plusArgText = ($testPlusArgs | ForEach-Object { ConvertTo-TclWord $_ }) -join ' '
            $runDo = @"
onerror {quit -f -code 3}
onbreak {resume}
transcript file $(ConvertTo-TclWord $logPath)
vsim -onfinish stop $loadOptions -wlf $(ConvertTo-TclWord (Join-Path $testDirectory 'waves.wlf')) work.tb_top $plusArgText
run -all
$coverageCommands
quit -f -code 0
"@
            $process = Invoke-SimulationDo $simulator $testDirectory $iniPath 'run' $runDo $TimeoutSeconds
            $text = Read-Logs @($logPath, $process.StdoutPath, $process.StderrPath)
            $reason = Get-SimulationFailure -Process $process -Text $text -PassMarker ($testName + ' PASSED') -RequireUvmSummary
            if (-not $reason -and $EnableSva -and $text -match '(?i)assertions? (are |is )?(supported only|not supported|disabled)|vsim-8311') {
                $reason = 'Concurrent assertions were requested but the simulator reports that they are unavailable.'
            }
            if (-not $reason -and (-not (Test-Path -LiteralPath $coveragePath) -or (Get-Item -LiteralPath $coveragePath).Length -eq 0)) {
                $reason = 'Required observed-bin coverage export is missing or empty.'
            }
            $result = 'PASS'
            if ($reason) { $result = 'FAIL' }
            $entry = [pscustomobject]@{
                Test = $testName; Seed = $seed; PlusArgs = $testPlusArgs; Result = $result; Reason = $reason
                GitRevision = $gitRevision; GitDirty = $gitDirty; ToolVersion = $toolVersion
                ExitCode = $process.ExitCode; TimedOut = $process.TimedOut; RuntimeSeconds = $process.RuntimeSeconds; LogPath = $logPath; CoveragePath = $coveragePath
            }
            $report.Results += $entry
            $entry | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $testDirectory 'result.json') -Encoding UTF8
            Write-Host "$testName seed=$seed : $result $reason"
        }
    }
    $report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    Write-RegressionReports $report $runDirectory
    if (@($report.Results | Where-Object { $_.Result -ne 'PASS' }).Count -gt 0) { exit 3 }
    Write-Host "ALL PASS ($($report.Results.Count) test/seed runs). Reports: $runDirectory"
    exit 0
} catch {
    Write-Error -ErrorAction Continue $_
    if ($runDirectory) { Write-Host "Available diagnostics: $runDirectory" }
    exit 1
}
