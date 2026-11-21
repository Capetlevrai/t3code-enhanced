$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "Elevation administrateur requise pour modifier Windows Defender..." -ForegroundColor Yellow
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Wait -PassThru
    exit $p.ExitCode
}

$paths = @(
    (Join-Path $env:LOCALAPPDATA "Programs\t3code"),
    (Join-Path $env:USERPROFILE ".t3")
)

foreach ($path in $paths) {
    Remove-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
    Write-Host "[OK] Exclusion retiree : $path" -ForegroundColor Yellow
}
