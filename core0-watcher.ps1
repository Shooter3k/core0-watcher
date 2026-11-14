param(
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
$dataDir = $PSScriptRoot
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

function Set-DefaultCpuSetIds([IntPtr]$Handle, [uint32[]]$Ids) {
    if (-not [Core0CpuSets]::SetProcessDefaultCpuSets($Handle, $Ids, [uint32]$Ids.Length)) {
        throw "SetProcessDefaultCpuSets failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

function Set-ProcessCpuSets($Process, [uint32[]]$CpuSetIds) {
    $handle = [Core0CpuSets]::OpenProcess(0x0200 -bor 0x1000 -bor 0x2000, $false, $Process.Id)
    if ($handle -eq [IntPtr]::Zero) {
        Write-Log "SKIP $($Process.ProcessName) pid=$($Process.Id): OpenProcess error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        return $false
    }

    try {
        Set-DefaultCpuSetIds $handle $CpuSetIds
        Write-Log "SET $($Process.ProcessName) pid=$($Process.Id) to $($CpuSetIds.Count) CPU sets"
        return $true
    } catch {
        Write-Log "ERROR $($Process.ProcessName) pid=$($Process.Id): $($_.Exception.Message)"
        return $false
    } finally {
        [void][Core0CpuSets]::CloseHandle($handle)
    }
}

function Invoke-Apply([hashtable]$Known) {
    $allowedIds = Get-CpuSetIds
    $seen = @{}

    foreach ($process in (Get-Process | Where-Object { $_.Id -gt 4 -and $skipNames -notcontains $_.ProcessName })) {
        $startKey = Get-ProcessStartKey $process
        $key = "$($process.Id):$startKey"
        $seen[$key] = $true
        if ($Known.ContainsKey($key)) { continue }
        $Known[$key] = $true
        [void](Set-ProcessCpuSets $process $allowedIds)
    }

    foreach ($key in @($Known.Keys)) {
        if (-not $seen.ContainsKey($key)) {
            [void]$Known.Remove($key)
        }
    }
}

New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

$known = @{}

if ($Once) {
    Invoke-Apply $known
    exit
}

Write-Log "Watcher started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) in session $((Get-Process -Id $PID).SessionId)."
while ($true) {
    try { Invoke-Apply $known }
    catch {
        Write-Log "WATCHER-ERROR $($_.Exception.Message)"
        exit 1
    }
    Start-Sleep -Milliseconds 500
}
