# T3 Code Enhanced (Windows)

Ultra-fast Windows Explorer context menu integration ("Open in T3 Code") and startup optimizations for **T3 Code** (`pingdotgg/t3code`) on Windows.

---

## Real-World Benchmarks (Before / After)

Measured on Windows from `%LOCALAPPDATA%\t3code-context-menu\last-run.log`, `desktop.trace.ndjson`, and `server.trace.ndjson`:

| Scenario / Step | Before (VBS + `t3 app`) | After (`open-in-t3code.exe` + optimizations) | Speedup |
| --- | --- | --- | --- |
| **Warm start** (T3 Code open → Explorer right-click) | **12.53 s** | **0.07 s** (60–93 ms wall, 33 ms internal) | **~170× faster** |
| **Full cold start** (T3 Code closed → folder opened) | **36–42 s** | **4.72–5.44 s** (1st IPC attempt) | **~7–8× faster** |
| Closed-app detection (Step 1) | **~21,000 ms** (`CLI_RESPONSE_TIMEOUT_MS`) | **15–33 ms** (`File.Exists` on named pipe) | **~630× faster** |
| Control pipe + local backend ready | **~15–22 s** | **~3.10–4.22 s** (pipe `+0.68 s`, HTTP 200 `+3.10 s`) | **~5× faster** |
| Trace logs (`%USERPROFILE%\.t3\userdata\logs`) | **131.9 MB** (13 rotated files) | **~10 MB** (**129.3 MB** freed) | **-92%** |

---

## 1. Windows Explorer Context Menu ("Ouvrir dans T3 Code" / Open in T3 Code)

Adds a right-click menu entry (with the T3 Code icon) across Windows Explorer:
- Right-click **on a folder** (`HKCU\Software\Classes\Directory\shell\T3CodeOpen`)
- Right-click **inside a folder background** (`HKCU\Software\Classes\Directory\Background\shell\T3CodeOpen`)
- Right-click **on a drive** (`HKCU\Software\Classes\Drive\shell\T3CodeOpen`)

> **No administrator privileges required** (per-user `HKCU` registry). On Windows 11, the entry appears under *Show more options* (or `Shift + Right-click`).

### How It Works (Direct Named-Pipe IPC)
- **Why the standard CLI wrapper was slow:** invoking `ELECTRON_RUN_AS_NODE=1 "T3 Code (Beta).exe" "...\bin.mjs" app "<folder>"` spawns the ~200 MB Electron binary and loads `server.asar` on every right-click (5–15 s even on a warm start, and ~21 s waiting on timeout during a cold start).
- **Lightweight native launcher ([`open-in-t3code.cs`](open-in-t3code.cs)):** compiled automatically into an ~8 KB console-free WinExe (`open-in-t3code.exe`) by [`install.ps1`](install.ps1) using Windows' built-in `.NET Framework 4` compiler (`csc.exe`) — zero external dependencies:
  - Computes T3 Code's exact control named pipe: `\\.\pipe\t3code-app-<sha256_24(stateDir)>` (respects `T3CODE_HOME` with `dev` fallback).
  - **Warm start (~70 ms):** detects the pipe in `< 20 ms` and sends the official JSON v1 `open-workspace` request directly over `NamedPipeClientStream`.
  - **Cold start (~4.7 s):** detects the missing pipe in `~15 ms`, handles Electron's `SingleInstanceLock` shutdown grace window cleanly if you just closed T3 Code, launches `T3 Code (Beta).exe` without `ELECTRON_RUN_AS_NODE`, waits for the pipe (`~0.7 s`) and local backend HTTP readiness (`http://127.0.0.1:3773/.well-known/t3/environment`, `~2.4–3.3 s`), then sends the IPC request on the first try.
  - Logs millisecond-level timings to `%LOCALAPPDATA%\t3code-context-menu\last-run.log`.
- **Fallback ([`open-in-t3code.vbs`](open-in-t3code.vbs)):** also optimized with `0 ms` pipe detection injected by `install.ps1` if `csc.exe` is unavailable.

### Install / Uninstall

