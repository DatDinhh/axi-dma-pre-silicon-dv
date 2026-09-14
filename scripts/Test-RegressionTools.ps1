# Checks the evidence gate against failure modes that otherwise produce false PASS.
# Also verifies real process exit capture and wall-clock termination on this host.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RegressionTools.psm1') -Force -DisableNameChecking
$cleanProcess = [pscustomobject]@{ TimedOut = $false; ExitCode = 0 }
$cleanLog = "# UVM_INFO @ 1: test [DONE] example_test PASSED.`n# UVM_ERROR : 0`n# UVM_FATAL : 0`n"
if (Get-SimulationFailure $cleanProcess $cleanLog 'example_test PASSED' -RequireUvmSummary) { throw 'A clean completed test must pass.' }
$badLogs = @(
    $cleanLog.Replace('example_test PASSED.', 'example_test started.'),
    ($cleanLog + '# ** Fatal: DUT failed'),
    ($cleanLog + '# UVM_ERROR file.sv(5) @ 4: checker [BAD] mismatch'),
    $cleanLog.Replace('UVM_ERROR : 0', 'UVM_ERROR : 1'),
    $cleanLog.Replace('# UVM_FATAL : 0', ''),
    ($cleanLog + '# Error loading design'),
    ($cleanLog + '# SIGSEGV')
)
foreach ($badLog in $badLogs) {
    if (-not (Get-SimulationFailure $cleanProcess $badLog 'example_test PASSED' -RequireUvmSummary)) { throw "Incorrect PASS accepted: $badLog" }
}
if (-not (Get-SimulationFailure ([pscustomobject]@{ TimedOut = $false; ExitCode = 7 }) $cleanLog 'example_test PASSED')) { throw 'Nonzero process exit must fail.' }
if (-not (Get-SimulationFailure ([pscustomobject]@{ TimedOut = $true; ExitCode = 0 }) $cleanLog 'example_test PASSED')) { throw 'Timed out process must fail even when its exit code is zero.' }
$testDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) ('output\runner_check_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
$hostExecutable = (Get-Process -Id $PID).Path
$exitResult = Invoke-BoundedProcess $hostExecutable @('-NoProfile', '-Command', 'exit 7') $testDirectory (Join-Path $testDirectory 'nonzero') 10
if ($exitResult.ExitCode -ne 7 -or $exitResult.TimedOut) { throw 'Native exit code was not retained.' }
$childScript = Join-Path $testDirectory 'exit_three.ps1'
Set-Content -LiteralPath $childScript -Value 'exit 3' -Encoding ASCII
$fileExitResult = Invoke-BoundedProcess $hostExecutable @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript) $testDirectory (Join-Path $testDirectory 'file_exit_three') 10
if ($fileExitResult.ExitCode -ne 3 -or $fileExitResult.TimedOut) { throw 'Native -File regression failure exit code was not retained.' }
$timeoutResult = Invoke-BoundedProcess $hostExecutable @('-NoProfile', '-Command', 'Start-Sleep -Seconds 20') $testDirectory (Join-Path $testDirectory 'timeout') 1
if (-not $timeoutResult.TimedOut -or $timeoutResult.RuntimeSeconds -ge 15) { throw 'External wall timeout did not bound process lifetime.' }
@{ NonzeroExit = $exitResult; NativeFileFailureExit = $fileExitResult; Timeout = $timeoutResult; PowerShellVersion = $PSVersionTable.PSVersion.ToString() } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $testDirectory 'result.json') -Encoding UTF8
Write-Host "Runner failure-gate and real timeout checks PASSED. $testDirectory"
