# ══════════════════════════════════════════════════════════════
# codex-gemini-login.ps1 — Codex / Gemini CLI einrichten + anmelden
# Senity Workspace
#
# Eigenstaendiges Script — bewusst NICHT Teil von claude-senity.ps1.
# 1. Stellt das Docker-Image sicher (Build installiert codex + gemini).
# 2. Startet codex bzw. gemini interaktiv im Workspace-Container.
# 3. Du meldest dich per OAuth an. Tokens landen in workspace/.codex
#    bzw. workspace/.gemini und bleiben erhalten.
# ══════════════════════════════════════════════════════════════
$ErrorActionPreference = "Continue"

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = $PWD.Path }

$Image     = "senity-claude:latest"
$Workspace = Join-Path $ScriptDir "workspace"

function Write-OK   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-INFO { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor Magenta }
function Write-FAIL { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Magenta
Write-Host "   Codex / Gemini - CLI-Login (Senity)" -ForegroundColor Magenta
Write-Host "  ============================================" -ForegroundColor Magenta
Write-Host ""

# ── Docker ──
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-FAIL "Docker nicht gefunden. Docker Desktop installieren und erneut starten."
    exit 1
}
docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-FAIL "Docker-Daemon laeuft nicht. Docker Desktop starten und erneut versuchen."
    exit 1
}
Write-OK "Docker bereit"

# ── Image sicherstellen (Build installiert codex + gemini) ──
docker image inspect $Image 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-INFO "Image '$Image' fehlt — wird gebaut (installiert u.a. codex + gemini)..."
    docker build -t $Image $ScriptDir
    if ($LASTEXITCODE -ne 0) { Write-FAIL "Image-Build fehlgeschlagen."; exit 1 }
}
Write-OK "Image bereit: $Image  (codex + gemini sind enthalten)"

if (-not (Test-Path $Workspace)) { New-Item -ItemType Directory -Path $Workspace -Force | Out-Null }
$wsDocker = ($Workspace -replace '\\', '/')

function Invoke-Login {
    param([string]$Label, [string[]]$Cmd)
    Write-Host ""
    Write-INFO "Starte $Label-Login im Container — folge dem Browser-/Device-Flow."
    docker run -it --rm -v "${wsDocker}:/workspace" -e "HOME=/workspace" -e "TERM=xterm-256color" -w /workspace $Image @Cmd
}

Write-Host ""
Write-Host "  Was einrichten?"
Write-Host "    [1] Codex (ChatGPT-Account)"
Write-Host "    [2] Gemini (Google-Account)"
Write-Host "    [3] Beide   (Default)"
Write-Host "    [q] Abbrechen"
$sel = Read-Host "  Auswahl [3]"
if (-not $sel) { $sel = "3" }

switch ($sel) {
    "1" { Invoke-Login "Codex"  @("codex","login") }
    "2" { Invoke-Login "Gemini" @("gemini") }
    "3" { Invoke-Login "Codex" @("codex","login"); Invoke-Login "Gemini" @("gemini") }
    { $_ -in "q","Q" } { Write-INFO "Abgebrochen."; exit 0 }
    default { Write-FAIL "Ungueltige Auswahl: $sel"; exit 1 }
}

Write-Host ""
Write-OK "Login-Vorgang beendet."
Write-INFO "Codex: Token in workspace/.codex/   Gemini: Token in workspace/.gemini/"
Write-INFO "Beim naechsten claude-senity-Start stehen codex/gemini im Container bereit."
Write-Host ""
Write-Host "  Hinweis: Bei Gemini im Menue 'Login with Google' waehlen; nach dem"
Write-Host "           Anmelden mit /quit beenden. 'codex login' beendet sich selbst."
Write-Host ""
