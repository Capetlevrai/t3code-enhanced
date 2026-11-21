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

## Limitations

- Uses T3 Code's desktop control named-pipe protocol v1 (`\\.\pipe\t3code-app-<sha256_24>`) and default local backend readiness endpoint (`http://127.0.0.1:3773/.well-known/t3/environment`). If a future T3 Code release changes this internal protocol, `open-in-t3code.cs` may need an update (you can fall back to `open-in-t3code.vbs` in the meantime).
- Relaunching immediately after closing T3 Code waits a few seconds for Electron's `SingleInstanceLock` to release during shutdown.
- The launcher always waits up to 20 s for T3 Code's answer (T3 Code itself gives up after 15 s). Closing the pipe earlier would cancel a request the app may already be processing, and retrying it could add the project twice. If T3 Code refuses the request (`platform-mismatch`, `project-create-failed`, …), its own message is shown immediately instead of retrying.
- The backend port is read from `userdata\server-runtime.json` (ignored when its pid is dead), then `T3CODE_PORT`, then `3773`.
- `optimize-t3code.ps1` disables `enableProviderUpdateChecks` (reversible in T3 Code settings; it only hides "provider update available" notices, so update Codex/Claude CLIs yourself) and only removes rotated trace archives (`*.ndjson.1`..`.10`); it never modifies T3 Code binaries or user data. T3 Code regenerates trace archives quickly (up to ~10 MB each), so the disk saving is temporary.
- `-EnableAutostart` launches the full T3 Code window at every Windows sign-in (T3 Code has no start-minimized mode).
- `add-defender-exclusions.ps1` excludes only the T3 Code install folder, `userdata\logs` and `statev2.sqlite*`. Attachments, provider downloads and worktrees stay scanned because they hold files fetched by agents. `-Broad` restores the old whole-`.t3` exclusion; `remove-defender-exclusions.ps1` removes both.

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
