# core0-watcher

A small Windows PowerShell service that keeps **user-mode processes off logical processors 0 and 1**, leaving those cores free for kernel interrupt (ISR) and deferred procedure call (DPC) work.

## Why

On large many-core systems (this was built on a 64-core / 128-thread Threadripper PRO with ~60 disks), Windows routes a lot of driver DPC work to logical processor 0. In my case an `xperf` trace showed `CLASSPNP.SYS` (the storage class driver) running 100% of its DPCs on core 0, often 0.25–4 ms each, alongside `ntoskrnl`, `ndis`, `storport`, and the NVIDIA driver.

When a heavy workload (e.g. an `ffmpeg` 4K transcode) also landed threads on core 0, that core hit 100% even though total CPU usage was only ~40%. The result was **laggy mouse and keyboard input** because input-related work queued behind it.

Moving user-mode threads off cores 0–1 dropped core 0 load from ~100% to ~5% and removed the contention.

## What it does

- Enumerates every running process every 500 ms (all sessions, including services such as databases).
- For each new process, calls `SetProcessDefaultCpuSets` with every CPU set **except** group 0, logical processors 0 and 1.
- Records each process's original CPU-set assignment in `process-state.json` so it can be restored.
- Skips core OS processes: `Idle`, `System`, `Registry`, `Secure System`, `Memory Compression`, `smss`, `csrss`, `wininit`, `winlogon`, `services`, `lsass`, `LsaIso`.
- Logs actions to `watcher.log` (rotated to `watcher.log.old` at 5 MB).

It does **not** change kernel ISR/DPC routing, and it does not use hard affinity masks. CPU sets are a soft preference that Windows honors for thread scheduling, and they only affect the processes the script touches.

### Limitations

- Protected processes (Microsoft Defender, some `svchost` instances, WSL `init`) cannot be opened even by SYSTEM and are skipped with `OpenProcess error 5`.
- `OpenProcess error 87` in the log means the process exited before it could be adjusted. It is harmless.
- A new process may run on cores 0–1 for up to ~500 ms before it is moved.
- The excluded cores are hardcoded (`$excludedGroup` / `$excludedLogicalProcessors` at the top of the script).

## Files

| File | Purpose |
| --- | --- |
| `core0-watcher.ps1` | The watcher. Runs continuously, or with `-Once` / `-Remove`. |
| `install-system-task.ps1` | Elevated installer. Locks down the folder ACL and registers the startup task. |

Runtime files created next to the script (git-ignored): `process-state.json`, `watcher.log`, `install-result.txt`.

## Install

Copy the folder somewhere permanent (for example `C:\notes\core0_watcher`), then run as Administrator:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-system-task.ps1
```

The installer:

1. Restricts the folder so only **Administrators** and **SYSTEM** can modify it; **Users** get read and execute. A script that runs as SYSTEM must not be writable by normal users.
2. Registers the scheduled task `Copilot-Core0-CPU-Set-Watcher`:
   - runs as `NT AUTHORITY\SYSTEM`, so it covers services before anyone logs in;
   - trigger: at system startup;
   - no execution time limit; restarts up to 3 times on failure.
3. Starts the task immediately and writes the outcome to `install-result.txt`.

## Usage

```powershell
# Apply once without staying resident
.\core0-watcher.ps1 -Once

# Uninstall: remove the task, stop the watcher, restore saved CPU sets (run as Administrator)
.\core0-watcher.ps1 -Remove
```

Check that a process was moved:

```powershell
Get-Content .\watcher.log -Tail 20
```

## Requirements

- Windows 10/11 (CPU Sets API)
- Windows PowerShell 5.1
- Administrator rights to install
