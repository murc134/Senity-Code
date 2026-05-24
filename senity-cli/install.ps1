#!/usr/bin/env pwsh
# Senity CLI Installer (Windows / pwsh).
# Installiert das `senity`-Wrapper-Script nach $env:USERPROFILE\.senity\bin
# und fuegt diesen Pfad zum User-PATH hinzu.
#
# Quick-Install (pwsh):
#   irm https://git.senity.ai/senity-admin/senity-code/raw/branch/main/senity-cli/install.ps1 | iex
#
# Lokal aus dem Repo:
#   .\senity-cli\install.ps1

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE ".senity\bin"),
    [switch]$NoPathUpdate
)

$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$RawUrl      = "https://git.senity.ai/senity-admin/senity-code/raw/branch/main/senity-cli/senity.ps1"
$LibRawUrl   = "https://git.senity.ai/senity-admin/senity-code/raw/branch/main/senity-cli/lib/gitea-device-flow.ps1"
$Target      = Join-Path $InstallDir "senity.ps1"
$ShimBat     = Join-Path $InstallDir "senity.bat"
$LibDir      = Join-Path $env:LOCALAPPDATA "senity\lib"
$LibTarget   = Join-Path $LibDir "gitea-device-flow.ps1"

function Write-Log  ([string]$M) { Write-Host "[install] $M" -ForegroundColor Magenta }
function Write-Warn2([string]$M) { Write-Host "[install] $M" -ForegroundColor Yellow }
function Write-Err2 ([string]$M) { Write-Host "[install] $M" -ForegroundColor Red }

# Verzeichnis vorbereiten.
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
if (-not (Test-Path $LibDir)) {
    New-Item -ItemType Directory -Path $LibDir -Force | Out-Null
}

# Quelle bestimmen.
$Source = Join-Path $ScriptDir "senity.ps1"
if (Test-Path $Source) {
    Write-Log "Kopiere $Source -> $Target"
    Copy-Item -Path $Source -Destination $Target -Force
} else {
    Write-Log "Lade $RawUrl -> $Target"
    Invoke-WebRequest -Uri $RawUrl -OutFile $Target -UseBasicParsing
}

# Lib (gitea-device-flow.ps1) mit-installieren
$LibSource = Join-Path $ScriptDir "lib\gitea-device-flow.ps1"
if (Test-Path $LibSource) {
    Write-Log "Kopiere lib\gitea-device-flow.ps1 -> $LibTarget"
    Copy-Item -Path $LibSource -Destination $LibTarget -Force
} else {
    Write-Log "Lade $LibRawUrl -> $LibTarget"
    Invoke-WebRequest -Uri $LibRawUrl -OutFile $LibTarget -UseBasicParsing
}

# .bat-Shim, damit `senity` auch aus cmd.exe funktioniert.
$shim = @"
@echo off
where pwsh >nul 2>&1
if %ERRORLEVEL% neq 0 (
    powershell -NoLogo -ExecutionPolicy Bypass -File "%~dp0senity.ps1" %*
) else (
    pwsh -NoLogo -ExecutionPolicy Bypass -File "%~dp0senity.ps1" %*
)
"@
Set-Content -Path $ShimBat -Value $shim -Encoding ASCII

Write-Log "Installiert: $Target"
Write-Log "Shim:        $ShimBat"
Write-Log "Lib-Dir:     $LibDir"

# PATH-Update (User-Scope).
if (-not $NoPathUpdate) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }
    $parts = $userPath.Split([IO.Path]::PathSeparator) | Where-Object { $_ }
    if ($parts -notcontains $InstallDir) {
        $newPath = ($parts + $InstallDir) -join [IO.Path]::PathSeparator
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Log "User-PATH erweitert um $InstallDir"
        Write-Warn2 "Neue Shell oeffnen, damit der PATH wirksam wird."
    } else {
        Write-Log "$InstallDir ist bereits im User-PATH."
    }
} else {
    Write-Warn2 "PATH-Update uebersprungen (-NoPathUpdate)."
    Write-Warn2 "Fuege manuell hinzu: $InstallDir"
}

# Docker-Check.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Warn2 "Docker Desktop ist nicht installiert."
    Write-Warn2 "Installation: winget install Docker.DockerDesktop"
}

Write-Log "Fertig. Test mit: senity -h"
Write-Log "Erst-Login:   senity login"
