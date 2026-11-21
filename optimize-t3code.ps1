<#
.SYNOPSIS
    Optimise la configuration locale de T3 Code (Windows) de facon sure et atomique.
.DESCRIPTION
    1. Desactive enableProviderUpdateChecks dans settings.json (uniquement si T3 Code est ferme,
       UTF-8 sans BOM, ecriture atomique avec sauvegarde .bak, no-op si deja false).
    2. Purge les anciens fichiers de logs en rotation (*.ndjson.1 .. .10) en comptant uniquement
       les suppressions reussies.
    3. Execute PRAGMA wal_checkpoint(TRUNCATE) + PRAGMA optimize sur statev2.sqlite (si T3 Code
       est ferme), en verifiant le champ `busy` pour ne jamais annoncer un faux succes.
    4. Optionnel : -EnableAutostart / -DisableAutostart (executables independamment sans toucher
       aux reglages/logs/SQLite sauf si -All est aussi precise).
#>
param(
    [switch]$EnableAutostart,
    [switch]$DisableAutostart,
    [switch]$All
)

$ErrorActionPreference = "Stop"

$t3Home = if (-not [string]::IsNullOrWhiteSpace($env:T3CODE_HOME)) { [System.IO.Path]::GetFullPath($env:T3CODE_HOME.Trim().Trim('"')) } else { Join-Path $env:USERPROFILE ".t3" }
$userData = Join-Path $t3Home "userdata"
$settingsPath = Join-Path $userData "settings.json"
$logsDir = Join-Path $userData "logs"
$dbPath = Join-Path $userData "statev2.sqlite"

# Standalone autostart toggle if requested without -All
$autostartOnly = ($EnableAutostart -or $DisableAutostart) -and (-not $All)

