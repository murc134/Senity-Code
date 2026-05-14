# ══════════════════════════════════════════════════════════════
# setup.ps1 — Senity Workspace Setup
#
# 1. Docker Desktop pruefen
# 2. Image bauen
# 3. Bindings.md pruefen/erstellen
# 4. Modus waehlen (MSH / Lokal / Eigenes Anthropic)
# 5. Container starten
# ══════════════════════════════════════════════════════════════
param(
    [switch]$NoInteractive,
    [string]$Mode
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── 1. Docker Desktop pruefen ──
Write-Host ""
Write-Host "  [1/5] Docker Desktop pruefen..." -ForegroundColor Cyan

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "  FEHLER: Docker Desktop nicht gefunden." -ForegroundColor Red
    Write-Host "  Installation: https://docs.docker.com/desktop/install/windows-install/"
    Write-Host "  Oder installiere via winget: winget install Docker.DockerDesktop"
    Write-Host ""
    exit 1
}

$dockerVersion = docker --version
Write-Host "  Docker: $dockerVersion" -ForegroundColor Green

# ── 2. Image bauen ──
Write-Host ""
Write-Host "  [2/5] Docker Image bauen..." -ForegroundColor Cyan

docker build -t senity-claude:latest "$ScriptDir"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  FEHLER: Image-Build fehlgeschlagen." -ForegroundColor Red
    exit 1
}
Write-Host "  Image gebaut: senity-claude:latest" -ForegroundColor Green

# ── 3. Bindings.md pruefen ──
Write-Host ""
Write-Host "  [3/5] Mount-Pfade pruefen..." -ForegroundColor Cyan

$bindingsFile = Join-Path $ScriptDir "Bindings.md"
$hasMounts = $false

if (Test-Path $bindingsFile) {
    $activeLines = Get-Content $bindingsFile | Where-Object {
        $line = $_.Trim()
        $line -ne '' -and $line -notmatch '^#'
    }
    if ($activeLines) {
        $hasMounts = $true
        Write-Host "  Bindings.md gefunden mit $($activeLines.Count) Pfad(en)" -ForegroundColor Green
    }
}

if (-not $hasMounts) {
    Write-Host ""
    Write-Host "  Hinweis: Bindings.md existiert nicht oder hat keine Mount-Pfade." -ForegroundColor Yellow
    Write-Host "  Du kannst spaeter Bindings.md bearbeiten und额外的 Ordner einbinden."
    Write-Host "  Default: ./workspace wird eingebunden."
    Write-Host ""
}

# ── 4. Modus waehlen ──
Write-Host ""
Write-Host "  [4/5] Modell-Quelle waehlen..." -ForegroundColor Cyan
Write-Host ""
Write-Host "  1) MSH Gateway (qwen3.6 vom Missionstarkeshandwerk)" -ForegroundColor White
Write-Host "  2) Eigenes Anthropic (Pro/Team API-Key)" -ForegroundColor White
Write-Host "  3) Ollama lokal (requires Ollama installiert)" -ForegroundColor White
Write-Host ""

if (-not $Mode) {
    if ($NoInteractive) {
        $Mode = "msh"
        Write-Host "  Non-interactive mode — defaulting to MSH Gateway" -ForegroundColor Yellow
    } else {
        $choice = Read-Host "  Modus waehlen (1/2/3) [1]"
        switch ($choice) {
            "1" { $Mode = "msh" }
            "2" { $Mode = "anthropic" }
            "3" { $Mode = "ollama" }
            default { $Mode = "msh"; Write-Host "  Default: MSH Gateway" -ForegroundColor Yellow }
        }
    }
}

# ── Env-Vars fuer den Modus setzen ──
$envVars = @{}

# .env aus Script-Verzeichnis lesen
$envFile = Join-Path $ScriptDir ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line -match '^#') { return }
        if ($line -match '^[^=]+=') {
            $idx = $line.IndexOf('=')
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Split('#')[0].Trim()
            $envVars[$key] = $val
        }
    }
}

