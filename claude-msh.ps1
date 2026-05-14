# ══════════════════════════════════════════════════════════════
# claude-msh — Senity Workspace (Docker Container)
#
# Startet Claude Code in einem Docker Container.
# Modus: MSH Gateway / Eigenes Anthropic / Ollama lokal.
# ══════════════════════════════════════════════════════════════
param(
    [string]$Model,
    [switch]$List,
    [string]$Endpoint,
    [string]$Mode,
    [switch]$Setup,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Setup-Modus ──
if ($Setup) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "setup.ps1") @Rest
    exit $LASTEXITCODE
}

# ── .env lesen ──
$envFile = Join-Path $ScriptDir ".env"
$envVars = @{}
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

# ── Modus ermitteln ──
if (-not $Mode) {
    # Standard: MSH Gateway
    $Mode = "msh"
}

# ── Werte pro Modus ──
$token = ""
$baseUrl = ""

switch ($Mode) {
    "msh" {
        $token = $envVars['MSH_API_KEY']
        if (-not $token) { $token = $envVars['MSH_VLLM_API_KEY'] }
        if (-not $token) { $token = $env:LITELLM_MASTER_KEY }
        if (-not $token) {
            Write-Host "FEHLER: Kein Auth-Token gefunden. Setz MSH_API_KEY in .env oder LITELLM_MASTER_KEY." -ForegroundColor Red
            exit 1
        }
        $baseUrl = $envVars['MSH_API_URL']
        if (-not $baseUrl) { $baseUrl = "https://gateway.missionstarkeshandwerk.de" }
    }
    "anthropic" {
        $token = $env:ANTHROPIC_API_KEY
        if (-not $token) {
            Write-Host "FEHLER: ANTHROPIC_API_KEY nicht gesetzt." -ForegroundColor Red
            exit 1
        }
        $baseUrl = ""
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
    $Model = $envVars['MSH_VLLM_MODEL']
    if (-not $Model) { $Model = "qwen3.6" }
}

# ── Wrapper zu setup.ps1 delegieren ──
$setupArgs = @(
    "-NoInteractive",
    "-Mode", $Mode
)

if ($Model) {
    $setupArgs += "-Model"; $setupArgs += $Model
}

if ($Rest) {
    $setupArgs += $Rest
}

$setupScript = Join-Path $ScriptDir "setup.ps1"
if (Test-Path $setupScript) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $setupScript @setupArgs
    exit $LASTEXITCODE
} else {
    Write-Host "setup.ps1 nicht gefunden. Fuehre zuerst .\setup.bat aus." -ForegroundColor Red
    exit 1
}
