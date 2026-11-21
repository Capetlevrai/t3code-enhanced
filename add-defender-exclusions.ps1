param(
    # Paths are resolved by the non-elevated instance and passed to the elevated one: if UAC asks
    # for a different admin account, $env:LOCALAPPDATA/$env:USERPROFILE would point to that
    # admin's profile instead of yours.
    [string]$T3InstallDir,
    [string]$T3UserDataDir,
    # Old behaviour: exclude the whole T3 home (attachments, provider downloads, worktrees...).
    [switch]$Broad
)

$ErrorActionPreference = "Stop"

if (-not $T3InstallDir) { $T3InstallDir = Join-Path $env:LOCALAPPDATA "Programs\t3code" }
if (-not $T3UserDataDir) {
    $t3Home = if ($env:T3CODE_HOME -and $env:T3CODE_HOME.Trim()) { $env:T3CODE_HOME.Trim() } else { Join-Path $env:USERPROFILE ".t3" }
    $T3UserDataDir = [System.IO.Path]::GetFullPath((Join-Path $t3Home "userdata"))
}

# Auto-elevate to Administrator if needed (triggers standard Windows UAC prompt)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "Elevation administrateur requise pour configurer Windows Defender..." -ForegroundColor Yellow
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -T3InstallDir `"$T3InstallDir`" -T3UserDataDir `"$T3UserDataDir`""
    if ($Broad) { $argList += " -Broad" }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

# Narrow by default: the signed app binaries (server.asar is ~260 MB and is scanned on every
# launch) plus the files T3 Code writes constantly (trace logs, SQLite database + WAL).
# Attachments, provider downloads and worktrees stay scanned: they hold files fetched by agents.
$paths = @($T3InstallDir)
if ($Broad) {
    $paths += (Split-Path -Parent $T3UserDataDir)
} else {
    $paths += (Join-Path $T3UserDataDir "logs")
    $paths += (Join-Path $T3UserDataDir "statev2.sqlite*")
}

foreach ($path in $paths) {
    $probe = $path -replace '\*$', ''
    if (Test-Path -Path "$probe*") {
        Add-MpPreference -ExclusionPath $path
        Write-Host "[OK] Exclusion Windows Defender ajoutee : $path" -ForegroundColor Green
    } else {
        Write-Host "[SKIP] Introuvable : $path" -ForegroundColor Yellow
    }
}

Write-Host "`nExclusions T3 Code actives :" -ForegroundColor Cyan
(Get-MpPreference).ExclusionPath | Where-Object { $_ -match "t3code|\\\.t3" } | ForEach-Object { Write-Host "  - $_" }
