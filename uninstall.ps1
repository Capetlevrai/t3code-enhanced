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

$installDir = Join-Path $env:LOCALAPPDATA "t3code-context-menu"
if (Test-Path $installDir) {
    Remove-Item -Path $installDir -Recurse -Force
}

Write-Host "Raccourci T3 Code desinstalle proprement." -ForegroundColor Yellow
