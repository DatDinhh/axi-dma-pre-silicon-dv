<#
.SYNOPSIS
Runs standalone RTL/responder/checker units separately from the UVM DUT suite.
.DESCRIPTION
Preserves each invocation under out/unit_<unique id>. Checks native
failures, UNIT_PASS, and explicit UVM report counts for checker self-tests.
The deliberate checker violation is PASS_EXPECTED_DETECTION and is never
counted as an ordinary clean DUT regression. No files are deleted.
Exit codes: 0 all selected units meet expectations; 1 setup error; 2 compile
failure; 3 failed unit or timeout.
.EXAMPLE
.\scripts\run_unit_checks.ps1
.EXAMPLE
.\scripts\run_unit_checks.ps1 -Cases engine_w_before_aw,regs_event
#>
[CmdletBinding()]
param(
    [string[]]$Cases = @(),
    [string]$VsimPath,
    [string]$UvmPath,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RegressionTools.psm1') -Force -DisableNameChecking
$projectRoot = Split-Path -Parent $PSScriptRoot
$runDirectory = $null
$report = $null
try {
    $allCases = @(
        @{ Name='engine_w_before_aw'; Top='engine_aw_w_test'; Args=@('+AW_MODE=0'); Kind='rtl_unit'; Errors=$null },
        @{ Name='engine_aw_before_w'; Top='engine_aw_w_test'; Args=@('+AW_MODE=1'); Kind='rtl_unit'; Errors=$null },
        @{ Name='engine_aw_w_together'; Top='engine_aw_w_test'; Args=@('+AW_MODE=2'); Kind='rtl_unit'; Errors=$null },
        @{ Name='engine_rresp'; Top='engine_aw_w_test'; Args=@('+RRESP=2'); Kind='rtl_unit'; Errors=$null },
        @{ Name='engine_bresp'; Top='engine_aw_w_test'; Args=@('+BRESP=2'); Kind='rtl_unit'; Errors=$null },
        @{ Name='engine_rlast'; Top='engine_aw_w_test'; Args=@('+BAD_RLAST=1'); Kind='rtl_unit'; Errors=$null },
        @{ Name='memory_default'; Top='mem_model_test'; Args=@(); Kind='responder_self_test'; Errors=$null },
        @{ Name='memory_seed1'; Top='mem_model_test'; Args=@('+AXI_AW_WAIT_W=1','+AXI_STALL_MAX=5','+AXI_STALL_SEED=1'); Kind='responder_self_test'; Errors=$null },
        @{ Name='memory_seed99'; Top='mem_model_test'; Args=@('+AXI_AW_WAIT_W=1','+AXI_STALL_MAX=5','+AXI_STALL_SEED=99'); Kind='responder_self_test'; Errors=$null },
        @{ Name='memory_errors_seed42'; Top='mem_model_test'; Args=@('+AXI_AW_WAIT_W=1','+AXI_STALL_MAX=7','+AXI_STALL_SEED=42','+AXI_BERR_ADDR=204','+AXI_RERR_ADDR=204'); Kind='responder_self_test'; Errors=$null },
        @{ Name='memory_errors_seed42_replay'; Top='mem_model_test'; Args=@('+AXI_AW_WAIT_W=1','+AXI_STALL_MAX=7','+AXI_STALL_SEED=42','+AXI_BERR_ADDR=204','+AXI_RERR_ADDR=204'); Kind='responder_self_test'; Errors=$null },
        @{ Name='checker_clean'; Top='rv_stability_test'; Args=@('+INJECT_STALL_ERROR=0'); Kind='checker_self_test'; Errors=0 },
        @{ Name='checker_expected_violation'; Top='rv_stability_test'; Args=@('+INJECT_STALL_ERROR=1'); Kind='expected_checker_detection'; Errors=1 },
        @{ Name='regs_event'; Top='regs_event_test'; Args=@(); Kind='rtl_unit'; Errors=$null }
    )
    if ($Cases.Count -gt 0) {
        foreach ($caseName in $Cases) {
            if ($caseName -notin @($allCases | ForEach-Object { $_.Name })) { throw "Unknown unit case: $caseName" }
        }
        $selectedCases = @($allCases | Where-Object { $_.Name -in $Cases })
    } else { $selectedCases = $allCases }
    $simulator = Resolve-Simulator $VsimPath $UvmPath
    $runId = 'unit_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $runDirectory = Join-Path $projectRoot ('out\' + $runId)
    $iniPath = New-SimulationDirectory $runDirectory $simulator.VendorIni
    $versionProcess = Invoke-BoundedProcess -Executable $simulator.VsimPath -Arguments @('-version') -WorkingDirectory $runDirectory -LogPrefix (Join-Path $runDirectory 'version') -TimeoutSeconds 30
    if ($versionProcess.TimedOut -or $versionProcess.ExitCode -ne 0) { throw 'Simulator version query failed.' }
    $version = (Read-Logs @($versionProcess.StdoutPath, $versionProcess.StderrPath)).Trim()
    $revision = 'unavailable'; $dirty = $null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $revisionOutput = & git -C $projectRoot rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) { $revision = [string]$revisionOutput }
        $statusOutput = & git -C $projectRoot status --porcelain 2>$null
        if ($LASTEXITCODE -eq 0) { $dirty = -not [string]::IsNullOrWhiteSpace(($statusOutput -join "`n")) }
    }
    $report = [pscustomobject]@{
        SchemaVersion=1; Mode='standalone-unit-checks'; DutRegression=$false; RunId=$runId
        StartedUtc=[DateTime]::UtcNow.ToString('o'); CompletedUtc=$null
        GitRevision=$revision; GitDirty=$dirty; ToolVersion=$version
        VsimPath=$simulator.VsimPath; UvmPath=$simulator.UvmPath
        CoverageEnabled=$false; SvaEnabled=$false; TimeoutSeconds=$TimeoutSeconds
        OutputDirectory=$runDirectory; Compile=$null; Results=@()
    }
    Write-Host "Unit output: $runDirectory"
    $uvmInclude = ConvertTo-TclWord ('+incdir+' + $simulator.UvmPath)
    $uvmSource = ConvertTo-TclWord (Join-Path $simulator.UvmPath 'uvm_pkg.sv')
    $sources = @('rtl/dma_pkg.sv','rtl/dma_regs_axil.sv','rtl/dma_engine_axi.sv',
        'tb/interfaces/axi_if.sv','tb/interfaces/axil_if.sv','tb/mem/mem_bkdr_if.sv',
        'tb/mem/axi_mem_model.sv','tb/checkers/dma_protocol_checks.sv',
        'tb/unit/engine_aw_w_test.sv','tb/unit/mem_model_test.sv',
        'tb/unit/rv_stability_test.sv','tb/unit/regs_event_test.sv')
    $sourceArgs = ($sources | ForEach-Object { ConvertTo-TclWord (Join-Path $projectRoot $_) }) -join ' '
    $compileLog = Join-Path $runDirectory 'compile.log'
    $compileDo = @"
