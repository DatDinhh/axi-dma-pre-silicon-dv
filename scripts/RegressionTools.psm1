Set-StrictMode -Version 2.0

function ConvertTo-TclWord([string]$Value) {
    # Tcl braced words preserve $, semicolons, spaces and quotes literally.
    $valueWithSlashes = $Value.Replace('\', '/')
    if ($valueWithSlashes -match '[{}\r\n]') { throw "Unsupported Tcl argument: braces/newlines are not allowed." }
    return '{' + $valueWithSlashes + '}'
}

function ConvertTo-NativeArgument([string]$Value) {
    # Windows CommandLineToArgvW quoting; also works for our simple Unix argv.
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
        } else {
            [void]$builder.Append(('\' * $slashes))
        }
        [void]$builder.Append($character)
        $slashes = 0
    }
    [void]$builder.Append(('\' * (2 * $slashes)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-BoundedProcess {
    param([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory,
          [string]$LogPrefix, [int]$TimeoutSeconds = 180)
    $stdout = $LogPrefix + '.stdout.log'
    $stderr = $LogPrefix + '.stderr.log'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $startOptions = @{
        FilePath = $Executable
        ArgumentList = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
        WorkingDirectory = $WorkingDirectory
        RedirectStandardOutput = $stdout
        RedirectStandardError = $stderr
        PassThru = $true
    }
    if ($isWindowsHost) { $startOptions.WindowStyle = 'Hidden' }
    $process = Start-Process @startOptions
    # Retain the process handle before it exits, including very short version queries.
    $null = $process.Handle
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        if ($isWindowsHost) {
            & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F 2>&1 | Out-Null
        } else {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        if (-not $process.WaitForExit(10000)) { throw "Could not terminate timed-out process $($process.Id)." }
    } else {
        $process.WaitForExit()
    }
    $timer.Stop()
    $exitCode = $null
    if ($process.HasExited) { $exitCode = $process.ExitCode }
    [pscustomobject]@{
        ExitCode = $exitCode; TimedOut = $timedOut
        RuntimeSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        StdoutPath = $stdout; StderrPath = $stderr
    }
}

function Read-Logs([string[]]$Paths) {
    return (($Paths | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
        Get-Content -LiteralPath $_ -Raw
    }) -join "`n")
}

function Resolve-Simulator([string]$VsimPath, [string]$UvmPath) {
    if ([string]::IsNullOrWhiteSpace($VsimPath)) {
        $command = Get-Command vsim -ErrorAction SilentlyContinue
        if (-not $command) { $command = Get-Command vsim.exe -ErrorAction SilentlyContinue }
        if (-not $command) { throw 'vsim was not found on PATH. Supply -VsimPath with its executable path.' }
        $VsimPath = $command.Source
    } elseif (Test-Path -LiteralPath $VsimPath -PathType Container) {
        $name = 'vsim'
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $name = 'vsim.exe' }
        $VsimPath = Join-Path $VsimPath $name
    }
    $VsimPath = (Resolve-Path -LiteralPath $VsimPath -ErrorAction Stop).Path
    $installRoot = Split-Path -Parent (Split-Path -Parent $VsimPath)
    $vendorIni = Join-Path $installRoot 'modelsim.ini'
    if (-not (Test-Path -LiteralPath $vendorIni)) { throw "Simulator modelsim.ini not found at $vendorIni" }
    if ([string]::IsNullOrWhiteSpace($UvmPath)) {
        $sourceRoot = Join-Path $installRoot 'verilog_src'
        $candidates = @(Get-ChildItem -LiteralPath $sourceRoot -Directory -Filter 'uvm*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($candidate in $candidates) {
            $candidateSource = Join-Path $candidate.FullName 'src'
            if (Test-Path -LiteralPath (Join-Path $candidateSource 'uvm_pkg.sv')) { $UvmPath = $candidateSource; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($UvmPath) -or -not (Test-Path -LiteralPath (Join-Path $UvmPath 'uvm_pkg.sv'))) {
        throw 'UVM sources were not found beside the simulator. Supply -UvmPath pointing to the UVM src directory.'
    }
    [pscustomobject]@{ VsimPath = $VsimPath; UvmPath = (Resolve-Path -LiteralPath $UvmPath).Path; VendorIni = $vendorIni }
}

function New-SimulationDirectory([string]$Directory, [string]$VendorIni) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $workPath = Join-Path $Directory 'work'
    $iniPath = Join-Path $Directory 'modelsim.ini'
    $iniText = "[Library]`nwork = $($workPath.Replace('\', '/'))`nothers = $($VendorIni.Replace('\', '/'))`n"
    Set-Content -LiteralPath $iniPath -Value $iniText -Encoding ASCII
    return $iniPath
}

function Invoke-SimulationDo {
    param([object]$Simulator, [string]$Directory, [string]$IniPath,
          [string]$Name, [string]$DoText, [int]$TimeoutSeconds)
    $doPath = Join-Path $Directory ($Name + '.do')
    Set-Content -LiteralPath $doPath -Value $DoText -Encoding ASCII
    # Keep ModelSim's generated DLL paths short; it creates PID-specific children.
    $tempDirectory = Join-Path (Split-Path -Parent $IniPath) 'tmp'
    New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
    $savedTemp = $env:TEMP
    $savedTmp = $env:TMP
    $savedModelsim = $env:MODELSIM
    try {
        $env:TEMP = $tempDirectory
        $env:TMP = $tempDirectory
        $env:MODELSIM = $IniPath
        return Invoke-BoundedProcess -Executable $Simulator.VsimPath -Arguments @('-c', '-modelsimini', $IniPath, '-l', (Join-Path $Directory ($Name + '.startup.log')), '-do', ('do ' + (ConvertTo-TclWord $doPath))) -WorkingDirectory $Directory -LogPrefix (Join-Path $Directory $Name) -TimeoutSeconds $TimeoutSeconds
    } finally {
        $env:TEMP = $savedTemp
        $env:TMP = $savedTmp
        $env:MODELSIM = $savedModelsim
    }
}

function Get-SimulationFailure([object]$Process, [string]$Text, [string]$PassMarker, [switch]$RequireUvmSummary) {
    if ($Process.TimedOut) { return 'External wall-clock timeout expired.' }
    if ($null -eq $Process.ExitCode -or $Process.ExitCode -ne 0) { return "Simulator exited with code $($Process.ExitCode)." }
    if ($Text -match '(?im)^\s*#?\s*\*\*\s+(Error|Fatal):|Error loading design|SIGSEGV|Segmentation fault|Internal (error|fatal)|vlog failed|Errors:\s*[1-9]') { return 'Simulator reported an error, fatal, or crash.' }
    if ($RequireUvmSummary) {
        if ($Text -match '(?im)^\s*#?\s*UVM_(ERROR|FATAL)\s+(?!\s*:\s*0\s*$)\S') { return 'UVM reported an error or fatal.' }
        if ($Text -match 'UVM_(ERROR|FATAL)\s*:\s*[1-9]') { return 'UVM summary contains errors or fatals.' }
        if ($Text -notmatch 'UVM_ERROR\s*:\s*0' -or $Text -notmatch 'UVM_FATAL\s*:\s*0') { return 'Clean UVM report summary is missing.' }
    }
    if ($PassMarker -and $Text -notmatch ('(?m)\b' + [regex]::Escape($PassMarker) + '(?:\.|\s|$)')) { return "Required completion marker '$PassMarker' is missing." }
    return ''
}

function Write-RegressionReports([object]$Report, [string]$Directory) {
    $Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Directory 'summary.json') -Encoding UTF8
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [Xml.XmlWriter]::Create((Join-Path $Directory 'junit.xml'), $settings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('testsuite')
        $writer.WriteAttributeString('name', $Report.Mode)
        $writer.WriteAttributeString('tests', [string]@($Report.Results).Count)
        $writer.WriteAttributeString('failures', [string]@($Report.Results | Where-Object { $_.Result -eq 'FAIL' }).Count)
        $writer.WriteAttributeString('skipped', [string]@($Report.Results | Where-Object { $_.Result -in @('UNSUPPORTED', 'UNAVAILABLE', 'INCONCLUSIVE') }).Count)
        $writer.WriteStartElement('properties')
        foreach ($key in @('GitRevision', 'GitDirty', 'ToolVersion', 'VsimPath', 'UvmPath', 'CoverageEnabled', 'SvaEnabled')) {
            $writer.WriteStartElement('property'); $writer.WriteAttributeString('name', $key); $writer.WriteAttributeString('value', [string]$Report.$key); $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
        foreach ($result in @($Report.Results)) {
            $writer.WriteStartElement('testcase')
            $writer.WriteAttributeString('name', ($result.Test + '.seed_' + $result.Seed))
            $writer.WriteAttributeString('classname', $Report.Mode)
            $writer.WriteAttributeString('time', $result.RuntimeSeconds.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
            if ($result.Result -eq 'FAIL') {
                $writer.WriteStartElement('failure'); $writer.WriteAttributeString('message', $result.Reason); $writer.WriteString('Log: ' + $result.LogPath); $writer.WriteEndElement()
            } elseif ($result.Result -in @('UNSUPPORTED', 'UNAVAILABLE', 'INCONCLUSIVE')) {
                $writer.WriteStartElement('skipped'); $writer.WriteAttributeString('message', $result.Reason); $writer.WriteEndElement()
            }
            $writer.WriteElementString('system-out', ('PlusArgs: ' + ($result.PlusArgs -join ' ') + "`nLog: " + $result.LogPath + "`nResult: " + $result.Result + "`nReason: " + $result.Reason))
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement(); $writer.WriteEndDocument()
    } finally { $writer.Dispose() }
}

Export-ModuleMember -Function *
