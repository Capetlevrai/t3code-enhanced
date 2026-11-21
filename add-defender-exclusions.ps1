$ErrorActionPreference = "Stop"

# Auto-elevate to Administrator if needed (triggers standard Windows UAC prompt)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "Elevation administrateur requise pour configurer Windows Defender..." -ForegroundColor Yellow
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Wait -PassThru
    exit $p.ExitCode
}

$paths = @(
    (Join-Path $env:LOCALAPPDATA "Programs\t3code"),
    (Join-Path $env:USERPROFILE ".t3")
)

foreach ($path in $paths) {
    if (Test-Path $path) {
        Add-MpPreference -ExclusionPath $path
        Write-Host "[OK] Exclusion Windows Defender ajoutee : $path" -ForegroundColor Green
    } else {
        Write-Host "[SKIP] Dossier introuvable : $path" -ForegroundColor Yellow
    }
}

Write-Host "`nExclusions T3 Code actives :" -ForegroundColor Cyan
(Get-MpPreference).ExclusionPath | Where-Object { $_ -match "t3code|\.t3" } | ForEach-Object { Write-Host "  - $_" }
