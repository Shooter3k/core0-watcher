$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'core0-watcher.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Cannot parse $scriptPath" }
foreach ($name in @('Write-Log', 'New-HeartbeatStats', 'Update-Heartbeat', 'Get-ProcessStartKey', 'Get-CpuSetIds', 'Set-ProcessCpuSets', 'Invoke-Apply')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Missing function $name" }
    Invoke-Expression $definition.Extent.Text
}

Describe 'Watcher process tracking' {
    BeforeEach {
        $script:known = @{}
        $script:processes = @()
        $script:applied = @()
        Mock Get-CpuSetIds { [uint32[]]@(2, 3) }
        Mock Get-Process { $script:processes }
        Mock Set-ProcessCpuSets {
            $script:applied += $Process.Id
            return $true
        }
    }

    It 'applies the CPU-set selection once to each process' {
        $started = [DateTime]::UtcNow
        $script:processes = @(
            [pscustomobject]@{ Id = 101; ProcessName = 'first'; StartTime = $started },
            [pscustomobject]@{ Id = 102; ProcessName = 'second'; StartTime = $started }
        )
        Invoke-Apply $known
        Invoke-Apply $known
        @($applied).Count | Should Be 2
        @($applied | Select-Object -Unique).Count | Should Be 2
    }

    It 'forgets exited processes and distinguishes a reused PID' {
        $firstStart = [DateTime]::UtcNow.AddMinutes(-1)
        $secondStart = [DateTime]::UtcNow
        $script:processes = @([pscustomobject]@{ Id = 103; ProcessName = 'worker'; StartTime = $firstStart })
        Invoke-Apply $known
        $script:processes = @()
        Invoke-Apply $known
        $script:processes = @([pscustomobject]@{ Id = 103; ProcessName = 'worker'; StartTime = $secondStart })
        Invoke-Apply $known
        @($applied).Count | Should Be 2
        @($known.Keys | Where-Object { $_ -like '103:*' }).Count | Should Be 1
        @($known.Keys)[0] | Should Be "103:$($secondStart.ToUniversalTime().Ticks)"
    }

    It 'does not read or write persistent process state' {
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $source | Should Not Match 'process-state|Read-State|Save-State|Invoke-Restore|switch\]\$Remove'
        $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should Be 'Once'
    }
}

Describe 'Watcher logging' {
    It 'does not throw when the log file is locked by another program' {
        $logPath = Join-Path $TestDrive 'watcher.log'
        $maxLogBytes = 5MB
        $ErrorActionPreference = 'Stop'
        Set-Content -LiteralPath $logPath -Value ''
        $lock = [IO.File]::Open($logPath, 'Open', 'Read', 'Read')
        try { { Write-Log 'test' } | Should Not Throw }
        finally { $lock.Close() }
        Write-Log 'after unlock'
        (Get-Content -LiteralPath $logPath -Raw) | Should Match 'after unlock'
    }
}

Describe 'Watcher heartbeat' {
    It 'reports scan count, slowest scan and longest gap once per interval' {
        $heartbeatSeconds = 10
        $t0 = [DateTime]'2026-01-01T00:00:00'
        $stats = New-HeartbeatStats $t0
        Update-Heartbeat $stats $t0 $t0.AddMilliseconds(40) | Should BeNullOrEmpty
        Update-Heartbeat $stats $t0.AddSeconds(1) $t0.AddSeconds(1).AddMilliseconds(90) | Should BeNullOrEmpty
        # A 25-second stall between scans must show up as the max gap.
        Update-Heartbeat $stats $t0.AddSeconds(26) $t0.AddSeconds(26).AddMilliseconds(30) | Should Be 'ALIVE scans=3 maxScanMs=90 maxGapMs=25000'
        Update-Heartbeat $stats $t0.AddSeconds(27) $t0.AddSeconds(27).AddMilliseconds(10) | Should BeNullOrEmpty
    }
}