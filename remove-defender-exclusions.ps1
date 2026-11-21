param(
    [string]$T3InstallDir,
    [string]$T3UserDataDir
)

$ErrorActionPreference = "Stop"

if (-not $T3InstallDir) { $T3InstallDir = Join-Path $env:LOCALAPPDATA "Programs\t3code" }
if (-not $T3UserDataDir) {
    $t3Home = if ($env:T3CODE_HOME -and $env:T3CODE_HOME.Trim()) { $env:T3CODE_HOME.Trim() } else { Join-Path $env:USERPROFILE ".t3" }
    $T3UserDataDir = [System.IO.Path]::GetFullPath((Join-Path $t3Home "userdata"))
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "Elevation administrateur requise pour modifier Windows Defender..." -ForegroundColor Yellow
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -T3InstallDir `"$T3InstallDir`" -T3UserDataDir `"$T3UserDataDir`""
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

# Removes both the narrow set (current default) and the broad T3 home exclusion (older versions / -Broad).
$paths = @(
    $T3InstallDir,
    (Join-Path $T3UserDataDir "logs"),
    (Join-Path $T3UserDataDir "statev2.sqlite*"),
    (Split-Path -Parent $T3UserDataDir)
)

$current = @((Get-MpPreference).ExclusionPath)
foreach ($path in $paths) {
    if ($current -contains $path) {
        Remove-MpPreference -ExclusionPath $path
        Write-Host "[OK] Exclusion retiree : $path" -ForegroundColor Yellow
    }
}
