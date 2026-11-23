<#
.SYNOPSIS
    Ajoute Oh My Pi (omp) comme fournisseur dans T3 Code sous Windows, via le shim omp-t3.
.DESCRIPTION
    T3 Code n'a pas de pilote Oh My Pi. Il a un pilote "Pi" (RPC JSONL) et omp-t3
    (https://github.com/hashangit/omp-t3) adapte omp a ce pilote. Ce script :
      1. Verifie Bun (>= 1.4.4, exige par omp 19.x) et omp (le reinstalle avec Bun s'il est casse).
      2. Installe omp-t3 a la version epinglee (npm -g) s'il est absent, ou si -OmpT3Version est donne.
         Un omp-t3 deja installe n'est jamais retrograde.
      3. Rend opt-in la creation automatique d'issues GitHub de omp-t3 (par defaut il utilise
         votre `gh` connecte pour publier une issue publique en votre nom) en patchant la valeur par
         defaut de src/doctor.js. Sans verification complete, le script s'arrete AVANT d'activer le
         fournisseur. `npm update -g omp-t3` annule le patch : relancez ensuite ce script.
      4. Lance `omp-t3 --check` avec le lanceur du meme prefixe npm que le paquet patche.
      5. Ecrit le fournisseur dans settings.json de T3 Code (cle `config`, sinon T3 ignore
         binaryPath et lance `pi`) en fusionnant avec une instance existante, plus les favoris.
         Ecriture atomique, UTF-8 sans BOM, sauvegarde .bak, rien n'est reecrit si rien ne change,
         uniquement si T3 Code est ferme (sauf -Force : T3 recharge le fichier a chaud).
.PARAMETER InstanceId
    Identifiant de l'instance dans T3 Code (defaut : ohmypi).
.PARAMETER DisplayName
    Nom affiche dans T3 Code (defaut : Oh My Pi). Applique seulement a la creation.
.PARAMETER Favorites
    Modeles a mettre en favoris, au format <fournisseur omp>/<id modele> (voir `omp models ls`).
.PARAMETER OmpT3Version
    Version de omp-t3 a installer quand il est absent (defaut : 1.5.0, testee avec omp 19.1.0 et
    T3 Code 0.1.11). Donnee explicitement, elle est installee meme si une autre version est presente.
.PARAMETER SkipInstall
    N'installe ni Bun, ni omp, ni omp-t3. Le patch des issues et `omp-t3 --check` sont quand meme
    appliques/lances sur le omp-t3 deja installe.
.PARAMETER Force
    Ecrit settings.json meme si T3 Code est ouvert.
.PARAMETER Remove
    Retire l'instance (seulement si c'est bien une instance Pi pointant vers omp-t3) et ses favoris.
    Ne desinstalle rien.
#>
# No positional binding: with `-File`, `-Favorites "a", "b"` would otherwise bind "b" to another parameter.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$InstanceId = "ohmypi",
    [string]$DisplayName = "Oh My Pi",
    [string[]]$Favorites = @(),
    [string]$OmpT3Version = "1.5.0",
    [switch]$SkipInstall,
    [switch]$Force,
    [switch]$Remove,
    # `powershell -File x.ps1 -Favorites "a", "b"` delivers "b" as a stray argument: collect it as a favorite.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$MoreFavorites = @()
)

$ErrorActionPreference = "Stop"
$MinBun = [version]"1.4.4"
$MaxJsonDepth = 30   # ConvertTo-Json -Depth 32 below; deeper settings would be stringified silently
# Single default for every ContractDoctor (src/doctor.js); call sites that pass nothing get "off".
$PatchOld = "this.issuesEnabled = options.issuesEnabled !== false;"
$PatchNew = "this.issuesEnabled = options.issuesEnabled === true || (options.issuesEnabled !== false && process.env.OMPT3_FILE_ISSUES === '1');"

if ($InstanceId -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') { throw "InstanceId invalide : $InstanceId" }

# `powershell -File` passes "a","b" as ONE string: split on commas and strip quotes.
foreach ($a in $MoreFavorites) {
    if ($a -match '^-') { throw "Parametre inconnu : $a" }
}
$Favorites = @(@($Favorites) + @($MoreFavorites) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Trim('"', "'").Trim() } | Where-Object { $_ })

