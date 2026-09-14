<#
.SYNOPSIS
Controlled, fixed-size A/B study of the legacy simulator DPI-export loader.
.DESCRIPTION
Copies an already compiled evidence library; never edits historical evidence.
Each trial is a separate process. All trials, including crashes, remain reported.
This is a diagnostic, not a replacement for the project regression.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
    [string]$VsimPath,
    [ValidateRange(1,30)][int]$Repetitions = 3,
    [string[]]$Variants = @('standard','no-exports'),
    [string]$TestName = 'out_of_range_test',
    [int]$Seed = 1
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($TestName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Invalid test name.' }
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $projectRoot 'scripts/RegressionTools.psm1') -Force -DisableNameChecking
$evidence = (Resolve-Path -LiteralPath $EvidenceDirectory).Path
$simulator = Resolve-Simulator $VsimPath ''
$VsimPath = $simulator.VsimPath
$id = 'loader-study-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$directory = Join-Path $projectRoot ('output/' + $id)
$ini = New-SimulationDirectory $directory $simulator.VendorIni
Copy-Item -LiteralPath (Join-Path $evidence 'work') -Destination $directory -Recurse
Copy-Item -LiteralPath (Join-Path $evidence 'source_manifest.json') -Destination (Join-Path $directory 'input_source_manifest.json')
& $VsimPath -help '-nodpiexports' | Set-Content -LiteralPath (Join-Path $directory 'noexports-help.txt') -Encoding ASCII
$results = @()
Write-Host "Output: $directory"
foreach ($repetition in 1..$Repetitions) {
    foreach ($variant in $Variants) {
        $loadOption = switch ($variant) {
            'standard' { '' }
            'no-exports' { '-nodpiexports' }
            'no-vopt' { '-novopt' }
            default { throw "Unsupported diagnostic variant '$variant'" }
        }
        $trial = Join-Path $directory ($variant + '-' + $repetition)
        New-Item -ItemType Directory -Path $trial -Force | Out-Null
        $log = Join-Path $trial 'simulation.log'
        $do = @"
onerror {quit -f -code 3}
onbreak {resume}
transcript file $(ConvertTo-TclWord $log)
vsim -onfinish stop -sv_seed $Seed $loadOption -wlf $(ConvertTo-TclWord (Join-Path $trial 'waves.wlf')) work.tb_top +UVM_TESTNAME=$TestName +UVM_NO_RELNOTES +TEST_SEED=$Seed +AXI_AW_WAIT_W=1 +AXI_STALL_MAX=7 +AXI_STALL_SEED=$Seed
run -all
quit -f -code 0
"@
        $process = Invoke-SimulationDo $simulator $trial $ini 'run' $do 90
        $text = Read-Logs @($log, $process.StdoutPath, $process.StderrPath)
        $reason = Get-SimulationFailure -Process $process -Text $text -PassMarker ($TestName + ' PASSED') -RequireUvmSummary
        $status = if ($reason) { 'FAIL' } else { 'PASS' }
        $results += [pscustomobject]@{ Variant=$variant; Repetition=$repetition; Test=$TestName; Seed=$Seed; Result=$status; Reason=$reason; ExitCode=$process.ExitCode; TimedOut=$process.TimedOut; RuntimeSeconds=$process.RuntimeSeconds; ExportDllLoaded=($text -match '(?im)^# Loading .*export_tramp.dll'); LogPath=$log }
        [pscustomobject]@{ SourceEvidence=$evidence; Simulator=$VsimPath; FixedRepetitions=$Repetitions; Results=$results } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $directory 'study.json') -Encoding UTF8
        Write-Host "$variant trial=$repetition : $status export-loaded=$($results[-1].ExportDllLoaded) $reason"
    }
}
