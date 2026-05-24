#!/usr/bin/env pwsh
# senity-start.ps1 - Host-Wrapper fuer Customer-Deployment (Windows / pwsh).
#
# Verkettung:
#   1. Pre-Check senity-CLI vorhanden.
#   2. senity gitea-token --ensure-fresh --write-docker-config
#      (Auto-Recovery via senity gitea-login bei Exit 2 / 3).
#   3. docker compose pull + up -d.
#   4. Interaktive Session via docker compose exec.
#
# Exit-Code-Verarbeitung (siehe reference_gitea_device_flow_params):
#   0 = ok                          -> weiter
#   2 = auth.json fehlt             -> einmalig 'senity gitea-login', retry
#   3 = refresh_token invalid_grant -> einmalig 'senity gitea-login', retry
#   4 = expired_token               -> abbrechen
#   5 = access_denied               -> abbrechen
#   6 = Netzwerk / Lib fehlt        -> abbrechen

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $PSCommandPath
$ComposeDir  = if ($env:SENITY_COMPOSE_DIR) { $env:SENITY_COMPOSE_DIR } else { Split-Path -Parent $ScriptDir }
$ComposeFile = Join-Path $ComposeDir "docker-compose.yml"
$Service     = if ($env:SENITY_COMPOSE_SERVICE) { $env:SENITY_COMPOSE_SERVICE } else { "senity-code" }
$ContainerCmd = if ($env:SENITY_CONTAINER_CMD) { $env:SENITY_CONTAINER_CMD } else { "senity-mascot-filter" }

function Write-StartLog ([string]$M) { Write-Host "[senity-start] $M" -ForegroundColor Magenta }
function Write-StartWarn([string]$M) { Write-Host "[senity-start] $M" -ForegroundColor Yellow }
function Write-StartErr ([string]$M) { Write-Host "[senity-start] $M" -ForegroundColor Red }

# ---- Vorbedingungen ---------------------------------------------------------
if (-not (Get-Command senity -ErrorAction SilentlyContinue) -and
    -not (Get-Command senity.ps1 -ErrorAction SilentlyContinue) -and
    -not (Get-Command senity.bat -ErrorAction SilentlyContinue)) {
    Write-StartErr "senity-CLI nicht gefunden. Installation: install.ps1 aus senity-cli/."
    exit 1
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-StartErr "docker nicht gefunden. Bitte Docker Desktop installieren."
    exit 1
}

try { docker info | Out-Null }
catch {
    Write-StartErr "Docker-Daemon laeuft nicht."
    exit 1
}

if (-not (Test-Path $ComposeFile)) {
    Write-StartErr "docker-compose.yml nicht gefunden unter $ComposeFile"
    Write-StartErr "Setze `$env:SENITY_COMPOSE_DIR falls dein Layout abweicht."
    exit 1
}

# ---- Schritt 1: Frischer Access-Token + Docker-Login-Patch ------------------
function Invoke-EnsureToken {
    param([int]$Attempt = 1)

    & senity gitea-token --ensure-fresh --write-docker-config
    $rc = $LASTEXITCODE

    switch ($rc) {
        0 { return 0 }

        { $_ -in 2, 3 } {
            if ($Attempt -ge 2) {
                Write-StartErr "Auth-Recovery fehlgeschlagen (Exit $rc nach Re-Login)."
                exit $rc
            }
            Write-StartLog "Kein gueltiger Token (Exit $rc). Starte Device-Login..."
            & senity gitea-login
            $lc = $LASTEXITCODE
            if ($lc -ne 0) {
                Write-StartErr "senity gitea-login fehlgeschlagen (Exit $lc)."
                exit $lc
            }
            return (Invoke-EnsureToken -Attempt 2)
        }

        4 {
            Write-StartErr "Device-Code abgelaufen, bitte Aufruf wiederholen."
            exit 4
        }
        5 {
            Write-StartErr "Login wurde abgelehnt."
            exit 5
        }
        6 {
            Write-StartErr "Netzwerkfehler beim Token-Refresh."
            exit 6
        }
        default {
            Write-StartErr "Unerwarteter Exit-Code $rc von 'senity gitea-token'."
            exit $rc
        }
    }
}

Write-StartLog "Pruefe Gitea-Auth + erneuere Token bei Bedarf"
Invoke-EnsureToken -Attempt 1 | Out-Null

# ---- Schritt 2: Image pullen, Container hochfahren --------------------------
Push-Location $ComposeDir
try {
    Write-StartLog "Pulle aktuelles Image"
    & docker compose pull $Service
    if ($LASTEXITCODE -ne 0) {
        Write-StartErr "docker compose pull fehlgeschlagen (Exit $LASTEXITCODE)."
        exit $LASTEXITCODE
    }

    Write-StartLog "Stelle sicher dass Container laeuft"
    & docker compose up -d $Service
    if ($LASTEXITCODE -ne 0) {
        Write-StartErr "docker compose up fehlgeschlagen (Exit $LASTEXITCODE)."
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

# ---- Schritt 3: Interaktive Session -----------------------------------------
Write-StartLog "Oeffne Session in $Service"
$execArgs = @("compose", "-f", $ComposeFile, "exec", "-it", $Service, $ContainerCmd, "claude")
if ($Args -and $Args.Count -gt 0) { $execArgs += $Args }
& docker @execArgs
exit $LASTEXITCODE
