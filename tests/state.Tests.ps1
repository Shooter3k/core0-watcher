$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'core0-watcher.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Cannot parse $scriptPath" }
foreach ($name in @('Read-State', 'Save-State')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Missing function $name" }
    Invoke-Expression $definition.Extent.Text
}

Describe 'Watcher state persistence' {
    BeforeEach {
        $script:statePath = Join-Path $TestDrive 'process-state.json'
        if (Test-Path $statePath) { Remove-Item $statePath }
        if (Test-Path "$statePath.bak") { Remove-Item "$statePath.bak" }
    }

    It 'round trips empty, single, and multiple entries' {
        $entry = [pscustomobject]@{
            Key = '123:456'
            ProcessId = 123
            StartKey = '456'
            CpuSetIds = @(3, 5)
            Applied = $true
        }
        Save-State @()
        @(Read-State).Count | Should Be 0
        Save-State @($entry)
        $read = @(Read-State)
        $read.Count | Should Be 1
        $read[0].Key | Should Be '123:456'
        @($read[0].CpuSetIds).Count | Should Be 2
        Save-State @($entry, $entry)
        @(Read-State).Count | Should Be 2
    }

    It 'keeps the previous complete state as a backup' {
        $old = [pscustomobject]@{ Key = 'old'; ProcessId = 1; StartKey = '1'; CpuSetIds = @() }
        $new = [pscustomobject]@{ Key = 'new'; ProcessId = 2; StartKey = '2'; CpuSetIds = @() }
        Save-State @($old)
        Save-State @($new)
        @(Read-State)[0].Key | Should Be 'new'
        $backup = Get-Content "$statePath.bak" -Raw | ConvertFrom-Json
        $backup.Key | Should Be 'old'
        Save-State @($old)
        $backup = Get-Content "$statePath.bak" -Raw | ConvertFrom-Json
        $backup.Key | Should Be 'new'
    }

    It 'serializes the generic list used by the watcher' {
        $list = [System.Collections.Generic.List[object]]::new()
        $list.Add([pscustomobject]@{ Key = '123:456'; ProcessId = 123; StartKey = '456'; CpuSetIds = @() })
        Save-State $list
        $read = @(Read-State)
        $read.Count | Should Be 1
        $read[0].Key | Should Be '123:456'
    }

    It 'reads a legacy single-object state file' {
        [IO.File]::WriteAllText($statePath, '{"Key":"123:456","ProcessId":123,"StartKey":"456","CpuSetIds":[]}')
        @(Read-State)[0].Key | Should Be '123:456'
    }

    It 'rejects corrupted state without overwriting it' {
        $bytes = [byte[]]::new(128)
        [IO.File]::WriteAllBytes($statePath, $bytes)
        { Read-State } | Should Throw
        [IO.File]::ReadAllBytes($statePath).Length | Should Be 128
    }

    It 'rejects null and entries missing restoration fields' {
        foreach ($json in @('null', '[{"Key":"x"}]')) {
            [IO.File]::WriteAllText($statePath, $json)
            { Read-State } | Should Throw
        }
    }

    It 'exits on corrupt state instead of looping or modifying it' {
        Copy-Item $scriptPath (Join-Path $TestDrive 'core0-watcher.ps1') -Force
        [IO.File]::WriteAllBytes($statePath, [byte[]]::new(128))
        & (Join-Path $PSHOME 'powershell.exe') -NoProfile -File (Join-Path $TestDrive 'core0-watcher.ps1') 2>&1 | Out-Null
        $LASTEXITCODE | Should Be 1
        [IO.File]::ReadAllBytes($statePath).Length | Should Be 128
        @(Select-String -Path (Join-Path $TestDrive 'watcher.log') -SimpleMatch 'WATCHER-ERROR').Count | Should Be 1
    }
}
