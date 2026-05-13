# ══════════════════════════════════════════════════════════════
# claude-msh — Claude Code gegen Self-Hosted Modelle (Windows)
#
# Liest .env aus dem eigenen Verzeichnis und leitet auf MSH vLLM
# oder Gateway um. Primar: direkter vLLM-Endpoint (thinking support).
#
# Usage:
#   claude-msh                        Default-Modell qwen3.6
#   claude-msh "frag mich was"        Argumente an claude weiterleiten
#   claude-msh -m gpt-4o "..."        Modell waehlen
#
# Voraussetzung: claude CLI installiert + .env im Script-Verzeichnis.
# ══════════════════════════════════════════════════════════════
param(
    [string]$Model,
    [switch]$List,
    [string]$Endpoint,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"

# ── Script-Verzeichnis ermitteln ──
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $ScriptDir ".env"

# ── .env parsen ──
function Parse-EnvFile {
    param([string]$Path)
    $vars = @{}
    if (-not (Test-Path $Path)) { return $vars }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line -match '^#') { return }
        if ($line -match '^[^=]+=') {
            $idx = $line.IndexOf('=')
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Split('#')[0].Trim()
            $vars[$key] = $val
        }
    }
    return $vars
}

$envVars = Parse-EnvFile $EnvFile

# ── Werte aus .env ──
$Token = $envVars['MSH_VLLM_API_KEY']
if (-not $Token -or $Token -eq '') {
    # Fallback: LITELLM_MASTER_KEY aus Environment
    $Token = $env:LITELLM_MASTER_KEY
}
if (-not $Token) {
    Write-Host "FEHLER: Kein Auth-Token gefunden." -ForegroundColor Red
    Write-Host ""
    Write-Host "Pruefe .env im Script-Verzeichnis: $EnvFile"
    Write-Host ""
    Write-Host "Oder setz die Env-Variable: LITELLM_MASTER_KEY"
    exit 1
}

$vllmUrl = $envVars['MSH_VLLM_URL']
$gwUrl = $envVars['MSH_API_URL']
$modelDefault = $envVars['MSH_VLLM_MODEL']

if (-not $Model) { $Model = if ($vllmUrl) { $modelDefault } else { "qwen3.6" } }
if (-not $Endpoint) {
    # Primar vLLM, Fallback Gateway
    if ($vllmUrl) { $Endpoint = $vllmUrl }
    elseif ($gwUrl) { $Endpoint = $gwUrl }
    else { $Endpoint = "https://gateway.missionstarkeshandwerk.de" }
}

# ── Modellliste abrufen ──
if ($List) {
    try {
        $resp = Invoke-RestMethod -Uri "$Endpoint/v1/models" -Headers @{ Authorization = "Bearer $Token" }
        $resp.data | ForEach-Object { $_.id }
    } catch {
        Write-Host "FEHLER beim Abruf der Modellliste: $_" -ForegroundColor Red
        exit 1
    }
    exit 0
}

# ── Claude starten ──
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "FEHLER: claude CLI nicht gefunden." -ForegroundColor Red
    Write-Host "Installation: npm install -g @anthropic-ai/claude-code"
    exit 1
}

# vLLM nutzt OpenAI-kompatibles Format — daher BASE_URL auf vLLM /v1
if ($Endpoint -eq $vllmUrl) {
    # Direkter vLLM: OpenAI-kompatibel
    $env:OPENAI_BASE_URL = $Endpoint
    $env:OPENAI_API_KEY = $Token
    $env:ANTHROPIC_BASE_URL = ""
    $env:ANTHROPIC_AUTH_TOKEN = ""
    $env:ANTHROPIC_API_KEY = ""
} else {
    # Gateway (LiteLLM / Anthropic-Format)
    $env:ANTHROPIC_BASE_URL = $Endpoint
    $env:ANTHROPIC_API_KEY = $Token
    $env:ANTHROPIC_AUTH_TOKEN = ""
    $env:OPENAI_BASE_URL = ""
    $env:OPENAI_API_KEY = ""
}

$extraArgs = @()
if ($Model) { $extraArgs += "--model"; $extraArgs += $Model }

# Arg-Escape fix: Rest-Items als separate Args uebergeben
if ($Rest) {
    $extraArgs += $Rest
}

& claude @extraArgs
$exitCode = $LASTEXITCODE
exit $exitCode
