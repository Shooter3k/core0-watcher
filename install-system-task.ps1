$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$script = Join-Path $dir 'core0-watcher.ps1'
$resultPath = Join-Path $dir 'install-result.txt'
$taskName = 'Copilot-Core0-CPU-Set-Watcher'

try {
    # Only Administrators/SYSTEM may modify files executed as SYSTEM.
    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE" }
    # Make existing files inherit the folder ACL instead of receiving explicit (OI)(CI) entries.
    & icacls.exe (Join-Path $dir '*') /reset /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls reset failed with exit code $LASTEXITCODE" }

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
            Where-Object { $_.CommandLine -like "*core0-watcher.ps1*" -and $_.CommandLine -match '\s-File\s' } |
            ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Keeps processes in all sessions (including services) off logical processors 0 and 1; kernel DPC/ISR scheduling is unchanged.' | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 5
    "OK state=$((Get-ScheduledTask -TaskName $taskName).State)" | Set-Content -LiteralPath $resultPath
} catch {
    "FAIL $($_.Exception.Message)" | Set-Content -LiteralPath $resultPath
}