switch ($Mode) {
    "msh" {
        $token = $envVars['MSH_API_KEY']
        $baseUrl = $envVars['MSH_API_URL']
        $model = $envVars['MSH_VLLM_MODEL']
        if (-not $token) { $token = $envVars['MSH_VLLM_API_KEY'] }
        if (-not $baseUrl) { $baseUrl = "https://gateway.missionstarkeshandwerk.de" }
        if (-not $model) { $model = "qwen3.6" }

        Write-Host "  Modell-Quelle: MSH Gateway ($baseUrl)" -ForegroundColor Green
        Write-Host "  Modell: $model" -ForegroundColor Green
    }
    "anthropic" {
        $token = $env['ANTHROPIC_API_KEY']
        if (-not $token) {
            $token = Read-Host "  Anthropic API-Key eingeben (sk-ant-...)"
            Write-Host "  Hinweis: Setz ANTHROPIC_API_KEY als User-Env-Var für permanente Konfiguration." -ForegroundColor Yellow
        }
        $baseUrl = ""  # Default Anthropic
        $model = "claude-sonnet-4-6"

        Write-Host "  Modell-Quelle: Eigenes Anthropic" -ForegroundColor Green
        Write-Host "  Modell: $model" -ForegroundColor Green
    }
    "ollama" {
        $token = "ollama"
        $baseUrl = "http://host.docker.internal:11434"
        $model = ""  # Wird im Container abgefragt

        # Ollama erreichbar?
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -TimeoutSec 3 -ErrorAction Stop
            Write-Host "  Modell-Quelle: Ollama lokal (host.docker.internal:11434)" -ForegroundColor Green
        } catch {
            Write-Host ""
            Write-Host "  WARNUNG: Ollama nicht unter localhost:11434 erreichbar." -ForegroundColor Yellow
            Write-Host "  Stelle sicher, dass Ollama laeuft: ollama serve"
            Write-Host "  Modell-Namen manuell eingeben oder MSH-Modus waehlen."
            $model = Read-Host "  Modell-Name (z.B. qwen3.6, llama3.1)"
            if (-not $model) { $model = "qwen3.6" }
        }
    }
}

# ── 5. Container starten ──
Write-Host ""
Write-Host "  [5/5] Container starten..." -ForegroundColor Cyan
Write-Host ""

$containerName = "senity-workspace-$($env:USERNAME)-$$"
$workspacePath = Join-Path $ScriptDir "workspace"

# Workspace-Verzeichnis erstellen falls nicht vorhanden
if (-not (Test-Path $workspacePath)) {
    New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
    Write-Host "  Workspace-Verzeichnis erstellt: $workspacePath" -ForegroundColor Yellow
}

$dockerArgs = @(
    "-it", "--rm",
    "--name", $containerName,
    "-v", "${workspacePath}:/workspace",
    "-w", "/workspace"
)

# Bindings aus Bindings.md
if ($hasMounts) {
    $activeLines = Get-Content $bindingsFile | Where-Object {
        $line = $_.Trim()
        $line -ne '' -and $line -notmatch '^#'
    }
    foreach ($binding in $activeLines) {
        if ($binding -match '^([^\s=]+)=([^\s]+)$') {
            $hostBinding = $Matches[1]
            $containerBinding = $Matches[2]
            $fullHost = Resolve-Path (Join-Path $ScriptDir $hostBinding) -ErrorAction SilentlyContinue
            if ($fullHost) {
                $dockerArgs += "-v"
                $dockerArgs += "$($fullHost.Path):$containerBinding"
            }
        }
    }
}

# SSH-Key mounten
$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (Test-Path $sshDir) {
    $dockerArgs += "-v"
    $dockerArgs += "${sshDir}:/home/node/.ssh:ro"
}

# Git-Config mounten
$gitconfig = Join-Path $env:USERPROFILE ".gitconfig"
if (Test-Path $gitconfig) {
    $dockerArgs += "-v"
    $dockerArgs += "${gitconfig}:/home/node/.gitconfig:ro"
}

# Environment-Vars
$dockerArgs += "-e"  "ANTHROPIC_BASE_URL=$baseUrl"
$dockerArgs += "-e"  "ANTHROPIC_API_KEY=$token"
$dockerArgs += "-e"  "HOME=/workspace"
$dockerArgs += "-e"  "TERM=xterm-256color"

if ($Mode -eq "ollama") {
    $dockerArgs += "--add-host"
    $dockerArgs += "host.docker.internal:host-gateway"
}

if ($model) {
    $dockerArgs += "--model"
    $dockerArgs += $model
}

Write-Host "  Starte Container: $containerName" -ForegroundColor Green
Write-Host ""

docker run @dockerArgs senity-claude:latest
