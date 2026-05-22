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

# ── Interaktives Terminal noetig (der Login laeuft interaktiv) ──
if ([System.Console]::IsInputRedirected) {
    Write-FAIL "Kein interaktives Terminal. Bitte direkt in Windows Terminal / pwsh starten."
    exit 1
}

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

# ── Image sicherstellen — es muss existieren UND codex + gemini enthalten ──
function Test-ImageHasClis {
    docker run --rm --entrypoint sh $Image -c 'command -v codex >/dev/null 2>&1 && command -v gemini >/dev/null 2>&1' 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}
$needBuild = $false
docker image inspect $Image 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-INFO "Image '$Image' fehlt."
    $needBuild = $true
} elseif (-not (Test-ImageHasClis)) {
    Write-INFO "Vorhandenes Image enthaelt codex/gemini noch nicht — Rebuild noetig."
    $needBuild = $true
}
if ($needBuild) {
    Write-INFO "Baue Image '$Image' (installiert u.a. codex + gemini)..."
    docker build -t $Image $ScriptDir
    if ($LASTEXITCODE -ne 0) { Write-FAIL "Image-Build fehlgeschlagen."; exit 1 }
}
Write-OK "Image bereit: $Image"

if (-not (Test-Path $Workspace)) { New-Item -ItemType Directory -Path $Workspace -Force | Out-Null }
$wsDocker = ($Workspace -replace '\\', '/')

$CodexCred  = ".codex/auth.json"
$GeminiCred = ".gemini/oauth_creds.json"

# Prueft, ob eine CLI im Image vorhanden ist (npm-Install ist soft-fail).
function Test-CliInImage {
    param([string]$Cli)
    docker run --rm --entrypoint sh $Image -c "command -v $Cli >/dev/null 2>&1" 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Startet den interaktiven Login + verifiziert per Token-Datei. $true = ok.
function Invoke-Login {
    param([string]$Label, [string]$Cli, [string]$Cred, [string[]]$Cmd)
    if (-not (Test-CliInImage $Cli)) {
        Write-FAIL "${Label}: '$Cli' ist nicht im Image — npm-Install beim Build fehlgeschlagen."
        Write-FAIL "       Image neu bauen: docker build -t $Image `"$ScriptDir`""
        return $false
    }
    Write-Host ""
    Write-INFO "Starte $Label-Login im Container — folge dem Browser-/Device-Flow."
    docker run -it --rm -v "${wsDocker}:/workspace" -e "HOME=/workspace" -e "TERM=xterm-256color" -w /workspace $Image @Cmd
    if (Test-Path (Join-Path $Workspace $Cred)) {
        Write-OK "${Label}: angemeldet."
        return $true
    }
    Write-FAIL "${Label}: kein Token gefunden — Login nicht abgeschlossen."
    return $false
}

Write-Host ""
Write-Host "  Was einrichten?"
Write-Host "    [1] Codex (ChatGPT-Account)"
Write-Host "    [2] Gemini (Google-Account)"
Write-Host "    [3] Beide   (Default)"
Write-Host "    [q] Abbrechen"
$sel = Read-Host "  Auswahl [3]"
if (-not $sel) { $sel = "3" }

$overall = 0
switch ($sel) {
    "1" { if (-not (Invoke-Login "Codex"  "codex"  $CodexCred  @("codex","login"))) { $overall = 1 } }
    "2" { if (-not (Invoke-Login "Gemini" "gemini" $GeminiCred @("gemini")))         { $overall = 1 } }
    "3" {
        if (-not (Invoke-Login "Codex"  "codex"  $CodexCred  @("codex","login"))) { $overall = 1 }
        if (-not (Invoke-Login "Gemini" "gemini" $GeminiCred @("gemini")))         { $overall = 1 }
    }
    { $_ -in "q","Q" } { Write-INFO "Abgebrochen."; exit 0 }
    default { Write-FAIL "Ungueltige Auswahl: $sel"; exit 1 }
}

Write-Host ""
if ($overall -eq 0) {
    Write-OK "Login abgeschlossen — beim naechsten claude-senity-Start stehen die CLIs"
    Write-OK "angemeldet im Container bereit (Token in workspace/.codex bzw. .gemini)."
} else {
    Write-FAIL "Mindestens ein Login wurde nicht abgeschlossen — Script erneut ausfuehren."
}
Write-Host ""
Write-Host "  Hinweis: Bei Gemini im Menue 'Login with Google' waehlen; nach dem"
Write-Host "           Anmelden mit /quit beenden. 'codex login' beendet sich selbst."
Write-Host "  Re-Login: workspace/.codex bzw. workspace/.gemini loeschen, Script erneut starten."
Write-Host ""
exit $overall
