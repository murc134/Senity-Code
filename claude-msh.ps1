# ══════════════════════════════════════════════════════════════
# claude-msh.ps1 — Senity Workspace (Container Start)
#
# Interaktiver Start: Provider -> Modell -> Yolo -> Container
# Alternative: Direkter Aufruf mit Flags
#
# Usage:
#   claude-msh                              # Interaktiv
#   claude-msh --msh                        # Direkt MSH-Modus
#   claude-msh --anthropic --yolo           # Direkt Anthropic + Yolo
#   claude-msh --ollama --model llama3.1    # Direkt Ollama
# ══════════════════════════════════════════════════════════════
param(
    [switch]$Yolo,
    [switch]$NoYolo,
    [string]$Mode,
    [string]$Model,
    [string]$Endpoint,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Help) {
    Write-Host "Usage: claude-msh [OPTIONS]" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Options:" -ForegroundColor White
    Write-Host "  --msh            MSH Gateway (qwen3.6, Default)" -ForegroundColor White
    Write-Host "  --anthropic      Eigenes Anthropic API" -ForegroundColor White
    Write-Host "  --ollama         Lokaler Ollama" -ForegroundColor White
    Write-Host "  --model NAME     Modell ueberschreiben" -ForegroundColor White
    Write-Host "  --yolo           Yolo Mode (ungefragte Execution)" -ForegroundColor White
    Write-Host "  --no-yolo        Yolo Mode deaktiviert" -ForegroundColor White
    Write-Host "  --endpoint URL   Ollama/Custom Endpoint" -ForegroundColor White
    Write-Host "  --help           Diese Hilfe" -ForegroundColor White
    Write-Host ""
    Write-Host "Ohne Flags: Interaktive Auswahl" -ForegroundColor White
    exit 0
}

# ── .env lesen ──
$envFile = Join-Path $ScriptDir ".env"
$envVars = @{}
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line -match '^#') { continue }
        if ($line -match '^[^=]+=') {
            $idx = $line.IndexOf('=')
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Trim()
            if ($val -match '^".*"') { $val = $val.Substring(1, $val.Length - 2) }
            elseif ($val -match "^'.*'") { $val = $val.Substring(1, $val.Length - 2) }
            $envVars[$key] = $val
        }
    }
}

# ── Modus ermitteln ──
if (-not $Mode) {
    $Mode = "msh"
}

# ── Werte pro Modus ──
$token = ""
$baseUrl = ""
$defaultModel = "qwen3.6"

switch ($Mode) {
    "msh" {
        $token = $envVars['MSH_API_KEY']
        if (-not $token) { $token = $envVars['MSH_VLLM_API_KEY'] }
        if (-not $token) { $token = $env:LITELLM_MASTER_KEY }
        if (-not $token) {
            Write-Host "FEHLER: Kein Auth-Token gefunden. Setz MSH_API_KEY, MSH_VLLM_API_KEY oder LITELLM_MASTER_KEY." -ForegroundColor Red
            exit 1
        }
        $baseUrl = $envVars['MSH_API_URL']
        if (-not $baseUrl) { $baseUrl = "https://gateway.missionstarkeshandwerk.de" }
        $defaultModel = $envVars['MSH_VLLM_MODEL']
        if (-not $defaultModel) { $defaultModel = "qwen3.6" }
    }
    "anthropic" {
        $token = $env:ANTHROPIC_API_KEY
        if (-not $token) { $token = $envVars['ANTHROPIC_API_KEY'] }
        if (-not $token) {
            Write-Host "FEHLER: ANTHROPIC_API_KEY nicht gesetzt." -ForegroundColor Red
            exit 1
        }
        $baseUrl = ""
        $defaultModel = "claude-sonnet-4-6"
    }
    "ollama" {
        $token = "ollama"
        $baseUrl = $Endpoint
        if (-not $baseUrl) { $baseUrl = "http://host.docker.internal:11434" }
    }
    default {
        Write-Host "FEHLER: Unbekannter Modus '$Mode'. Waehle: msh, anthropic, ollama" -ForegroundColor Red
        exit 1
    }
}

if (-not $Model) {
    $Model = $defaultModel
}

# ── Yolo — default: AUS (Sicherheit) ──
$yolo = $false
if ($Yolo) { $yolo = $true }
if (-not ($Yolo -or $NoYolo)) {
    $yolo = $false
}

# ── Container starten ──
$containerName = "senity-workspace-$($env:USERNAME)-$PID"
$workspacePath = Join-Path $ScriptDir "workspace"
$claudeDir = Join-Path $ScriptDir ".claude"

# Verzeichnisse erstellen
if (-not (Test-Path $workspacePath)) {
    New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
}
if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

$dockerArgs = @(
    "-it", "--rm",
    "--name", $containerName,
    "-v", "${workspacePath}:/workspace",
    "-v", "${claudeDir}:/workspace/.claude",
    "-w", "/workspace"
)

# Bindings aus Bindings.md
$bindingsFile = Join-Path $ScriptDir "Bindings.md"
if (Test-Path $bindingsFile) {
    Get-Content $bindingsFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line -match '^#') { continue }
        if ($line -match '^([^\s=]+)=([^\s]+)$') {
            $resolved = Join-Path $ScriptDir $Matches[1]
            if (Test-Path $resolved) {
                $dockerArgs += "-v"
                $dockerArgs += "${resolved}:${Matches[2]}"
            }
        }
    }
}

# SSH + Git
$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (Test-Path $sshDir) {
    $dockerArgs += "-v"
    $dockerArgs += "${sshDir}:/home/node/.ssh:ro"
}

$gitconfig = Join-Path $env:USERPROFILE ".gitconfig"
if (Test-Path $gitconfig) {
    $dockerArgs += "-v"
    $dockerArgs += "${gitconfig}:/home/node/.gitconfig:ro"
}

# Environment
$dockerArgs += "-e"
$dockerArgs += "ANTHROPIC_BASE_URL=$baseUrl"
$dockerArgs += "-e"
$dockerArgs += "ANTHROPIC_API_KEY=$token"
$dockerArgs += "-e"
$dockerArgs += "HOME=/workspace"
$dockerArgs += "-e"
$dockerArgs += "TERM=xterm-256color"

if ($Mode -eq "ollama") {
    $dockerArgs += "--add-host"
    $dockerArgs += "host.docker.internal:host-gateway"
}

# Claude-Argumente NACH dem Image-Namen (nicht als Docker-Flags)
$claudeArgs = @("--model", $Model)
if ($yolo) {
    $claudeArgs += "--dangerously-skip-permissions"
}

docker run @dockerArgs senity-claude:latest @claudeArgs @Rest
