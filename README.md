# T3 Code Enhanced (Windows)

Instant Windows Explorer right-click integration and startup optimizations for **T3 Code** (`pingdotgg/t3code`).

## Benchmarks

| Action | Before | After | Speedup |
| --- | --- | --- | --- |
| **Warm start** (app open → right-click) | 12.53 s | **0.07 s** | **~170×** |
| **Cold start** (app closed → folder open) | 36–42 s | **4.72 s** | **~8×** |
| Closed-app detection | ~21,000 ms | **15 ms** | **~1,400×** |
| Rotated trace logs | 131.9 MB | **~10 MB** | **-92%** |

## Quick Start

```powershell
# 1. Install right-click menu ("Ouvrir dans T3 Code") — no admin required
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

# 2. Apply safe startup & log optimizations (add -EnableAutostart for ~70 ms opens all day)
powershell -NoProfile -ExecutionPolicy Bypass -File .\optimize-t3code.ps1

# 3. Optional: add Windows Defender exclusions (prompts for UAC)
powershell -NoProfile -ExecutionPolicy Bypass -File .\add-defender-exclusions.ps1
```

## How It Works

`install.ps1` compiles [`open-in-t3code.cs`](open-in-t3code.cs) into a tiny (~8 KB) console-free WinExe using Windows' built-in `.NET 4` compiler (`csc.exe`). Instead of spawning Electron with `ELECTRON_RUN_AS_NODE=1` on every click, it talks directly to T3 Code's control named pipe (`\\.\pipe\t3code-app-<hash>`).

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\remove-defender-exclusions.ps1
```

## Files

- [`open-in-t3code.cs`](open-in-t3code.cs) — Native C# launcher (direct named-pipe IPC)
- [`open-in-t3code.vbs`](open-in-t3code.vbs) — Fallback VBScript launcher
- [`install.ps1`](install.ps1) / [`uninstall.ps1`](uninstall.ps1) — Context menu installer & uninstaller (`HKCU`)
- [`optimize-t3code.ps1`](optimize-t3code.ps1) — Disables provider update checks, cleans rotated logs, optimizes SQLite, optional autostart
- [`add-defender-exclusions.ps1`](add-defender-exclusions.ps1) / [`remove-defender-exclusions.ps1`](remove-defender-exclusions.ps1) — Windows Defender exclusions
