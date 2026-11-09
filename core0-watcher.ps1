param(
    [switch]$Once,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$taskName = 'Copilot-Core0-CPU-Set-Watcher'
$dataDir = $PSScriptRoot
$statePath = Join-Path $dataDir 'process-state.json'
$logPath = Join-Path $dataDir 'watcher.log'
$excludedGroup = 0
$excludedLogicalProcessors = @(0, 1)
$maxLogBytes = 5MB
# Core OS processes that are left untouched.
$skipNames = @(
    'Idle', 'System', 'Registry', 'Secure System', 'Memory Compression',
    'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'LsaIso'
)

if (-not ('Core0CpuSets' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Core0CpuSets {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetSystemCpuSetInformation(IntPtr info, uint length, out uint returnedLength, IntPtr process, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetProcessDefaultCpuSets(IntPtr process, uint[] ids, uint count, out uint requiredCount);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetProcessDefaultCpuSets(IntPtr process, uint[] ids, uint count);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
}

function Write-Log([string]$Message) {
    $stamp = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt $maxLogBytes) {
        Move-Item -LiteralPath $logPath -Destination "$logPath.old" -Force
    }
    Add-Content -LiteralPath $logPath -Value "$stamp $Message"
}

function Get-CpuSetIds {
    [uint32]$needed = 0
    [void][Core0CpuSets]::GetSystemCpuSetInformation([IntPtr]::Zero, 0, [ref]$needed, [IntPtr]::Zero, 0)
    if ($needed -eq 0) { throw 'Windows returned no CPU-set information.' }

    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$needed)
    try {
        if (-not [Core0CpuSets]::GetSystemCpuSetInformation($buffer, $needed, [ref]$needed, [IntPtr]::Zero, 0)) {
            throw "GetSystemCpuSetInformation failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }

        $allowed = [System.Collections.Generic.List[uint32]]::new()
        $excludedFound = 0
        $offset = 0
        while ($offset -lt $needed) {
            $size = [Runtime.InteropServices.Marshal]::ReadInt32($buffer, $offset)
            $type = [Runtime.InteropServices.Marshal]::ReadInt32($buffer, $offset + 4)
            if ($size -lt 8) { throw "Invalid CPU-set record size: $size" }
            if ($type -eq 0) {
                $id = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($buffer, $offset + 8)
                $group = [uint16][Runtime.InteropServices.Marshal]::ReadInt16($buffer, $offset + 12)
                $lp = [int][Runtime.InteropServices.Marshal]::ReadByte($buffer, $offset + 14)
                if ($group -eq $excludedGroup -and $excludedLogicalProcessors -contains $lp) {
                    $excludedFound++
                } else {
                    $allowed.Add($id)
                }
            }
            $offset += $size
        }

        if ($excludedFound -ne $excludedLogicalProcessors.Count) {
            throw "Expected to find exactly $($excludedLogicalProcessors.Count) CPU sets for group $excludedGroup LPs 0 and 1; found $excludedFound. No process settings were changed."
        }
        if ($allowed.Count -eq 0) { throw 'No CPU sets remain after exclusions.' }
        return ,$allowed.ToArray()
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }
}

function Get-ProcessStartKey($Process) {
    try { return $Process.StartTime.ToUniversalTime().Ticks.ToString() }
    catch { return 'unknown' }
}

function Get-OriginalCpuSetIds([IntPtr]$Handle) {
    [uint32]$needed = 0
    if (-not [Core0CpuSets]::GetProcessDefaultCpuSets($Handle, $null, 0, [ref]$needed)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errorCode -ne 122 -and $errorCode -ne 0) {
            throw "GetProcessDefaultCpuSets failed: $errorCode"
        }
    }
    if ($needed -eq 0) { return ,@() }

    $ids = [uint32[]]::new($needed)
    if (-not [Core0CpuSets]::GetProcessDefaultCpuSets($Handle, $ids, $needed, [ref]$needed)) {
        throw "GetProcessDefaultCpuSets failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    return ,$ids
}

function Set-DefaultCpuSetIds([IntPtr]$Handle, [uint32[]]$Ids) {
    $count = if ($null -eq $Ids) { 0 } else { $Ids.Length }
    if (-not [Core0CpuSets]::SetProcessDefaultCpuSets($Handle, $Ids, [uint32]$count)) {
        throw "SetProcessDefaultCpuSets failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

function Read-State {
    if (Test-Path -LiteralPath $statePath) {
        return @(Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
    }
    return @()
}

function Save-State($State) {
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Invoke-Apply {
    $allowedIds = Get-CpuSetIds
    $state = [System.Collections.Generic.List[object]]::new()
    $known = @{}
    foreach ($entry in (Read-State)) { $state.Add($entry); $known[$entry.Key] = $true }
    $seen = @{}
    $dirty = $false

    foreach ($process in (Get-Process | Where-Object { $_.Id -gt 4 -and $skipNames -notcontains $_.ProcessName })) {
        $startKey = Get-ProcessStartKey $process
        $key = "$($process.Id):$startKey"
        $seen[$key] = $true
        if ($known.ContainsKey($key)) { continue }
        $known[$key] = $true

        $handle = [Core0CpuSets]::OpenProcess(0x0200 -bor 0x1000 -bor 0x2000, $false, $process.Id)
        if ($handle -eq [IntPtr]::Zero) {
            Write-Log "SKIP $($process.ProcessName) pid=$($process.Id): OpenProcess error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            $state.Add([pscustomobject]@{
                Key = $key
                ProcessId = $process.Id
                ProcessName = $process.ProcessName
                StartKey = $startKey
                CpuSetIds = @()
                Applied = $false
            })
            $dirty = $true
            continue
        }
        try {
            $oldIds = Get-OriginalCpuSetIds $handle
            Set-DefaultCpuSetIds $handle $allowedIds
            $state.Add([pscustomobject]@{
                Key = $key
                ProcessId = $process.Id
                ProcessName = $process.ProcessName
                StartKey = $startKey
                CpuSetIds = @($oldIds)
                Applied = $true
            })
            Write-Log "SET $($process.ProcessName) pid=$($process.Id) to $($allowedIds.Count) CPU sets"
            $dirty = $true
        } catch {
            Write-Log "ERROR $($process.ProcessName) pid=$($process.Id): $($_.Exception.Message)"
            $state.Add([pscustomobject]@{
                Key = $key
                ProcessId = $process.Id
                ProcessName = $process.ProcessName
                StartKey = $startKey
                CpuSetIds = @()
                Applied = $false
            })
            $dirty = $true
        } finally {
            [void][Core0CpuSets]::CloseHandle($handle)
        }
    }

    $retained = @($state | Where-Object { $seen.ContainsKey($_.Key) })
    if ($retained.Count -ne $state.Count) {
        $state = [System.Collections.Generic.List[object]]::new([object[]]$retained)
        $dirty = $true
    }
    if ($dirty) { Save-State $state }
}

function Invoke-Restore {
    $state = Read-State
    foreach ($entry in $state) {
        if ($entry.PSObject.Properties.Name -contains 'Applied' -and -not $entry.Applied) { continue }
        try {
            $process = Get-Process -Id ([int]$entry.ProcessId) -ErrorAction Stop
            if ((Get-ProcessStartKey $process) -ne [string]$entry.StartKey) { continue }
            $handle = [Core0CpuSets]::OpenProcess(0x0200 -bor 0x1000 -bor 0x2000, $false, [int]$entry.ProcessId)
            if ($handle -eq [IntPtr]::Zero) {
                Write-Log "RESTORE-SKIP $($entry.ProcessName) pid=$($entry.ProcessId): OpenProcess error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
                continue
            }
            try {
                $ids = [uint32[]]@($entry.CpuSetIds | ForEach-Object { [uint32]$_ })
                Set-DefaultCpuSetIds $handle $ids
                Write-Log "RESTORE $($entry.ProcessName) pid=$($entry.ProcessId)"
            } finally {
                [void][Core0CpuSets]::CloseHandle($handle)
            }
        } catch {
            Write-Log "RESTORE-ERROR pid=$($entry.ProcessId): $($_.Exception.Message)"
        }
    }
}

New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

if ($Remove) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    $watcherPattern = '-File\s+"?' + [regex]::Escape($PSCommandPath) + '"?(\s|$)'
    Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -match $watcherPattern
    } | ForEach-Object {
        Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    Invoke-Restore
    Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
    Write-Log 'Watcher task removed and saved process settings restored where possible.'
    exit
}

if ($Once) {
    Invoke-Apply
    exit
}

Write-Log "Watcher started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) in session $((Get-Process -Id $PID).SessionId)."
while ($true) {
    try { Invoke-Apply }
    catch { Write-Log "WATCHER-ERROR $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 500
}