if ($EnableAutostart -or $DisableAutostart) {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runName = "T3CodeBackground"
    if ($EnableAutostart) {
        $t3Dir = Join-Path $env:LOCALAPPDATA "Programs\t3code"
        $exePath = @(
            (Join-Path $t3Dir "T3 Code (Beta).exe"),
            (Join-Path $t3Dir "T3 Code.exe")
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($exePath) {
            Set-ItemProperty -Path $runKey -Name $runName -Value "`"$exePath`""
            Write-Host "[OK] Demarrage automatique active (HKCU\...\Run\$runName)." -ForegroundColor Green
        } else {
            Write-Warning "T3 Code est introuvable dans $t3Dir ; demarrage automatique non active."
        }
    }
    if ($DisableAutostart) {
        Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
        Write-Host "[OK] Demarrage automatique desactive." -ForegroundColor Yellow
    }
    if ($autostartOnly) { return }
}

$running = @(Get-Process | Where-Object { $_.ProcessName -match '^T3 Code' })

# 1. Disable provider update checks in settings.json (only when T3 Code is closed, UTF-8 no BOM, atomic)
if (Test-Path -LiteralPath $settingsPath) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $origWriteTime = (Get-Item -LiteralPath $settingsPath).LastWriteTimeUtc
    $raw = [System.IO.File]::ReadAllText($settingsPath, $utf8NoBom)
    $json = $raw | ConvertFrom-Json
    $alreadyFalse = ($null -ne $json.PSObject.Properties["enableProviderUpdateChecks"]) -and ($json.enableProviderUpdateChecks -eq $false)

    if ($alreadyFalse) {
        Write-Host "[OK] enableProviderUpdateChecks est deja a false (aucune reecriture)." -ForegroundColor Cyan
    } elseif ($running.Count -gt 0) {
        Write-Host "[SKIP] settings.json non modifie (fermez T3 Code pour eviter tout ecrasement concurrent)." -ForegroundColor Yellow
    } else {
        if ($null -eq $json.PSObject.Properties["enableProviderUpdateChecks"]) {
            $json | Add-Member -NotePropertyName "enableProviderUpdateChecks" -NotePropertyValue $false
        } else {
            $json.enableProviderUpdateChecks = $false
        }
        $serialized = $json | ConvertTo-Json -Depth 32
        # Validate round-trip before writing
        $null = $serialized | ConvertFrom-Json

        $tmpSettings = "$settingsPath.tmp.$([guid]::NewGuid().ToString('N'))"
        $bakSettings = "$settingsPath.bak"
        try {
            [System.IO.File]::WriteAllText($tmpSettings, $serialized + "`n", $utf8NoBom)
            $currentWriteTime = (Get-Item -LiteralPath $settingsPath).LastWriteTimeUtc
            if ($currentWriteTime -ne $origWriteTime) {
                throw "settings.json a change pendant l'operation ; modification annulee."
            }
            [System.IO.File]::Replace($tmpSettings, $settingsPath, $bakSettings)
            Write-Host "[OK] enableProviderUpdateChecks = false (UTF-8 sans BOM, atomique) dans $settingsPath" -ForegroundColor Green
        } finally {
            if (Test-Path -LiteralPath $tmpSettings) {
                Remove-Item -LiteralPath $tmpSettings -Force -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    Write-Host "[SKIP] settings.json introuvable : $settingsPath" -ForegroundColor Yellow
}

# 2. Clean rotated trace log backups (*.ndjson.1 .. *.ndjson.10), counting only actually deleted files
if (Test-Path -LiteralPath $logsDir) {
    $rotated = @(Get-ChildItem -LiteralPath $logsDir -File | Where-Object { $_.Name -match '\.ndjson\.([1-9]|10)$' })
    $deletedCount = 0
    $lockedCount = 0
    $freedBytes = 0L
    foreach ($f in $rotated) {
        $len = $f.Length
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $deletedCount++
            $freedBytes += $len
        } catch {
            $lockedCount++
        }
    }
    if ($deletedCount -gt 0) {
        $extra = if ($lockedCount -gt 0) { " ($lockedCount verrouilles ignores)" } else { "" }
        Write-Host ("[OK] {0} fichiers de logs en rotation supprimes ({1:N1} Mo liberes){2}" -f $deletedCount, ($freedBytes / 1MB), $extra) -ForegroundColor Green
    } elseif ($lockedCount -gt 0) {
        Write-Host ("[WARN] {0} fichiers de logs en rotation verrouilles (aucun supprime)." -f $lockedCount) -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Aucun fichier de log en rotation (.1..10) a nettoyer." -ForegroundColor Cyan
    }
}

# 3. SQLite checkpoint + optimize when T3 Code is closed (checks `busy` field, unique temp script, restores env)
if ($running.Count -eq 0 -and (Test-Path -LiteralPath $dbPath)) {
    $t3Dir = Join-Path $env:LOCALAPPDATA "Programs\t3code"
    $exePath = @(
        (Join-Path $t3Dir "T3 Code (Beta).exe"),
        (Join-Path $t3Dir "T3 Code.exe")
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if ($exePath) {
        $walPath = "$dbPath-wal"
        $beforeMb = ((Get-Item -LiteralPath $dbPath).Length + $(if (Test-Path -LiteralPath $walPath) { (Get-Item -LiteralPath $walPath).Length } else { 0 })) / 1MB
        $tmpJs = Join-Path $env:TEMP ("t3code-sqlite-opt-" + [guid]::NewGuid().ToString("N") + ".js")
        $prevElectronAsNode = $env:ELECTRON_RUN_AS_NODE
        @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(process.argv[2]);
db.exec('PRAGMA busy_timeout = 3000;');
const cp = db.prepare('PRAGMA wal_checkpoint(TRUNCATE);').get();
let optOk = true;
try { db.exec('PRAGMA optimize;'); } catch (e) { optOk = false; }
db.close();
console.log(JSON.stringify({ busy: cp ? cp.busy : -1, log: cp ? cp.log : -1, checkpointed: cp ? cp.checkpointed : -1, optOk }));
"@ | Set-Content -LiteralPath $tmpJs -Encoding ASCII
        $prevEap = $ErrorActionPreference
        try {
            $env:ELECTRON_RUN_AS_NODE = "1"
            $ErrorActionPreference = "Continue"
            $outJson = (& $exePath $tmpJs $dbPath 2>&1 | Out-String).Trim()
            $sqliteRc = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
            if ($null -eq $prevElectronAsNode) {
                Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
            } else {
                $env:ELECTRON_RUN_AS_NODE = $prevElectronAsNode
            }
            Remove-Item -LiteralPath $tmpJs -Force -ErrorAction SilentlyContinue
        }

        $afterMb = ((Get-Item -LiteralPath $dbPath).Length + $(if (Test-Path -LiteralPath $walPath) { (Get-Item -LiteralPath $walPath).Length } else { 0 })) / 1MB
        if ($sqliteRc -eq 0) {
            try {
                $res = $outJson | ConvertFrom-Json
                if ($res.busy -ne 0) {
                    Write-Host "[WARN] SQLite WAL checkpoint differe (base verrouillee, busy=$($res.busy)); PRAGMA optimize=$($res.optOk)." -ForegroundColor Yellow
                } elseif (-not $res.optOk) {
                    Write-Host ("[WARN] SQLite WAL checkpoint OK ({0:N2} Mo -> {1:N2} Mo) mais PRAGMA optimize a echoue." -f $beforeMb, $afterMb) -ForegroundColor Yellow
                } else {
                    Write-Host ("[OK] SQLite checkpoint + optimize : {0:N2} Mo -> {1:N2} Mo" -f $beforeMb, $afterMb) -ForegroundColor Green
                }
            } catch {
                Write-Host ("[WARN] Resultat SQLite inattendu : $outJson") -ForegroundColor Yellow
            }
        } else {
            Write-Warning "SQLite optimize a echoue (code $sqliteRc) : $outJson"
        }
    }
} elseif ($running.Count -gt 0) {
    Write-Host "[SKIP] SQLite optimize ignore (fermez T3 Code puis relancez pour optimiser statev2.sqlite)." -ForegroundColor Yellow
}