onerror {quit -f -code 2}
onbreak {quit -f -code 2}
transcript file $(ConvertTo-TclWord $compileLog)
vlib $(ConvertTo-TclWord (Join-Path $runDirectory 'work'))
vlog -sv +define+UVM_NO_DPI $uvmInclude $uvmSource
vlog -sv +define+UVM_NO_DPI $uvmInclude $sourceArgs
puts {UNIT_COMPILE_PASS}
quit -f -code 0
"@
    $process = Invoke-SimulationDo $simulator $runDirectory $iniPath 'compile' $compileDo $TimeoutSeconds
    $compileText = Read-Logs @($compileLog, $process.StdoutPath, $process.StderrPath)
    $reason = Get-SimulationFailure -Process $process -Text $compileText -PassMarker 'UNIT_COMPILE_PASS'
    $report.Compile = [pscustomobject]@{ Result=$(if ($reason) {'FAIL'} else {'PASS'}); Reason=$reason; ExitCode=$process.ExitCode; TimedOut=$process.TimedOut; LogPath=$compileLog }
    if ($reason) {
        $report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Write-RegressionReports $report $runDirectory
        Write-Error "Unit compile failed: $reason" -ErrorAction Continue
        exit 2
    }
    foreach ($unitCase in $selectedCases) {
        $caseLog = Join-Path $runDirectory ($unitCase.Name + '.log')
        $plusArgs = ($unitCase.Args | ForEach-Object { ConvertTo-TclWord $_ }) -join ' '
        $unitDo = @"
onerror {quit -f -code 3}
onbreak {resume}
transcript file $(ConvertTo-TclWord $caseLog)
vsim -onfinish stop work.$($unitCase.Top) $plusArgs
run -all
quit -f -code 0
"@
        $process = Invoke-SimulationDo $simulator $runDirectory $iniPath $unitCase.Name $unitDo $TimeoutSeconds
        $unitText = Read-Logs @($caseLog, $process.StdoutPath, $process.StderrPath)
        $reason = Get-SimulationFailure -Process $process -Text $unitText -PassMarker 'UNIT_PASS'
        if (-not $reason -and $null -ne $unitCase.Errors) {
            $errorCounts = @([regex]::Matches($unitText, 'UVM_ERROR\s*:\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
            $fatalCounts = @([regex]::Matches($unitText, 'UVM_FATAL\s*:\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
            if ($errorCounts.Count -eq 0 -or $fatalCounts.Count -eq 0 -or
                @($errorCounts | Where-Object { $_ -ne $unitCase.Errors }).Count -gt 0 -or
                @($fatalCounts | Where-Object { $_ -ne 0 }).Count -gt 0) {
                $reason = "Checker reports did not match expected UVM_ERROR=$($unitCase.Errors), UVM_FATAL=0."
            }
        }
        $result = 'PASS'
        if ($reason) { $result = 'FAIL' }
        elseif ($unitCase.Kind -eq 'expected_checker_detection') { $result = 'PASS_EXPECTED_DETECTION' }
        $entry = [pscustomobject]@{
            Test=$unitCase.Name; Top=$unitCase.Top; Kind=$unitCase.Kind; Seed=1
            PlusArgs=$unitCase.Args; ExpectedUvmErrors=$unitCase.Errors
            Result=$result; Reason=$reason; ExitCode=$process.ExitCode; TimedOut=$process.TimedOut
            RuntimeSeconds=$process.RuntimeSeconds; LogPath=$caseLog
        }
        $report.Results += $entry
        $entry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDirectory ($unitCase.Name + '.result.json')) -Encoding UTF8
        Write-Host "$($unitCase.Name): $result $reason"
    }
    # Replay check supplements each responder test's data/protocol checks.
    $original = @($report.Results | Where-Object { $_.Test -eq 'memory_errors_seed42' })
    $replay = @($report.Results | Where-Object { $_.Test -eq 'memory_errors_seed42_replay' })
    if ($original.Count -eq 1 -and $replay.Count -eq 1 -and $original[0].Result -eq 'PASS' -and $replay[0].Result -eq 'PASS') {
        $firstText = Read-Logs @($original[0].LogPath)
        $secondText = Read-Logs @($replay[0].LogPath)
        $firstCycle = [regex]::Match($firstText, 'UNIT_PASS[^\r\n]*cycles=(\d+)').Groups[1].Value
        $secondCycle = [regex]::Match($secondText, 'UNIT_PASS[^\r\n]*cycles=(\d+)').Groups[1].Value
        if (-not $firstCycle -or $firstCycle -ne $secondCycle) {
            $replay[0].Result = 'FAIL'; $replay[0].Reason = 'Same seeded responder stimulus did not reproduce cycle count.'
            $replay[0] | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDirectory 'memory_errors_seed42_replay.result.json') -Encoding UTF8
        }
    }
    $report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    Write-RegressionReports $report $runDirectory
    $failed = @($report.Results | Where-Object { $_.Result -eq 'FAIL' }).Count
    Write-Host "Unit checks: $($report.Results.Count - $failed)/$($report.Results.Count) met expectations. Summary: $(Join-Path $runDirectory 'summary.json')"
    if ($failed) { exit 3 }
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    if ($report -and $runDirectory) {
        $report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Write-RegressionReports $report $runDirectory
    }
    exit 1
}
