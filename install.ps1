$ErrorActionPreference = "Stop"

$label = "Ouvrir dans T3 Code"
$installDir = Join-Path $env:LOCALAPPDATA "t3code-context-menu"
$sourceVbs = Join-Path $PSScriptRoot "open-in-t3code.vbs"
$targetVbs = Join-Path $installDir "open-in-t3code.vbs"

# Find T3 Code icon
$t3Dir = Join-Path $env:LOCALAPPDATA "Programs\t3code"
$exePath = @(
    (Join-Path $t3Dir "T3 Code (Beta).exe"),
    (Join-Path $t3Dir "T3 Code.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $exePath) {
    throw "T3 Code est introuvable dans $t3Dir"
}

# Copy launcher to permanent AppData location
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -Path $sourceVbs -Destination $targetVbs -Force

$iconValue = "`"$exePath`",0"
$entries = @(
    @{ Key = "HKCU:\Software\Classes\Directory\shell\T3CodeOpen";            Arg = "%1" },
    @{ Key = "HKCU:\Software\Classes\Directory\Background\shell\T3CodeOpen"; Arg = "%V" },
    @{ Key = "HKCU:\Software\Classes\Drive\shell\T3CodeOpen";                Arg = "%V" }
)

foreach ($entry in $entries) {
    $key = $entry.Key
    $cmdKey = "$key\command"
    $cmdValue = "wscript.exe //B //NoLogo `"$targetVbs`" `"$($entry.Arg)`""

    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name "(Default)" -Value $label
    Set-ItemProperty -Path $key -Name "Icon" -Value $iconValue

    New-Item -Path $cmdKey -Force | Out-Null
    Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value $cmdValue
}

Write-Host "Raccourci '$label' installe avec succes !" -ForegroundColor Green
Write-Host "Lanceur : $targetVbs"
