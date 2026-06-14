#!/usr/bin/env pwsh
<#
  build.ps1 - Kompiliert senity.iss zu dist\senity-setup.exe via Inno Setup.

  Voraussetzung: Inno Setup 6 (ISCC.exe). Wird es nicht gefunden, kann es per
  -Install via winget installiert werden (Paket: JRSoftware.InnoSetup).

  Usage:
    .\build.ps1                 Build
    .\build.ps1 -Install        Inno Setup via winget installieren, dann Build
    .\build.ps1 -Version 1.2.0  Versionsnummer ueberschreiben
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$Version
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$IssFile   = Join-Path $ScriptDir "senity.iss"
$OutDir    = Join-Path $ScriptDir "dist"

function Find-ISCC {
    $cmd = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )) { if (Test-Path $p) { return $p } }
    return $null
}

$iscc = Find-ISCC
if (-not $iscc -and $Install) {
    Write-Host "[build] Installiere Inno Setup via winget..." -ForegroundColor Cyan
    winget install --id JRSoftware.InnoSetup -e --accept-source-agreements --accept-package-agreements
    $iscc = Find-ISCC
}
if (-not $iscc) {
    Write-Host "[build] ISCC.exe nicht gefunden." -ForegroundColor Red
    Write-Host "        Inno Setup 6 installieren: winget install --id JRSoftware.InnoSetup -e" -ForegroundColor Yellow
    Write-Host "        oder: .\build.ps1 -Install" -ForegroundColor Yellow
    exit 1
}

$isccArgs = @("/Qp")
if ($Version) { $isccArgs += "/DAppVersion=$Version" }
$isccArgs += $IssFile

Write-Host "[build] ISCC: $iscc" -ForegroundColor Magenta
Write-Host "[build] Kompiliere $IssFile ..." -ForegroundColor Magenta
& $iscc @isccArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[build] Kompilierung fehlgeschlagen (ExitCode $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}

$exe = Join-Path $OutDir "senity-setup.exe"
if (Test-Path $exe) {
    Write-Host "[build] Fertig: $exe" -ForegroundColor Green
} else {
    Write-Host "[build] Kompilierung lief durch, aber $exe fehlt - OutputDir in senity.iss pruefen." -ForegroundColor Yellow
}