$t3Home = if (-not [string]::IsNullOrWhiteSpace($env:T3CODE_HOME)) { [System.IO.Path]::GetFullPath($env:T3CODE_HOME.Trim().Trim('"')) } else { Join-Path $env:USERPROFILE ".t3" }
$settingsPath = Join-Path (Join-Path $t3Home "userdata") "settings.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

function Write-FileAtomic([string]$Path, [string]$Content, [string]$Backup) {
    $tmp = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tmp, $Content, $utf8NoBom)
        [System.IO.File]::Replace($tmp, $Path, $Backup)
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-NpmPath([string]$Npm, [string]$What, [switch]$AllowMissing) {
    # stdout only: npm warnings on stderr must not end up in the path.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $lines = @(& $Npm $What "-g" 2>$null) } finally { $ErrorActionPreference = $prev }
    $path = @($lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -Last 1
    # Before the first global install, `npm root -g` can name a folder that does not exist yet.
    $ok = ($LASTEXITCODE -eq 0 -and $path -and [System.IO.Path]::IsPathRooted($path) -and ($AllowMissing -or (Test-Path -LiteralPath $path)))
    if (-not $ok) { throw "npm $What -g a echoue ou renvoie un chemin invalide : '$path'." }
    return $path
}

function Get-BunVersion([string]$Bun) {
    $r = Invoke-Native $Bun @("--version")
    $m = [regex]::Match($r.Output, '\d+\.\d+\.\d+')
    if ($r.Code -ne 0 -or -not $m.Success) { throw "bun --version a echoue : $($r.Output)" }
    return [version]$m.Value
}

function Get-JsonDepth($Node) {
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $max = 0
        foreach ($p in $Node.PSObject.Properties) { $d = Get-JsonDepth $p.Value; if ($d -gt $max) { $max = $d } }
        return 1 + $max
    }
    if ($Node -is [System.Collections.IList]) {
        $max = 0
        foreach ($v in $Node) { $d = Get-JsonDepth $v; if ($d -gt $max) { $max = $d } }
        return 1 + $max
    }
    return 0
}

function Test-IsOmpT3Instance($Instance) {
    if ($null -eq $Instance -or $Instance.driver -ne "pi") { return $false }
    $cfg = $Instance.PSObject.Properties["config"]
    if ($null -eq $cfg -or $null -eq $cfg.Value) { return $false }
    $bp = $cfg.Value.PSObject.Properties["binaryPath"]
    return ($null -ne $bp -and (Test-IsOmpT3Launcher ([string]$bp.Value)))
}

function Test-IsOmpT3Launcher([string]$Path) {
    # Whole file name, not a suffix: "custom-omp-t3.cmd" is someone else's launcher.
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return @("omp-t3", "omp-t3.cmd") -contains [System.IO.Path]::GetFileName($Path.Trim().Trim('"')).ToLowerInvariant()
}

