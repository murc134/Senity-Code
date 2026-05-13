# ══════════════════════════════════════════════════════════════
# claude-msh — Claude Code gegen Self-Hosted Modelle (Windows)
#
# Spricht das oeffentliche Gateway https://gateway.missionstarkeshandwerk.de
# (Caddy → cc-adapter:8765 fuer /v1/messages, sonst LiteLLM:4000).
# Auth ueber LITELLM_MASTER_KEY (User-Env-Var oder %USERPROFILE%\.config\claude-msh\auth).
#
# Wird ueblicherweise via claude-msh.bat aufgerufen.
#
# Beispiele:
#   claude-msh                            Default-Modell qwen3.6
#   claude-msh -Model gpt-4o "..."        Anderes Modell
#   claude-msh -List                      Modellliste vom Gateway
#   claude-msh -Endpoint http://...       Anderen Endpoint
#
# Voraussetzung: claude CLI installiert (npm install -g @anthropic-ai/claude-code).
# ══════════════════════════════════════════════════════════════
param(
    [string]$Model = "qwen3.6",
    [string]$Endpoint = "https://gateway.missionstarkeshandwerk.de",
    [switch]$List,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"

$AuthFile = Join-Path $env:USERPROFILE ".config\claude-msh\auth"

$Token = $env:LITELLM_MASTER_KEY
if (-not $Token) { $Token = $env:ANTHROPIC_AUTH_TOKEN }
if (-not $Token -and (Test-Path $AuthFile)) {
    $Token = (Get-Content -Raw $AuthFile).Trim()
}

if (-not $Token) {
    Write-Host "FEHLER: Kein Auth-Token gefunden." -ForegroundColor Red
    Write-Host ""
    Write-Host "Setz die User-Env-Variable LITELLM_MASTER_KEY (PowerShell):"
    Write-Host "  [Environment]::SetEnvironmentVariable('LITELLM_MASTER_KEY','sk-msh-...','User')"
    Write-Host ""
    Write-Host "Oder schreib den Key nach:"
    Write-Host "  $AuthFile"
    Write-Host ""
    Write-Host "Den Key findest du auf opus in /home/msh/gateway-stack/.env (LITELLM_MASTER_KEY=...)."
    exit 1
}

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

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "FEHLER: claude CLI nicht gefunden." -ForegroundColor Red
    Write-Host "Installation: npm install -g @anthropic-ai/claude-code"
    exit 1
}

$env:ANTHROPIC_BASE_URL = $Endpoint
$env:ANTHROPIC_AUTH_TOKEN = $Token
$env:ANTHROPIC_API_KEY = $Token

if ($Rest) {
    & claude --model $Model @Rest
} else {
    & claude --model $Model
}
exit $LASTEXITCODE
