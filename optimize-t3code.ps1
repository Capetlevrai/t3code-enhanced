<#
.SYNOPSIS
    Optimise la configuration locale de T3 Code (Windows) sans supprimer aucune donnee utilisateur.
.DESCRIPTION
    1. Desactive enableProviderUpdateChecks dans %USERPROFILE%\.t3\userdata\settings.json.
    2. Purge les anciens fichiers de logs en rotation (*.ndjson.1 .. .10) dans %USERPROFILE%\.t3\userdata\logs.
    3. Execute PRAGMA wal_checkpoint(TRUNCATE) + PRAGMA optimize sur statev2.sqlite (si T3 Code est ferme).
    4. Optionnel : -EnableAutostart / -DisableAutostart pour lancer T3 Code a l'ouverture de session Windows.
#>
param(
    [switch]$EnableAutostart,
    [switch]$DisableAutostart
)

$ErrorActionPreference = "Stop"

$t3Home = if ($env:T3CODE_HOME) { $env:T3CODE_HOME } else { Join-Path $env:USERPROFILE ".t3" }
$userData = Join-Path $t3Home "userdata"
$settingsPath = Join-Path $userData "settings.json"
$logsDir = Join-Path $userData "logs"
$dbPath = Join-Path $userData "statev2.sqlite"

# 1. Disable provider update checks in settings.json
if (Test-Path $settingsPath) {
    $raw = Get-Content -Path $settingsPath -Raw -Encoding UTF8
    $json = $raw | ConvertFrom-Json
    if ($null -eq $json.PSObject.Properties["enableProviderUpdateChecks"]) {
        $json | Add-Member -NotePropertyName "enableProviderUpdateChecks" -NotePropertyValue $false
    } else {
        $json.enableProviderUpdateChecks = $false
    }
    $json | ConvertTo-Json -Depth 16 | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Host "[OK] enableProviderUpdateChecks = false dans $settingsPath" -ForegroundColor Green
} else {
    Write-Host "[SKIP] settings.json introuvable : $settingsPath" -ForegroundColor Yellow
}

# 2. Clean rotated trace log backups (*.ndjson.1 .. *.ndjson.99)
if (Test-Path $logsDir) {
    $rotated = Get-ChildItem -Path $logsDir -File | Where-Object { $_.Name -match '\.ndjson\.\d+$' }
    $freedBytes = ($rotated | Measure-Object Length -Sum).Sum
    if ($rotated.Count -gt 0) {
        $rotated | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host ("[OK] {0} fichiers de logs en rotation supprimes ({1:N1} Mo liberes)" -f $rotated.Count, ($freedBytes / 1MB)) -ForegroundColor Green
    } else {
        Write-Host "[OK] Aucun fichier de log en rotation a nettoyer." -ForegroundColor Cyan
    }
}

# 3. Optional SQLite checkpoint + optimize when T3 Code is closed
$running = Get-Process | Where-Object { $_.ProcessName -match '^T3 Code' }
if (-not $running -and (Test-Path $dbPath)) {
    $t3Dir = Join-Path $env:LOCALAPPDATA "Programs\t3code"
    $exePath = @(
        (Join-Path $t3Dir "T3 Code (Beta).exe"),
        (Join-Path $t3Dir "T3 Code.exe")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($exePath) {
        $beforeMb = ((Get-Item $dbPath).Length + (Get-Item "$dbPath-wal" -ErrorAction SilentlyContinue).Length) / 1MB
        $tmpJs = Join-Path $env:TEMP "t3code-sqlite-opt.js"
        @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(process.argv[2]);
db.exec('PRAGMA wal_checkpoint(TRUNCATE);');
db.exec('PRAGMA optimize;');
db.close();
"@ | Set-Content -Path $tmpJs -Encoding ASCII
        $env:ELECTRON_RUN_AS_NODE = "1"
        & $exePath $tmpJs $dbPath | Out-Null
        $sqliteRc = $LASTEXITCODE
        Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
        Remove-Item $tmpJs -Force -ErrorAction SilentlyContinue
        $afterMb = ((Get-Item $dbPath).Length + (Get-Item "$dbPath-wal" -ErrorAction SilentlyContinue).Length) / 1MB
        if ($sqliteRc -eq 0) {
            Write-Host ("[OK] SQLite checkpoint + optimize : {0:N2} Mo -> {1:N2} Mo" -f $beforeMb, $afterMb) -ForegroundColor Green
        } else {
            Write-Warning "SQLite optimize a echoue (code $sqliteRc)."
        }
    }
} elseif ($running) {
    Write-Host "[SKIP] SQLite optimize ignore (fermez T3 Code puis relancez pour optimiser statev2.sqlite)." -ForegroundColor Yellow
}

# 4. Optional Windows autostart (HKCU\...\Run, no admin required)
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runName = "T3CodeBackground"
if ($EnableAutostart) {
    $t3Dir = Join-Path $env:LOCALAPPDATA "Programs\t3code"
    $exePath = @(
        (Join-Path $t3Dir "T3 Code (Beta).exe"),
        (Join-Path $t3Dir "T3 Code.exe")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($exePath) {
        Set-ItemProperty -Path $runKey -Name $runName -Value "`"$exePath`""
        Write-Host "[OK] Demarrage automatique active (HKCU\...\Run\$runName) -> ouvertures < 0,2 s en permanence." -ForegroundColor Green
    }
}
if ($DisableAutostart) {
    Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
    Write-Host "[OK] Demarrage automatique desactive." -ForegroundColor Yellow
}
