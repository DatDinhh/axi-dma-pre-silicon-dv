<# ---------------------------------------------------------
run_regression.ps1
AXI DMA Pre-Silicon DV regression (ModelSim Intel FPGA 20.1)

Runs:
  smoke_test
  copy_test
  len_zero_test
  unaligned_addr_test
  out_of_range_test

Outputs:
  logs\compile.log
  logs\<test>.log
  logs\<test>.wlf

Exit codes:
  0 = all pass
  2 = compile failed
  3 = one or more tests failed
---------------------------------------------------------- #>

$ErrorActionPreference = "Stop"

# ---------------------------
# Config (edit if needed)
# ---------------------------
$VSIM = "C:\intelFPGA\20.1\modelsim_ase\win32aloem\vsim.exe"
$UVM  = "C:/intelFPGA/20.1/modelsim_ase/verilog_src/uvm-1.2/src"

# Use the directory where this script lives as project root
$PROJ = Split-Path -Parent $MyInvocation.MyCommand.Path

# Short TEMP directory reduces weird Windows path issues
$TEMP_DIR = "D:\msim_tmp"

# Test list
$tests = @(
  "smoke_test",
  "copy_test",
  "len_zero_test",
  "unaligned_addr_test",
  "out_of_range_test"
)

# ---------------------------
# Helpers
# ---------------------------
function To-FwdSlash([string]$p) {
  return ($p -replace "\\", "/")
}

function Run-VsimDo([string]$doText) {
  & $VSIM -c -do $doText | Out-Host
  return $LASTEXITCODE
}

function Tail([string]$file, [int]$n = 60) {
  if (Test-Path $file) { Get-Content $file -Tail $n }
}

# ---------------------------
# Pre-flight checks
# ---------------------------
if (!(Test-Path $VSIM)) {
  Write-Host "ERROR: vsim.exe not found at: $VSIM" -ForegroundColor Red
  exit 1
}
if (!(Test-Path (Join-Path $PROJ "filelist.f"))) {
  Write-Host "ERROR: filelist.f not found in: $PROJ" -ForegroundColor Red
  exit 1
}

Set-Location $PROJ
$PROJ_FWD = To-FwdSlash $PROJ

# TEMP/TMP
$env:TEMP = $TEMP_DIR
$env:TMP  = $TEMP_DIR
if (!(Test-Path $TEMP_DIR)) { New-Item -ItemType Directory -Path $TEMP_DIR | Out-Null }

# logs/
if (!(Test-Path ".\logs")) { New-Item -ItemType Directory -Path ".\logs" | Out-Null }

# Clean logs from previous run
Remove-Item ".\logs\*.log" -ErrorAction SilentlyContinue
Remove-Item ".\logs\*.wlf" -ErrorAction SilentlyContinue

# Clean work/ (fresh compile)
if (Test-Path ".\work") { Remove-Item -Recurse -Force ".\work" }

Write-Host "`n=============================="
Write-Host " AXI DMA Regression START"
Write-Host " Project: $PROJ"
Write-Host "==============================`n"

# ---------------------------
# Compile ONCE
# ---------------------------
Write-Host "=== [1/2] COMPILE ===" -ForegroundColor Cyan

$compileDo = @"
cd $PROJ_FWD
transcript file logs/compile.log

vlib work
vmap work work

vlog -sv +define+UVM_NO_DPI +incdir+$UVM $UVM/uvm_pkg.sv
vlog -sv +define+UVM_NO_DPI +incdir+$UVM -f filelist.f

quit -f
"@

Run-VsimDo $compileDo | Out-Null

if (!(Test-Path ".\logs\compile.log")) {
  Write-Host "COMPILE FAILED: no compile.log generated." -ForegroundColor Red
  exit 2
}

$compileTxt = Get-Content ".\logs\compile.log" -Raw
if ($compileTxt -match "vlog failed" -or
    $compileTxt -match "\*\*\s+Error" -or
    $compileTxt -match "Errors:\s*[1-9]") {
  Write-Host "`nCOMPILE FAILED. Tail of logs\compile.log:" -ForegroundColor Red
  Tail ".\logs\compile.log" 80 | Out-Host
  exit 2
}

Write-Host "COMPILE PASS ✅" -ForegroundColor Green

# ---------------------------
# Run tests
# ---------------------------
Write-Host "`n=== [2/2] RUN TESTS ===" -ForegroundColor Cyan

$results = @()

foreach ($t in $tests) {
  Write-Host "`n--- Running $t ---" -ForegroundColor Yellow

  $runDo = @"
cd $PROJ_FWD
transcript file logs/$t.log
vmap work work

vsim -wlf logs/$t.wlf work.tb_top +UVM_TESTNAME=$t +UVM_NO_RELNOTES
run -all
quit -f
"@

  Run-VsimDo $runDo | Out-Null

  $logPath = ".\logs\$t.log"
  if (!(Test-Path $logPath)) {
    $results += [pscustomobject]@{ Test = $t; Result = "FAIL"; Reason = "No log generated (vsim crash?)" }
    Write-Host "RESULT: $t FAIL (no log)" -ForegroundColor Red
    continue
  }

  $txt = Get-Content $logPath -Raw

  $hasPassLine = ($txt -match [regex]::Escape($t) + ".*PASSED")
  $noUvmErr    = ($txt -match "UVM_ERROR\s*:\s*0")
  $noUvmFatal  = ($txt -match "UVM_FATAL\s*:\s*0")
  $noLoadErr   = -not ($txt -match "Error loading design")
  $noSegv      = -not ($txt -match "SIGSEGV")

  if ($hasPassLine -and $noUvmErr -and $noUvmFatal -and $noLoadErr -and $noSegv) {
    $results += [pscustomobject]@{ Test = $t; Result = "PASS"; Reason = "" }
    Write-Host "RESULT: $t PASS " -ForegroundColor Green
  } else {
    $results += [pscustomobject]@{ Test = $t; Result = "FAIL"; Reason = "See logs\$t.log" }
    Write-Host "RESULT: $t FAIL  (see logs\$t.log)" -ForegroundColor Red
    Write-Host "---- Tail of logs\$t.log ----"
    Tail $logPath 60 | Out-Host
  }
}

# ---------------------------
# Summary
# ---------------------------
Write-Host "`n================ Regression Summary ================" -ForegroundColor Cyan
foreach ($r in $results) {
  $line = ("{0,-22} {1}" -f $r.Test, $r.Result)
  if ($r.Result -eq "PASS") { Write-Host $line -ForegroundColor Green }
  else                      { Write-Host $line -ForegroundColor Red }
}

$anyFail = $results | Where-Object { $_.Result -ne "PASS" }
if ($anyFail) {
  Write-Host "`nRegression: FAIL   (check logs\*.log)" -ForegroundColor Red
  exit 3
} else {
  Write-Host "`nRegression: ALL PASS " -ForegroundColor Green
  exit 0
}
