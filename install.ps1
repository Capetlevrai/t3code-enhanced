param(
    [switch]$UseVbs
)

$ErrorActionPreference = "Stop"

$label = "Ouvrir dans T3 Code"
$installDir = Join-Path $env:LOCALAPPDATA "t3code-context-menu"
$sourceCs = Join-Path $PSScriptRoot "open-in-t3code.cs"
$targetExe = Join-Path $installDir "open-in-t3code.exe"
$sourceVbs = Join-Path $PSScriptRoot "open-in-t3code.vbs"
$targetVbs = Join-Path $installDir "open-in-t3code.vbs"

# Find T3 Code icon
$t3Dir = Join-Path $env:LOCALAPPDATA "Programs\t3code"
$exePath = @(
    (Join-Path $t3Dir "T3 Code (Beta).exe"),
    (Join-Path $t3Dir "T3 Code.exe")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $exePath) {
    throw "T3 Code est introuvable dans $t3Dir"
}

New-Item -ItemType Directory -Path $installDir -Force | Out-Null

# Compute exact T3 Code control pipe path for 0 ms detection in VBS fallback
$t3Home = if ($env:T3CODE_HOME) { [System.IO.Path]::GetFullPath($env:T3CODE_HOME.Trim()) } else { Join-Path $env:USERPROFILE ".t3" }
$stateDir = [System.IO.Path]::GetFullPath((Join-Path $t3Home "userdata"))
$sha = [System.Security.Cryptography.SHA256]::Create()
$hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stateDir))
$pipeHash = -join ($hashBytes[0..11] | ForEach-Object { $_.ToString("x2") })
$pipePath = "\\.\pipe\t3code-app-$pipeHash"

# Always install optimized VBS fallback with injected pipe path
$vbsContent = (Get-Content -LiteralPath $sourceVbs -Raw) -replace "__T3_PIPE_PATH__", $pipePath
Set-Content -LiteralPath $targetVbs -Value $vbsContent -Encoding ASCII

# Prefer compiling native .NET WinExe launcher (~70 ms warm start, 15 ms cold-start detection)
$cscPath = @(
    "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$useNativeExe = $false
if (-not $UseVbs -and $cscPath -and (Test-Path -LiteralPath $sourceCs)) {
    Write-Host "Compilation du lanceur natif open-in-t3code.exe..." -ForegroundColor Cyan
    # Compile to a temp file first: if the current exe is running (a launcher still waiting on a
    # cold start) csc cannot overwrite it, and we must not silently downgrade to the VBS launcher.
    $newExe = "$targetExe.new"
    Remove-Item -LiteralPath $newExe -Force -ErrorAction SilentlyContinue
    & $cscPath /nologo /target:winexe /optimize+ /out:"$newExe" /r:System.Windows.Forms.dll /r:System.Core.dll "$sourceCs"
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $newExe)) {
        try {
            Move-Item -LiteralPath $newExe -Destination $targetExe -Force
        } catch {
            # Running exes can be renamed but not overwritten on Windows.
            $oldExe = "$targetExe.old"
            Remove-Item -LiteralPath $oldExe -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $targetExe -Destination $oldExe -Force
            Move-Item -LiteralPath $newExe -Destination $targetExe -Force
        }
        $useNativeExe = $true
    } elseif (Test-Path -LiteralPath $targetExe) {
        Write-Warning "Compilation C# echouee, conservation du lanceur natif deja installe."
        $useNativeExe = $true
    } else {
        Write-Warning "Compilation C# echouee, bascule sur open-in-t3code.vbs."
    }
    Remove-Item -LiteralPath $newExe -Force -ErrorAction SilentlyContinue
}

$iconValue = "`"$exePath`",0"
# Suffix `\.' inside quotes so drive roots like C:\ never escape the closing quote (C:\ -> C:\.\ -> C:\)
$entries = @(
    @{ Key = "HKCU:\Software\Classes\Directory\shell\T3CodeOpen";            Arg = "%1\." },
    @{ Key = "HKCU:\Software\Classes\Directory\Background\shell\T3CodeOpen"; Arg = "%V\." },
    @{ Key = "HKCU:\Software\Classes\Drive\shell\T3CodeOpen";                Arg = "%V\." }
)

foreach ($entry in $entries) {
    $key = $entry.Key
    $cmdKey = "$key\command"
    if ($useNativeExe) {
        $cmdValue = "`"$targetExe`" `"$($entry.Arg)`""
    } else {
        $cmdValue = "wscript.exe //B //NoLogo `"$targetVbs`" `"$($entry.Arg)`""
    }

    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name "(Default)" -Value $label
    Set-ItemProperty -Path $key -Name "Icon" -Value $iconValue

    New-Item -Path $cmdKey -Force | Out-Null
    Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value $cmdValue
}

Write-Host "Raccourci '$label' installe avec succes !" -ForegroundColor Green
if ($useNativeExe) {
    Write-Host "Lanceur natif : $targetExe (IPC direct sur $pipePath)" -ForegroundColor Green
} else {
    Write-Host "Lanceur VBS   : $targetVbs (detection rapide sur $pipePath)" -ForegroundColor Green
}