```powershell
# Install (compiles open-in-t3code.exe + registers HKCU context menu)
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

# Clean uninstall (removes registry keys + AppData folder)
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

---

## 2. T3 Code Startup & Maintenance Optimizer (`optimize-t3code.ps1`)

[`optimize-t3code.ps1`](optimize-t3code.ps1) applies safe local optimizations without deleting any user data:
1. Sets **`enableProviderUpdateChecks: false`** in `%USERPROFILE%\.t3\userdata\settings.json` (avoids network update checks for providers at boot).
2. **Purges old rotated trace logs** (`*.ndjson.1` .. `.10` in `%USERPROFILE%\.t3\userdata\logs`) while keeping active trace files intact.
3. **Runs SQLite maintenance** (`PRAGMA wal_checkpoint(TRUNCATE); PRAGMA optimize;` on `statev2.sqlite` when T3 Code is closed).
4. **Optional instant-open mode (`-EnableAutostart`):** registers T3 Code in `HKCU\...\Run` (no admin required) so every Explorer right-click opens in **~70 ms** all day.

```powershell
# Apply local optimizations (settings + log rotation cleanup + SQLite when T3 Code is closed)
powershell -NoProfile -ExecutionPolicy Bypass -File .\optimize-t3code.ps1

# Optional: enable / disable launch on Windows sign-in
powershell -NoProfile -ExecutionPolicy Bypass -File .\optimize-t3code.ps1 -EnableAutostart
powershell -NoProfile -ExecutionPolicy Bypass -File .\optimize-t3code.ps1 -DisableAutostart
```

---

## 3. Windows Defender Exclusions

On Windows, real-time scanning of Electron binaries (`T3 Code (Beta).exe`, `app.asar`, `server.asar`) and spawned CLI tools (`codex`, `claude`, `git`) is a major cold-start bottleneck.

```powershell
# Add exclusions (%LOCALAPPDATA%\Programs\t3code and %USERPROFILE%\.t3) — prompts for UAC elevation
powershell -NoProfile -ExecutionPolicy Bypass -File .\add-defender-exclusions.ps1

# Remove exclusions
powershell -NoProfile -ExecutionPolicy Bypass -File .\remove-defender-exclusions.ps1
```

---

## 4. Cold-Start Trace Breakdown (`desktop.trace.ndjson` & `server.trace.ndjson`)

Key spans measured during a cold start of `T3 Code (Beta).exe`:

| Component / Span | Measured Duration | Notes |
| --- | --- | --- |
| Node spawn + `server.asar` load | **~1.47 s** | Gap between Electron launch and first server span |
| `desktop.shellEnvironment.refresh` (Windows) | **1.07 s** | Runs in parallel with backend startup |
| `makeCodexInstallation` (`CodexInstallation.resolveLocal`) | **0.78 s** | Local `codex` CLI probe during server boot |
| `VcsProcess.spawn` (`gh`) | **0.18 s** | GitHub CLI probe |
| `Sqlite.setup` (`statev2.sqlite`, 65 MB) | **7.7 ms** | Fast at boot (official compaction available via `t3 doctor`) |
| Parallel post-boot probes (non-blocking) | **1.1–1.7 s** | `withCodexAppServerClient` (`1.46 s`), `runClaudeCommand` (`1.19 s`), `runGrokCliCommand` (`1.15 s`), `tailscale` (`1.04 s`), `git` repo identity (`1.1 s`) |

---

## Repository Files

- [`open-in-t3code.cs`](open-in-t3code.cs) — Native C# WinExe launcher (direct named-pipe IPC, ~70 ms warm / ~4.7 s cold)
- [`open-in-t3code.vbs`](open-in-t3code.vbs) — VBScript fallback launcher with `0 ms` pipe detection
- [`install.ps1`](install.ps1) — Compiles `open-in-t3code.exe` and installs Windows Explorer context menu (`HKCU`)
- [`uninstall.ps1`](uninstall.ps1) — Cleanly removes context menu entries and launcher files
- [`optimize-t3code.ps1`](optimize-t3code.ps1) — Local T3 Code optimizer (`enableProviderUpdateChecks`, log cleanup, SQLite maintenance, optional autostart)
- [`add-defender-exclusions.ps1`](add-defender-exclusions.ps1) — Adds Windows Defender exclusions (with UAC prompt)
- [`remove-defender-exclusions.ps1`](remove-defender-exclusions.ps1) — Removes Windows Defender exclusions
