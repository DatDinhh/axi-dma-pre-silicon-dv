<#
.SYNOPSIS
Captures real VCD traces for the original AW/W deadlock and the repaired engine.
.DESCRIPTION
Both simulations use the same current package, interface and standalone test with
AW_MODE=0. Only the engine differs: an exact Git blob versus the working-tree file.
The original engine must hit ENGINE_TIMEOUT; that is recorded as a failing DUT,
not a clean regression pass. Source bytes, hashes, commands and raw logs are kept
under out/wave_capture_<unique id>. No existing output is overwritten.
.EXAMPLE
.\scripts\capture_axi_write_evidence.ps1 -VsimPath C:\tools\modelsim\win64\vsim.exe
#>
[CmdletBinding()]
param(
    [string]$VsimPath,
    [string]$UvmPath,
    [string]$BeforeRevision = 'c5f730ddb48d09e6effee9ebe9ac23aac5003cc1',
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RegressionTools.psm1') -Force -DisableNameChecking
$projectRoot = Split-Path -Parent $PSScriptRoot
$runDirectory = $null
$report = $null

function Save-GitBlob([string]$GitPath, [string]$ObjectName, [string]$Destination) {
    # Copy the binary stdout stream so shell encodings/newlines cannot alter RTL.
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $GitPath
    $info.Arguments = (@('-C', $projectRoot, 'cat-file', 'blob', $ObjectName) |
        ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $stream = [IO.File]::Create($Destination)
    try {
        if (-not $process.Start()) { throw 'Could not start Git blob extraction.' }
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($stream)
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'Git blob extraction timed out.'
        }
        $null = $copyTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Git blob extraction failed: $errorText" }
    } finally {
        $stream.Dispose()
        $process.Dispose()
    }
}

function Get-SourceRecord([string]$SnapshotRoot, [string]$RelativePath) {
    $path = Join-Path $SnapshotRoot $RelativePath
    [pscustomobject]@{
        Path = $RelativePath.Replace('\', '/')
        Bytes = (Get-Item -LiteralPath $path).Length
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Save-CaptureReport {
    $report | ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath (Join-Path $runDirectory 'summary.json') -Encoding UTF8
}

try {
    $simulator = Resolve-Simulator $VsimPath $UvmPath
    $git = (Get-Command git -ErrorAction Stop).Source
    $beforeCommit = [string](& $git -C $projectRoot rev-parse --verify ($BeforeRevision + '^{commit}'))
    if ($LASTEXITCODE -ne 0) { throw "The original engine revision is unavailable: $BeforeRevision" }
    $beforeBlob = [string](& $git -C $projectRoot rev-parse ($beforeCommit + ':rtl/dma_engine_axi.sv'))
    if ($LASTEXITCODE -ne 0) { throw 'The original revision has no engine source.' }
    $head = [string](& $git -C $projectRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the current Git revision.' }
    $dirty = -not [string]::IsNullOrWhiteSpace(((& $git -C $projectRoot status --porcelain) -join "`n"))
    $runId = 'wave_capture_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $runDirectory = Join-Path $projectRoot ('out\' + $runId)
    New-Item -ItemType Directory -Path $runDirectory | Out-Null
    $versionProcess = Invoke-BoundedProcess -Executable $simulator.VsimPath -Arguments @('-version') -WorkingDirectory $runDirectory -LogPrefix (Join-Path $runDirectory 'version') -TimeoutSeconds 30
    if ($versionProcess.TimedOut -or $versionProcess.ExitCode -ne 0) { throw 'Simulator version query failed.' }
    $version = (Read-Logs @($versionProcess.StdoutPath, $versionProcess.StderrPath)).Trim()
    $sources = @('rtl/dma_pkg.sv', 'rtl/dma_engine_axi.sv',
        'tb/interfaces/axi_if.sv', 'tb/unit/engine_aw_w_test.sv')
    $signals = @('clk', 'rst_n', 'start', 'busy', 'accept', 'done', 'err',
        'remain', 'err_code', 'cycles', 'aw_cycle', 'w_cycle', 'write_age',
        'aw_seen', 'w_seen', 'dut/state',
        'axi/awvalid', 'axi/awready', 'axi/awaddr',
        'axi/wvalid', 'axi/wready', 'axi/wdata', 'axi/wstrb', 'axi/wlast',
        'axi/bvalid', 'axi/bready', 'axi/bresp',
        'axi/arvalid', 'axi/arready', 'axi/araddr',
        'axi/rvalid', 'axi/rready', 'axi/rdata', 'axi/rresp', 'axi/rlast')
    $report = [pscustomobject]@{
        SchemaVersion = 1; Mode = 'axi-write-waveform-comparison'; RunId = $runId
        StartedUtc = [DateTime]::UtcNow.ToString('o'); CompletedUtc = $null
        Result = 'INCOMPLETE'; Reason = ''; DutRegression = $false
        GitRevision = $head; GitDirty = $dirty
        BeforeRevision = $beforeCommit; BeforeEngineGitBlob = $beforeBlob
        BeforeEngineOrigin = 'Exact Git blob; all other sources are current working-tree bytes.'
        AfterEngineOrigin = 'Current working-tree bytes; GitRevision alone is not a source fingerprint.'
        ToolVersion = $version; VsimPath = $simulator.VsimPath
        UvmUsed = $false; CoverageEnabled = $false
        OutputDirectory = $runDirectory; TimeoutSeconds = $TimeoutSeconds
        SimulationLimitNs = 1100; Top = 'engine_aw_w_test'; PlusArgs = @('+AW_MODE=0')
        CompletionExitPolicy = 'On simulator break, flush VCD and exit 0 if DONE is high, otherwise 3. Logs and exact outcome markers are checked independently.'
        Signals = $signals; SourceFiles = $sources; DifferentEngineOnly = $false
        RunnerSources = @(); Results = @()
    }
    $runnerRoot = Join-Path $runDirectory 'runner'
    New-Item -ItemType Directory -Path $runnerRoot | Out-Null
    foreach ($runnerFile in @('capture_axi_write_evidence.ps1', 'RegressionTools.psm1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $runnerFile) -Destination (Join-Path $runnerRoot $runnerFile)
        $report.RunnerSources += Get-SourceRecord $runnerRoot $runnerFile
    }
    # Freeze the shared inputs once, then copy identical bytes into each run.
    $sharedRoot = Join-Path $runDirectory 'shared_source'
    foreach ($source in $sources) {
        $destination = Join-Path $sharedRoot $source
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot $source) -Destination $destination
    }
    Write-Host "Waveform capture: $runDirectory"
    foreach ($name in @('before', 'after')) {
        $caseDirectory = Join-Path $runDirectory $name
        $iniPath = New-SimulationDirectory $caseDirectory $simulator.VendorIni
        $snapshotRoot = Join-Path $caseDirectory 'source'
        foreach ($source in $sources) {
            $destination = Join-Path $snapshotRoot $source
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $sharedRoot $source) -Destination $destination
        }
        if ($name -eq 'before') {
            $beforePath = Join-Path $snapshotRoot 'rtl/dma_engine_axi.sv'
            Save-GitBlob $git ($beforeCommit + ':rtl/dma_engine_axi.sv') $beforePath
            $extractedBlob = [string](& $git -C $projectRoot hash-object --no-filters $beforePath)
            if ($LASTEXITCODE -ne 0 -or $extractedBlob -ne $beforeBlob) {
                throw 'Extracted engine bytes do not match the original Git blob.'
            }
        }
        $sourceRecords = @($sources | ForEach-Object { Get-SourceRecord $snapshotRoot $_ })
        $sourceRecords | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $caseDirectory 'source_manifest.json') -Encoding UTF8
        $sourceArgs = ($sources | ForEach-Object { ConvertTo-TclWord (Join-Path $snapshotRoot $_) }) -join ' '
        $compileLog = Join-Path $caseDirectory 'compile.log'
        $compileDo = @"
onerror {quit -f -code 2}
onbreak {quit -f -code 2}
transcript file $(ConvertTo-TclWord $compileLog)
vlib $(ConvertTo-TclWord (Join-Path $caseDirectory 'work'))
vlog -sv $sourceArgs
puts {WAVE_COMPILE_PASS}
quit -f -code 0
"@
        $compile = Invoke-SimulationDo $simulator $caseDirectory $iniPath 'compile' $compileDo $TimeoutSeconds
        $compileText = Read-Logs @($compileLog, $compile.StdoutPath, $compile.StderrPath)
        $reason = Get-SimulationFailure -Process $compile -Text $compileText -PassMarker 'WAVE_COMPILE_PASS'
        $entry = [pscustomobject]@{
            Name = $name; Result = 'INCOMPLETE'; DutResult = 'NOT_RUN'; Reason = $reason
            Sources = $sourceRecords
            Compile = [pscustomobject]@{ ExitCode=$compile.ExitCode; TimedOut=$compile.TimedOut; LogPath=$compileLog }
            Simulation = $null; VcdPath = (Join-Path $runDirectory ($name + '.vcd')); VcdSha256 = $null
        }
        $report.Results += $entry
        Save-CaptureReport
        if ($reason) { throw "$name compile failed: $reason" }
        $simulationLog = Join-Path $caseDirectory 'simulation.log'
        $vcdSignals = ($signals | ForEach-Object { ConvertTo-TclWord ('/engine_aw_w_test/' + $_) }) -join ' '
        $simulateDo = @"
onerror {quit -f -code 3}
onbreak {vcd flush; if {[examine -radix unsigned /engine_aw_w_test/done] == 1} {quit -f -code 0} else {quit -f -code 3}}
transcript file $(ConvertTo-TclWord $simulationLog)
vsim -onfinish stop -voptargs=+acc work.engine_aw_w_test +AW_MODE=0
vcd file $(ConvertTo-TclWord $entry.VcdPath)
vcd add $vcdSignals
run 1100 ns
vcd flush
quit -f -code 0
"@
        $simulation = Invoke-SimulationDo $simulator $caseDirectory $iniPath 'simulate' $simulateDo $TimeoutSeconds
        $simulationText = Read-Logs @($simulationLog, $simulation.StdoutPath, $simulation.StderrPath)
        $entry.Simulation = [pscustomobject]@{
            ExitCode=$simulation.ExitCode; TimedOut=$simulation.TimedOut
            RuntimeSeconds=$simulation.RuntimeSeconds; LogPath=$simulationLog
        }
        $reason = ''
        if ($simulation.TimedOut) { $reason = 'External wall-clock timeout expired.' }
        elseif ($simulationText -match 'SIGSEGV|Segmentation fault|Internal (error|fatal)|Error loading design') {
            $reason = 'Simulator failed before a trustworthy trace was captured.'
        } elseif ($name -eq 'before') {
            $expected = 'ENGINE_TIMEOUT mode=0 AWVALID=1 AWREADY=0 WVALID=0 WREADY=1'
            if ($simulation.ExitCode -ne 3 -or $simulationText -notmatch [regex]::Escape($expected) -or
                $simulationText -notmatch 'Time:\s*1060 ns' -or $simulationText -match '\bUNIT_PASS\b') {
                $reason = 'Original engine did not produce the exact expected deadlock timeout.'
            } else { $entry.DutResult = 'EXPECTED_FAIL_ENGINE_TIMEOUT' }
        } else {
            $reason = Get-SimulationFailure -Process $simulation -Text $simulationText -PassMarker 'UNIT_PASS'
            if (-not $reason -and $simulationText -notmatch 'UNIT_PASS mode=0 AW_cycle=12 W_cycle=8') {
                $reason = 'Repaired engine did not produce the expected W-before-AW completion.'
            }
            if (-not $reason) { $entry.DutResult = 'PASS' }
        }
        if (-not (Test-Path -LiteralPath $entry.VcdPath) -or (Get-Item -LiteralPath $entry.VcdPath).Length -eq 0) {
            $reason = 'VCD trace is missing or empty.'
        } else {
            $vcdText = Get-Content -LiteralPath $entry.VcdPath -Raw
            if ($vcdText -notmatch '\$enddefinitions\s+\$end' -or $vcdText -notmatch '(?m)^#\d+') {
                $reason = 'VCD trace has no definitions or simulation timestamps.'
            }
            $entry.VcdSha256 = (Get-FileHash -LiteralPath $entry.VcdPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $entry.Reason = $reason
        $entry.Result = $(if ($reason) { 'FAIL' } else { 'CAPTURED_EXPECTED_OUTCOME' })
        Save-CaptureReport
        Write-Host "$name : $($entry.DutResult), simulator exit $($simulation.ExitCode)"
        if ($reason) { throw "$name capture failed: $reason" }
    }
    $differences = @()
    foreach ($source in $sources) {
        $beforeHash = ($report.Results[0].Sources | Where-Object { $_.Path -eq $source }).Sha256
        $afterHash = ($report.Results[1].Sources | Where-Object { $_.Path -eq $source }).Sha256
        if ($beforeHash -ne $afterHash) { $differences += $source }
    }
    $report.DifferentEngineOnly = ($differences.Count -eq 1 -and $differences[0] -eq 'rtl/dma_engine_axi.sv')
    if (-not $report.DifferentEngineOnly) { throw 'Comparison does not differ in exactly the engine source.' }
    $report.Result = 'PASS_EVIDENCE_CAPTURE'
    $report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    Save-CaptureReport
    Write-Host "Captured both expected outcomes. Summary: $(Join-Path $runDirectory 'summary.json')"
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    if ($report -and $runDirectory) {
        $report.Result = 'FAIL'; $report.Reason = [string]$_
        $report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Save-CaptureReport
    }
    exit 1
}
