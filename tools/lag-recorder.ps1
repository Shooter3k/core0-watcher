<#
Keeps a kernel trace (DPCs, interrupts, disk I/O, CPU samples) in a circular memory buffer and saves it
to disk when the system stalls. Run elevated; stop with Ctrl+C or by running it with -Stop.

A stall is detected when listing processes takes longer than -SlowScanMs, when processor 0 spends more
than -DpcPercent of its time in DPCs, or when a file named "trigger" appears in -OutputDir.
#>
param(
    [string]$OutputDir = 'M:\lagtraces',
    [int]$SlowScanMs = 1000,
    [int]$DpcPercent = 20,
    [int]$PostTriggerSeconds = 10,
    [int]$CooldownSeconds = 120,
    [int]$MaxCaptures = 5,
    [int]$BufferMB = 4096,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'
$xperf = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe'
$kernelFlags = 'PROC_THREAD+LOADER+DPC+INTERRUPT+PROFILE+DISK_IO+DISK_IO_INIT'
$logger = 'NT Kernel Logger'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}
if (-not (Test-Path -LiteralPath $xperf)) { throw "xperf not found at $xperf" }

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$logPath = Join-Path $OutputDir 'recorder.log'
$triggerPath = Join-Path $OutputDir 'trigger'
$stopPath = Join-Path $OutputDir 'stop'

if ($Stop) {
    New-Item -ItemType File -Path $stopPath -Force | Out-Null
    'Stop requested.'
    return
}

function Write-RecorderLog([string]$Message) {
    $line = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff')) $Message"
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line
}

function Invoke-Xperf([string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $xperf @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join [Environment]::NewLine) }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Start-KernelTrace {
    $result = Invoke-Xperf -Arguments @('-loggers')
    if ($result.ExitCode -ne 0) { throw "xperf could not list active loggers: $($result.Output)" }
    if ($result.Output -match 'Logger Name\s+:\s+NT Kernel Logger') {
        throw 'The NT Kernel Logger is already in use; refusing to stop or replace another trace.'
    }

    $result = Invoke-Xperf -Arguments @('-on', $kernelFlags, '-stackwalk', 'Profile', '-BufferSize', '1024', '-MinBuffers', "$BufferMB", '-MaxBuffers', "$BufferMB", '-Buffering')
    if ($result.ExitCode -ne 0) { throw "xperf failed to start: $($result.Output)" }
    $script:traceStarted = $true
}

function Stop-KernelTrace {
    if ($script:traceStarted) {
        $result = Invoke-Xperf -Arguments @('-stop')
        if ($result.ExitCode -ne 0) { throw "xperf failed to stop the recorder's trace: $($result.Output)" }
        $script:traceStarted = $false
    }
}

function Get-Sample {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [void][Diagnostics.Process]::GetProcesses()
    $scanMs = $sw.ElapsedMilliseconds
    $samples = (Get-Counter '\Processor(0)\% DPC Time', '\PhysicalDisk(*)\Current Disk Queue Length' -MaxSamples 1).CounterSamples
    $dpc = ($samples | Where-Object Path -like '*processor(0)*').CookedValue
    $queues = $samples | Where-Object { $_.Path -like '*physicaldisk*' -and $_.InstanceName -ne '_total' -and $_.CookedValue -gt 0 } |
        Sort-Object CookedValue -Descending | Select-Object -First 5 |
        ForEach-Object { '{0}={1}' -f $_.InstanceName, $_.CookedValue }
    [pscustomobject]@{ ScanMs = $scanMs; DpcPercent = [Math]::Round($dpc, 1); Queues = ($queues -join ' ') }
}

function Save-Trace([string]$Reason) {
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $raw = Join-Path $OutputDir "lag-$stamp-raw.etl"
    $final = Join-Path $OutputDir "lag-$stamp.etl"
    Write-RecorderLog "TRIGGER $Reason; recording $PostTriggerSeconds more seconds"
    Start-Sleep -Seconds $PostTriggerSeconds
    $result = Invoke-Xperf -Arguments @('-flush', $logger, '-f', $raw)
    if ($result.ExitCode -ne 0) { throw "xperf failed to flush the trace: $($result.Output)" }
    Stop-KernelTrace
    $result = Invoke-Xperf -Arguments @('-merge', $raw, $final)
    if ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $final)) {
        Remove-Item -LiteralPath $raw -Force
        Write-RecorderLog ("SAVED {0} ({1:N0} MB)" -f $final, ((Get-Item -LiteralPath $final).Length / 1MB))
    } else {
        Write-RecorderLog "SAVE-FAILED merge did not produce $final; raw trace kept at $raw"
    }
}

$captures = 0
try {
    Start-KernelTrace
    Write-RecorderLog "Recorder started: buffer ${BufferMB} MB, triggers scan>${SlowScanMs}ms, core0 DPC>${DpcPercent}%, or $triggerPath"
    $cooldownUntil = [DateTime]::MinValue
    while ($captures -lt $MaxCaptures) {
            if (Test-Path -LiteralPath $stopPath) {
                Remove-Item -LiteralPath $stopPath -Force
                break
            }
        $s = Get-Sample
        $reason = $null
        if (Test-Path -LiteralPath $triggerPath) {
            Remove-Item -LiteralPath $triggerPath -Force
            $reason = 'manual trigger'
        } elseif ([DateTime]::Now -ge $cooldownUntil) {
            if ($s.ScanMs -gt $SlowScanMs) { $reason = "process list took $($s.ScanMs) ms" }
            elseif ($s.DpcPercent -gt $DpcPercent) { $reason = "core 0 DPC $($s.DpcPercent)%" }
        }
        if ($reason) {
            Save-Trace "$reason (scan=$($s.ScanMs)ms dpc0=$($s.DpcPercent)% queues: $($s.Queues))"
            $captures++
            $cooldownUntil = [DateTime]::Now.AddSeconds($CooldownSeconds)
            if ($captures -lt $MaxCaptures) { Start-KernelTrace }
        }
        Start-Sleep -Seconds 1
    }
    if ($captures -ge $MaxCaptures) { Write-RecorderLog "Reached $MaxCaptures captures; stopping." }
} catch {
    Write-RecorderLog "RECORDER-ERROR $($_.Exception.Message)"
    throw
} finally {
    Stop-KernelTrace
    Write-RecorderLog 'Recorder stopped.'
}
