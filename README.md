# core0-watcher

A Windows PowerShell scheduled task that sets default CPU sets for user-mode processes to exclude **group 0 logical processors 0 and 1**, reducing competition with kernel interrupt (ISR) and deferred procedure call (DPC) work. It does not reserve those processors for the kernel.

## Why

On large many-core systems (this was built on a 64-core / 128-thread Threadripper PRO with ~60 disks), Windows routes a lot of driver DPC work to logical processor 0. In my case an `xperf` trace showed `CLASSPNP.SYS` (the storage class driver) running 100% of its DPCs on core 0, often 0.25–4 ms each, alongside `ntoskrnl`, `ndis`, `storport`, and the NVIDIA driver.

During a heavy workload (e.g. an `ffmpeg` 4K transcode), core 0 reached 100% even though total CPU usage was only ~40%. Input lag was also observed, but the trace did not establish its cause.

After changing the CPU sets, a later sample showed core 0 load around 5%. This does not establish that the change eliminated input lag.

## What it does

- Enumerates running processes in all sessions, including services such as databases, with a 500 ms delay between scans.
- For each new process, calls `SetProcessDefaultCpuSets` with every CPU set **except** group 0, logical processors 0 and 1.
- Keeps only an in-memory list of processes it has already checked, so each process is adjusted once and the list is rebuilt automatically if the watcher restarts.
- Does not save previous CPU-set selections or any per-process state.
- Skips core OS processes: `Idle`, `System`, `Registry`, `Secure System`, `Memory Compression`, `smss`, `csrss`, `wininit`, `winlogon`, `services`, `lsass`, `LsaIso`.
- Logs actions to `watcher.log` (rotated to `watcher.log.old` at 5 MB).
- Every 10 seconds, logs an `ALIVE` line with the number of scans, the slowest scan (`maxScanMs`), and the longest time between the starts of two scans (`maxGapMs`). A missing `ALIVE` line or a large `maxGapMs` means the watcher was stalled.

It does **not** change kernel ISR/DPC routing, and it does not use hard affinity masks. CPU sets are a soft preference that Windows honors for thread scheduling, and they only affect the processes the script touches.

### Limitations

- Protected processes (Microsoft Defender, some `svchost` instances, WSL `init`) cannot be opened even by SYSTEM and are skipped with `OpenProcess error 5`.
- `OpenProcess error 87` can mean a process exited before it could be adjusted; other errors should be investigated.
- The watcher sleeps for 500 ms between scans; scan time adds to that delay. A process may run on cores 0–1 until a subsequent scan reaches it.
- On an unexpected error, the watcher logs the error and exits; Task Scheduler may restart it up to three times.
- The excluded cores are hardcoded (`$excludedGroup` / `$excludedLogicalProcessors` at the top of the script).

## Files

| File | Purpose |
| --- | --- |
| `core0-watcher.ps1` | The watcher. Runs continuously, or with `-Once`. |
| `install-system-task.ps1` | Elevated installer. Locks down the folder ACL and registers the startup task. |

Runtime files created next to the script (git-ignored): `watcher.log` and `install-result.txt`.

## Install

Copy the folder somewhere permanent (for example `C:\ProgramData\core0-watcher`), then run as Administrator:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-system-task.ps1
```

The installer:

1. Restricts the folder so only **Administrators** and **SYSTEM** can modify it; **Users** get read and execute. It also sets ownership to Administrators, since owners can change file permissions. A script that runs as SYSTEM must not be writable by normal users.
2. Registers the scheduled task `Copilot-Core0-CPU-Set-Watcher`:
   - runs as `NT AUTHORITY\SYSTEM`, so it covers services before anyone logs in;
   - trigger: at system startup;
   - no execution time limit; restarts up to 3 times on failure.
3. Starts the task immediately and writes the outcome to `install-result.txt`.

The install directory and its parent directories must not be replaceable by untrusted users. Locking down the install directory alone does not protect it if an untrusted user owns or can change permissions on a parent directory.

## Usage

```powershell
# Apply once without staying resident
.\core0-watcher.ps1 -Once
```

Check that a process was moved:

```powershell
Get-Content .\watcher.log -Tail 20
```

To uninstall, stop and unregister the `Copilot-Core0-CPU-Set-Watcher` scheduled task from Task Scheduler. CPU-set restrictions already applied to running processes remain until those processes exit or Windows restarts.

## Lag recorder (diagnostics)

`tools\lag-recorder.ps1` keeps a kernel trace (DPCs, interrupts, disk I/O, CPU samples) in a 4 GB circular memory buffer and saves it to `M:\lagtraces` when the system stalls: listing processes takes over 1 second, processor 0 spends over 20% of its time in DPCs, or a file named `trigger` is created in the output folder. It saves at most 5 traces, waits 2 minutes between them, and logs each trigger to `recorder.log`. Requires Administrator and the Windows Performance Toolkit (`xperf`).

```powershell
.\tools\lag-recorder.ps1          # run until Ctrl+C
.\tools\lag-recorder.ps1 -Stop    # stop the kernel trace if the window was closed
```

## Requirements

- Windows 10/11 (CPU Sets API)
- Windows PowerShell 5.1
- Administrator rights to install

## Tests

Run the watcher tests with Pester under Windows PowerShell 5.1:

```powershell
Invoke-Pester .\tests\watcher.Tests.ps1
```
