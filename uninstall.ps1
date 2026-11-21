$ErrorActionPreference = "Stop"

$keys = @(
    "HKCU:\Software\Classes\Directory\shell\T3CodeOpen",
    "HKCU:\Software\Classes\Directory\Background\shell\T3CodeOpen",
    "HKCU:\Software\Classes\Drive\shell\T3CodeOpen"
)

foreach ($key in $keys) {
    if (Test-Path $key) {
        Remove-Item -Path $key -Recurse -Force
    }
}

Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "T3CodeBackground" -ErrorAction SilentlyContinue

$installDir = Join-Path $env:LOCALAPPDATA "t3code-context-menu"
if (Test-Path -LiteralPath $installDir) {
    try {
        Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "Impossible de supprimer completement $installDir (fichier verrouille) : $($_.Exception.Message)"
    }
}

Write-Host "Raccourci T3 Code (et autostart eventuel) desinstalle proprement." -ForegroundColor Yellow