# ---------------------------------------------------------------- 1..4 install, patch, check
$ompT3Cmd = $null
if (-not $Remove) {
    $npm = Get-CommandPath "npm.cmd"
    if (-not $npm) { throw "npm est introuvable (Node.js requis par omp-t3)." }

    if (-not $SkipInstall) {
        $bun = Get-CommandPath "bun"
        if (-not $bun) { throw "Bun est introuvable. Installez-le (https://bun.sh) puis relancez." }
        $bunVer = Get-BunVersion $bun
        if ($bunVer -lt $MinBun) {
            Write-Host "[..] Bun $bunVer < $MinBun : bun upgrade" -ForegroundColor Cyan
            $r = Invoke-Native $bun @("upgrade")
            if ($r.Code -ne 0) { throw "bun upgrade a echoue : $($r.Output)" }
            $bunVer = Get-BunVersion $bun
            if ($bunVer -lt $MinBun) { throw "Bun reste en $bunVer apres bun upgrade (minimum $MinBun)." }
        }
        Write-Host "[OK] Bun $bunVer" -ForegroundColor Green

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

        # Never downgrade an installed omp-t3 unless a version was asked for explicitly.
        $installedPkg = Join-Path (Get-NpmPath $npm "root" -AllowMissing) "omp-t3\package.json"
        $installedVer = $null
        if (Test-Path -LiteralPath $installedPkg) { $installedVer = ([System.IO.File]::ReadAllText($installedPkg, $utf8NoBom) | ConvertFrom-Json).version }
        if ($installedVer -and -not $PSBoundParameters.ContainsKey("OmpT3Version")) {
            Write-Host "[OK] omp-t3 $installedVer deja installe (conserve ; -OmpT3Version pour changer)." -ForegroundColor Cyan
        } elseif ($installedVer -eq $OmpT3Version) {
            Write-Host "[OK] omp-t3 $installedVer deja installe." -ForegroundColor Cyan
        } else {
            $r = Invoke-Native $npm @("install", "-g", "omp-t3@$OmpT3Version")
            if ($r.Code -ne 0) { throw "npm install -g omp-t3@$OmpT3Version a echoue : $($r.Output)" }
            Write-Host "[OK] omp-t3@$OmpT3Version installe" -ForegroundColor Green
        }
    }

    # The package and its launcher must come from the SAME npm prefix (several Node installs are common).
    $npmRoot = Get-NpmPath $npm "root"
    $npmPrefix = Get-NpmPath $npm "prefix"
    $pkgDir = Join-Path $npmRoot "omp-t3"
    $doctorJs = Join-Path $pkgDir "src\doctor.js"
    $ompT3Cmd = Join-Path $npmPrefix "omp-t3.cmd"
    if (-not (Test-Path -LiteralPath $doctorJs)) { throw "omp-t3 introuvable ($pkgDir). Relancez sans -SkipInstall." }
    if (-not (Test-Path -LiteralPath $ompT3Cmd)) { throw "Lanceur introuvable : $ompT3Cmd (prefixe npm $npmPrefix)." }
    $onPath = Get-CommandPath "omp-t3.cmd"
    if ($onPath -and ([System.IO.Path]::GetFullPath($onPath) -ne [System.IO.Path]::GetFullPath($ompT3Cmd))) {
        Write-Warning "Un autre omp-t3 passe avant dans le PATH ($onPath). T3 Code utilisera $ompT3Cmd."
    }

    # Patch: issue filing becomes opt-in (OMPT3_FILE_ISSUES=1) at its single default in src/doctor.js.
    $src = [System.IO.File]::ReadAllText($doctorJs, $utf8NoBom)
    $patched = $src.Replace($PatchOld, $PatchNew)
    $defaults = [regex]::Matches($patched, 'this\.issuesEnabled\s*=[^;]*;')
    # No call site may force it on, in any shipped JS file. Filter on the path RELATIVE to the package:
    # the absolute path of a global install always contains \node_modules\.
    $pkgFull = [System.IO.Path]::GetFullPath($pkgDir).TrimEnd('\') + '\'
    # No -Include: Windows PowerShell 5.1 ignores it with -LiteralPath. bin\ holds extension-less Node scripts.
    $shipped = @(Get-ChildItem -LiteralPath $pkgDir -Recurse -File -ErrorAction Stop | Where-Object {
        $rel = $_.FullName.Substring($pkgFull.Length)
        (@('.js', '.cjs', '.mjs') -contains $_.Extension.ToLowerInvariant() -or $rel -match '^bin\\[^\\.]+$') -and
        $rel -notmatch '^(node_modules|test|tests)\\|\\(node_modules|test|tests)\\'
    })
    $forcedOn = @($shipped | Where-Object { $_.FullName -ne [System.IO.Path]::GetFullPath($doctorJs) } |
        Select-String -Pattern 'issuesEnabled\s*:\s*(true|!0|1)\b' -List)
    if ($shipped.Count -eq 0 -or @($shipped | Where-Object { $_.Name -eq 'proxy.js' }).Count -eq 0) {
        throw "omp-t3 : aucun fichier source examine ($pkgDir). Fournisseur NON active."
    }
    if ($defaults.Count -ne 1 -or $defaults[0].Value -ne $PatchNew -or $forcedOn.Count -gt 0) {
        throw "omp-t3 a change : impossible de verifier que les issues GitHub automatiques sont coupees (src/doctor.js). Fournisseur NON active ; verifiez src/doctor.js et src/proxy.js."
    }
    if ($patched -ne $src) {
        Write-FileAtomic $doctorJs $patched "$doctorJs.orig"
        Write-Host "[OK] Issues GitHub automatiques desactivees (opt-in OMPT3_FILE_ISSUES=1 ; original : doctor.js.orig)." -ForegroundColor Green
    } else {
        Write-Host "[OK] Issues GitHub automatiques deja desactivees (opt-in OMPT3_FILE_ISSUES=1)." -ForegroundColor Cyan
    }

    $r = Invoke-Native $ompT3Cmd @("--check")
    # Windows PowerShell wraps native stderr in error records: keep only the message part, once.
    $warnings = @($r.Output -split "`r?`n" | Where-Object { $_ -notmatch 'CategoryInfo|FullyQualifiedErrorId' } |
        ForEach-Object { [regex]::Match($_, '(\[(WARN|FAIL)\].*|Existing path at .*Skipping overwrite\.|Failed to create session symlink.*)').Value } |
        Where-Object { $_ } | Select-Object -Unique)
    if ($r.Code -ne 0 -or $r.Output -notmatch 'All checks passed') {
        Write-Host $r.Output
        throw "omp-t3 --check a echoue (code $($r.Code))."
    }
    foreach ($w in $warnings) { Write-Host "[WARN] omp-t3 --check : $(($w -replace '^\[(WARN|FAIL)\]\s*', '').Trim())" -ForegroundColor Yellow }
    Write-Host "[OK] omp-t3 --check reussi ($ompT3Cmd)" -ForegroundColor Green
}

# ---------------------------------------------------------------- 5 settings.json
if (-not (Test-Path -LiteralPath $settingsPath)) { throw "settings.json introuvable : $settingsPath (lancez T3 Code une fois)." }
$running = @(Get-Process | Where-Object { $_.ProcessName -match '^T3 Code' })
if ($running.Count -gt 0 -and -not $Force) {
    Write-Host "[SKIP] settings.json non modifie : fermez T3 Code ou relancez avec -Force." -ForegroundColor Yellow
    return
}

$origWriteTime = (Get-Item -LiteralPath $settingsPath).LastWriteTimeUtc
$json = [System.IO.File]::ReadAllText($settingsPath, $utf8NoBom) | ConvertFrom-Json
if ($null -eq $json -or $json -isnot [System.Management.Automation.PSCustomObject]) { throw "settings.json est vide ou n'est pas un objet JSON : $settingsPath" }
$depth = Get-JsonDepth $json
if ($depth -gt $MaxJsonDepth) { throw "settings.json est trop imbrique ($depth niveaux > $MaxJsonDepth) pour une reecriture sure sous PowerShell ; rien n'a ete modifie." }
$before = $json | ConvertTo-Json -Depth 32 -Compress

$hasInstances = ($null -ne $json.PSObject.Properties["providerInstances"] -and $null -ne $json.providerInstances)
if (-not $hasInstances -and -not $Remove) {
    $json | Add-Member -NotePropertyName "providerInstances" -NotePropertyValue ([pscustomobject]@{}) -Force
    $hasInstances = $true
}
$existing = if ($hasInstances) { $json.providerInstances.PSObject.Properties[$InstanceId] } else { $null }
$favs = @()
if ($null -ne $json.PSObject.Properties["favorites"]) { $favs = @($json.favorites | Where-Object { $null -ne $_ }) }

if ($Remove) {
    if ($null -eq $existing) {
        Write-Host "[OK] Aucune instance '$InstanceId' : rien a retirer." -ForegroundColor Cyan
    } elseif (-not (Test-IsOmpT3Instance $existing.Value)) {
        throw "L'instance '$InstanceId' n'est pas une instance Pi pointant vers omp-t3 ; refus de la retirer."
    } else {
        $json.providerInstances.PSObject.Properties.Remove($InstanceId)
    }
    if ($null -ne $existing -or @($favs | Where-Object { $_.provider -eq $InstanceId }).Count -gt 0) {
        if ($null -ne $json.PSObject.Properties["favorites"]) {
            $json.favorites = @($favs | Where-Object { $_.provider -ne $InstanceId })
        }
    }
} else {
    if ($null -ne $existing -and $existing.Value.driver -ne "pi") {
        throw "L'instance '$InstanceId' existe deja avec le pilote '$($existing.Value.driver)'. Choisissez un autre -InstanceId."
    }
    if ($null -ne $existing) {
        # A Pi instance pointing at another launcher (upstream pi, a custom wrapper) is not ours to convert.
        $cfgProp = $existing.Value.PSObject.Properties["config"]
        $bpProp = if ($null -ne $cfgProp -and $null -ne $cfgProp.Value) { $cfgProp.Value.PSObject.Properties["binaryPath"] } else { $null }
        # A top-level binaryPath (ignored by T3 Code) pointing at omp-t3 is a broken earlier attempt: migrate it.
        $topBp = $existing.Value.PSObject.Properties["binaryPath"]
        $isOurs = (Test-IsOmpT3Launcher $(if ($null -ne $bpProp) { [string]$bpProp.Value } else { "" })) -or
                  ($null -eq $bpProp -and $null -ne $topBp -and (Test-IsOmpT3Launcher ([string]$topBp.Value)))
        if (-not $isOurs) {
            # Includes a stock Pi instance without binaryPath, which runs `pi` from PATH.
            $what = if ($null -ne $bpProp -and -not [string]::IsNullOrWhiteSpace([string]$bpProp.Value)) { "'$($bpProp.Value)'" } else { "pi (instance Pi standard)" }
            throw "L'instance '$InstanceId' est une instance Pi qui lance $what. Choisissez un autre -InstanceId."
        }
    }
    if ($null -eq $existing) {
        $instance = [pscustomobject]@{ driver = "pi"; displayName = $DisplayName; enabled = $true; config = [pscustomobject]@{} }
        $json.providerInstances | Add-Member -NotePropertyName $InstanceId -NotePropertyValue $instance
    } else {
        # Merge: keep environment, accentColor, displayName and other config fields untouched.
        $instance = $existing.Value
        if ($null -eq $instance.PSObject.Properties["enabled"]) { $instance | Add-Member -NotePropertyName "enabled" -NotePropertyValue $true } else { $instance.enabled = $true }
        if ($null -eq $instance.PSObject.Properties["displayName"] -or [string]::IsNullOrWhiteSpace([string]$instance.displayName)) {
            $instance | Add-Member -NotePropertyName "displayName" -NotePropertyValue $DisplayName -Force
        }
        if ($null -eq $instance.PSObject.Properties["config"] -or $null -eq $instance.config) {
            $instance | Add-Member -NotePropertyName "config" -NotePropertyValue ([pscustomobject]@{}) -Force
        }
    }
    # Driver settings MUST live under `config`; top-level binaryPath is silently ignored by T3 Code.
    $instance.config | Add-Member -NotePropertyName "binaryPath" -NotePropertyValue $ompT3Cmd -Force
    if ($null -ne $instance.PSObject.Properties["binaryPath"]) { $instance.PSObject.Properties.Remove("binaryPath") }

    foreach ($m in $Favorites) {
        if ($m -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._:/@+-]+$') { Write-Warning "Favori ignore (format <fournisseur>/<modele>) : $m"; continue }
        if (-not ($favs | Where-Object { $_.provider -eq $InstanceId -and $_.model -eq $m })) {
            $favs += [pscustomobject]@{ provider = $InstanceId; model = $m }
        }
    }
    if ($null -eq $json.PSObject.Properties["favorites"]) {
        if ($favs.Count -gt 0) { $json | Add-Member -NotePropertyName "favorites" -NotePropertyValue @($favs) }
    } elseif ($null -ne $json.favorites -or $favs.Count -gt 0) {
        $json.favorites = @($favs)
    }
}

$after = $json | ConvertTo-Json -Depth 32 -Compress
if ($after -eq $before) {
    Write-Host "[OK] settings.json deja a jour : aucune reecriture (la sauvegarde .bak existante est conservee)." -ForegroundColor Cyan
    return
}

$serialized = $json | ConvertTo-Json -Depth 32
$null = $serialized | ConvertFrom-Json
if ((Get-Item -LiteralPath $settingsPath).LastWriteTimeUtc -ne $origWriteTime) {
    throw "settings.json a change pendant l'operation ; modification annulee."
}
Write-FileAtomic $settingsPath ($serialized + "`n") "$settingsPath.bak"

if ($Remove) {
    Write-Host "[OK] Instance '$InstanceId' et ses favoris retires de settings.json (sauvegarde : settings.json.bak)." -ForegroundColor Yellow
} else {
    Write-Host "[OK] '$($instance.displayName)' ($InstanceId) -> $ompT3Cmd ; $(@($favs | Where-Object { $_.provider -eq $InstanceId }).Count) favori(s). Sauvegarde : settings.json.bak" -ForegroundColor Green
    Write-Host "     Si T3 Code etait ouvert, il recharge settings.json tout seul ; sinon ouvrez-le et choisissez '$($instance.displayName)'." -ForegroundColor Cyan
}
