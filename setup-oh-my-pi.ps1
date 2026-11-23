<#
.SYNOPSIS
    Ajoute Oh My Pi (omp) comme fournisseur dans T3 Code sous Windows, via le shim omp-t3.
.DESCRIPTION
    T3 Code n'a pas de pilote Oh My Pi. Il a un pilote "Pi" (RPC JSONL) et omp-t3
    (https://github.com/hashangit/omp-t3) adapte omp a ce pilote. Ce script :
      1. Verifie Bun (>= 1.4.4, exige par omp 19.x) et omp (le reinstalle avec Bun s'il est casse).
      2. Installe omp-t3 a la version epinglee (npm -g) puis lance `omp-t3 --check`.
      3. Rend opt-in la creation automatique d'issues GitHub de omp-t3 (par defaut il utilise
         votre `gh` connecte pour publier une issue publique en votre nom). Le patch est
         idempotent et doit etre reapplique apres chaque mise a jour de omp-t3 : relancez ce script.
      4. Ecrit le fournisseur dans settings.json de T3 Code (cle `config`, sinon T3 ignore
         binaryPath et lance `pi`), plus les favoris demandes. Ecriture atomique, UTF-8 sans BOM,
         sauvegarde .bak, uniquement si T3 Code est ferme (sauf -Force : T3 recharge le fichier a chaud).
.PARAMETER InstanceId
    Identifiant de l'instance dans T3 Code (defaut : ohmypi).
.PARAMETER DisplayName
    Nom affiche dans T3 Code (defaut : Oh My Pi).
.PARAMETER Favorites
    Modeles a mettre en favoris, au format <fournisseur omp>/<id modele> (voir `omp models ls`).
.PARAMETER OmpT3Version
    Version de omp-t3 a installer (defaut : 1.5.0, testee avec omp 19.1.0 et T3 Code 0.1.11).
.PARAMETER SkipInstall
    Ne touche ni a Bun, ni a omp, ni a omp-t3 : configure seulement T3 Code.
.PARAMETER Force
    Ecrit settings.json meme si T3 Code est ouvert.
.PARAMETER Remove
    Retire l'instance et ses favoris de settings.json (ne desinstalle rien).
#>
param(
    [string]$InstanceId = "ohmypi",
    [string]$DisplayName = "Oh My Pi",
    [string[]]$Favorites = @(),
    [string]$OmpT3Version = "1.5.0",
    [switch]$SkipInstall,
    [switch]$Force,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$MinBun = [version]"1.4.4"
$PatchOld = "new ContractDoctor({ shimVersion: pkg.version })"
$PatchNew = "new ContractDoctor({ shimVersion: pkg.version, issuesEnabled: process.env.OMPT3_FILE_ISSUES === '1' })"

if ($InstanceId -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') { throw "InstanceId invalide : $InstanceId" }

# `powershell -File` passes "a","b" as ONE string: split on commas and strip quotes.
$Favorites = @($Favorites | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Trim('"', "'").Trim() } | Where-Object { $_ })

$t3Home = if (-not [string]::IsNullOrWhiteSpace($env:T3CODE_HOME)) { [System.IO.Path]::GetFullPath($env:T3CODE_HOME.Trim().Trim('"')) } else { Join-Path $env:USERPROFILE ".t3" }
$settingsPath = Join-Path (Join-Path $t3Home "userdata") "settings.json"

function Invoke-Native {
    # Runs a native command without letting stderr noise (warnings) abort the script.
    param([string]$File, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = (& $File @Arguments 2>&1 | Out-String).Trim()
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-CommandPath([string]$Name) {
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

# ---------------------------------------------------------------- 1..3 install
$ompT3Cmd = $null
if (-not $Remove) {
    if (-not $SkipInstall) {
        $bun = Get-CommandPath "bun"
        if (-not $bun) { throw "Bun est introuvable. Installez-le (https://bun.sh) puis relancez." }
        $bunVer = [version]((Invoke-Native $bun @("--version")).Output -replace '[^0-9.].*$', '')
        if ($bunVer -lt $MinBun) {
            Write-Host "[..] Bun $bunVer < $MinBun : bun upgrade" -ForegroundColor Cyan
            $r = Invoke-Native $bun @("upgrade")
            if ($r.Code -ne 0) { throw "bun upgrade a echoue : $($r.Output)" }
        }
        Write-Host "[OK] Bun $((Invoke-Native $bun @('--version')).Output)" -ForegroundColor Green

        $omp = Get-CommandPath "omp"
        $ompOk = $false
        if ($omp) { $r = Invoke-Native $omp @("--version"); $ompOk = ($r.Code -eq 0 -and $r.Output -match 'omp/') }
        if (-not $ompOk) {
            Write-Host "[..] omp absent ou casse : bun install -g @oh-my-pi/pi-coding-agent" -ForegroundColor Cyan
            $r = Invoke-Native $bun @("install", "-g", "@oh-my-pi/pi-coding-agent")
            if ($r.Code -ne 0) { throw "Installation de omp echouee : $($r.Output)" }
            $omp = Get-CommandPath "omp"
            if (-not $omp) { throw "omp reste introuvable apres installation (PATH ?)." }
        }
        Write-Host "[OK] $((Invoke-Native $omp @('--version')).Output) ($omp)" -ForegroundColor Green

        $npm = Get-CommandPath "npm.cmd"
        if (-not $npm) { throw "npm est introuvable (Node.js requis par omp-t3)." }
        $r = Invoke-Native $npm @("install", "-g", "omp-t3@$OmpT3Version")
        if ($r.Code -ne 0) { throw "npm install -g omp-t3@$OmpT3Version a echoue : $($r.Output)" }
        Write-Host "[OK] omp-t3@$OmpT3Version installe" -ForegroundColor Green
    }

    # Patch: issue filing becomes opt-in (OMPT3_FILE_ISSUES=1)
    $npmRoot = (Invoke-Native (Get-CommandPath "npm.cmd") @("root", "-g")).Output
    $proxyJs = Join-Path $npmRoot "omp-t3\src\proxy.js"
    if (-not (Test-Path -LiteralPath $proxyJs)) { throw "omp-t3 introuvable ($proxyJs). Relancez sans -SkipInstall." }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $src = [System.IO.File]::ReadAllText($proxyJs, $utf8NoBom)
    if ($src.Contains("OMPT3_FILE_ISSUES")) {
        Write-Host "[OK] Issues GitHub automatiques deja desactivees (opt-in OMPT3_FILE_ISSUES=1)." -ForegroundColor Cyan
    } elseif ($src.Contains($PatchOld)) {
        $count = ([regex]::Matches($src, [regex]::Escape($PatchOld))).Count
        [System.IO.File]::WriteAllText($proxyJs, $src.Replace($PatchOld, $PatchNew), $utf8NoBom)
        Write-Host "[OK] Issues GitHub automatiques desactivees ($count occurrence(s) patchee(s))." -ForegroundColor Green
    } else {
        Write-Warning "omp-t3 a change : patch des issues GitHub non applique. Verifiez src/doctor.js avant usage (il peut publier avec votre compte gh)."
    }

    $ompT3Cmd = Get-CommandPath "omp-t3.cmd"
    if (-not $ompT3Cmd) { throw "omp-t3.cmd introuvable dans le PATH." }
    $r = Invoke-Native $ompT3Cmd @("--check")
    if ($r.Output -notmatch 'All checks passed') {
        Write-Host $r.Output
        throw "omp-t3 --check a echoue."
    }
    Write-Host "[OK] omp-t3 --check : tout est vert" -ForegroundColor Green
}

# ---------------------------------------------------------------- 4 settings.json
if (-not (Test-Path -LiteralPath $settingsPath)) { throw "settings.json introuvable : $settingsPath (lancez T3 Code une fois)." }
$running = @(Get-Process | Where-Object { $_.ProcessName -match '^T3 Code' })
if ($running.Count -gt 0 -and -not $Force) {
    Write-Host "[SKIP] settings.json non modifie : fermez T3 Code ou relancez avec -Force." -ForegroundColor Yellow
    return
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$origWriteTime = (Get-Item -LiteralPath $settingsPath).LastWriteTimeUtc
$json = [System.IO.File]::ReadAllText($settingsPath, $utf8NoBom) | ConvertFrom-Json

if ($null -eq $json.PSObject.Properties["providerInstances"]) {
    $json | Add-Member -NotePropertyName "providerInstances" -NotePropertyValue ([pscustomobject]@{})
}
if ($null -eq $json.PSObject.Properties["favorites"]) {
    $json | Add-Member -NotePropertyName "favorites" -NotePropertyValue @()
}
$favs = @($json.favorites | Where-Object { $null -ne $_ })

if ($Remove) {
    $json.providerInstances.PSObject.Properties.Remove($InstanceId)
    $favs = @($favs | Where-Object { $_.provider -ne $InstanceId })
} else {
    # Driver-specific settings MUST live under `config`; top-level binaryPath is silently ignored.
    $instance = [pscustomobject]@{
        driver      = "pi"
        displayName = $DisplayName
        enabled     = $true
        config      = [pscustomobject]@{ binaryPath = $ompT3Cmd }
    }
    $json.providerInstances | Add-Member -NotePropertyName $InstanceId -NotePropertyValue $instance -Force
    foreach ($m in $Favorites) {
        if ($m -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._:/@+-]+$') { Write-Warning "Favori ignore (format <fournisseur>/<modele>) : $m"; continue }
        if (-not ($favs | Where-Object { $_.provider -eq $InstanceId -and $_.model -eq $m })) {
            $favs += [pscustomobject]@{ provider = $InstanceId; model = $m }
        }
    }
}
$json.favorites = @($favs)

$serialized = $json | ConvertTo-Json -Depth 32
$null = $serialized | ConvertFrom-Json
$tmp = "$settingsPath.tmp.$([guid]::NewGuid().ToString('N'))"
try {
    [System.IO.File]::WriteAllText($tmp, $serialized + "`n", $utf8NoBom)
    if ((Get-Item -LiteralPath $settingsPath).LastWriteTimeUtc -ne $origWriteTime) {
        throw "settings.json a change pendant l'operation ; modification annulee."
    }
    [System.IO.File]::Replace($tmp, $settingsPath, "$settingsPath.bak")
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

if ($Remove) {
    Write-Host "[OK] Instance '$InstanceId' et ses favoris retires de settings.json (sauvegarde : settings.json.bak)." -ForegroundColor Yellow
} else {
    Write-Host "[OK] '$DisplayName' ($InstanceId) -> $ompT3Cmd ; $(@($favs | Where-Object { $_.provider -eq $InstanceId }).Count) favori(s). Sauvegarde : settings.json.bak" -ForegroundColor Green
    Write-Host "     Si T3 Code etait ouvert, il recharge settings.json tout seul ; sinon ouvrez-le et choisissez '$DisplayName'." -ForegroundColor Cyan
}
