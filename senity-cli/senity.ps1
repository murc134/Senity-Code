#!/usr/bin/env pwsh
# senity - globaler CLI-Wrapper fuer den Senity-Workspace-Container (Windows / pwsh).
# Startet einen Ad-hoc-Container mit dem aktuellen cwd als /workspace/cwd.
#
# Defaults:
#   - Image:        ghcr.io/murc134/senity-code:latest
#                   Fallback (kein Pull moeglich): senity-claude:latest
#   - Auto-Update:  bei jedem Start. -SkipUpdate ueberspringt.
#   - Yolo:         an. -NoYolo deaktiviert.
#
# Usage:
#   senity                      Container starten, Senity Code an
#   senity select               Agent-Auswahl anzeigen
#   senity codex                Codex CLI starten
#   senity claude               Claude Code upstream starten
#   senity antigravity          Antigravity CLI starten
#   senity -SkipUpdate          Ohne docker pull / git pull
#   senity -NoYolo              Permission-Prompts an
#   senity -Mount H:C[:ro]      Zusatz-Mount (mehrfach)
#   senity -Image <ref>         Image-Tag ueberschreiben
#   senity login                Senity-Proxy-Key einrichten
#   senity comfyui              ComfyUI Server starten
#   senity -h                   Hilfe

[CmdletBinding(PositionalBinding=$false)]
param(
    [switch]$SkipUpdate,
    [switch]$NoYolo,
    [switch]$Yolo,
    [string[]]$Mount = @(),
    [string]$Image = "",
    [Alias("comfyui-port")][int]$ComfyUIPort = 8188,
    [Alias("comfyui-gpu")][switch]$ComfyUIGpu,
    [switch]$Headless,
    [switch]$EnsureFresh,
    [switch]$WriteDockerConfig,
    [switch]$Print,
    [Alias("h", "?")][switch]$HelpRequest,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)

$ErrorActionPreference = "Stop"

# ---- Konstanten -------------------------------------------------------------
$SenityHome      = if ($env:SENITY_HOME) { $env:SENITY_HOME } else { Join-Path $env:USERPROFILE ".senity" }
$SenityEnvFile   = Join-Path $SenityHome ".env"
$SenityMcpConfig = Join-Path $SenityHome "mcp-config.json"
$SenityCacheDir  = Join-Path $SenityHome "cache"
$SenityWsDir     = Join-Path $SenityHome "workspace"

$DefaultImage    = "ghcr.io/murc134/senity-code:latest"
$FallbackImage   = "senity-claude:latest"
$DefaultProxyUrl = "https://sdr.senity.ai/api/claude-proxy"

$SkillsRepo      = "git@github.com:murc134/Claude-Skills.git"
$CommandsRepo    = "git@github.com:murc134/Claude-Commands.git"
$AgentsRepo      = "git@github.com:murc134/Claude-Agents.git"
$McpsRepo        = "ssh://git@git.senity.ai:2200/senity/senity-mcps.git"

# ---- Lib-Loader (gitea-device-flow) -----------------------------------------
$ScriptDir = Split-Path -Parent $PSCommandPath
$LibCandidates = @(
    (Join-Path $ScriptDir "lib"),
    (Join-Path (Split-Path -Parent $ScriptDir) "share\senity\lib"),
    (Join-Path $env:LOCALAPPDATA "senity\lib"),
    (Join-Path $env:USERPROFILE ".local\share\senity\lib"),
    "C:\ProgramData\senity\lib"
)
$SenityGiteaAvailable = $false
foreach ($cand in $LibCandidates) {
    $libFile = Join-Path $cand "gitea-device-flow.ps1"
    if (Test-Path $libFile) {
        . $libFile
        $SenityGiteaAvailable = $true
        break
    }
}

# ---- Logging ----------------------------------------------------------------
function Write-Log  ([string]$Msg) { Write-Host "[senity] $Msg" -ForegroundColor Magenta }
function Write-Warn2([string]$Msg) { Write-Host "[senity] $Msg" -ForegroundColor Yellow }
function Write-Err2 ([string]$Msg) { Write-Host "[senity] $Msg" -ForegroundColor Red }

function Normalize-AgentMode([string]$Mode) {
    $m = if ($Mode) { $Mode.ToLowerInvariant() } else { "senity" }
    switch ($m) {
        "senity"      { return "senity" }
        "claude"      { return "claude" }
        "codex"       { return "codex" }
        "antigravity" { return "antigravity" }
        "agy"         { return "antigravity" }
        default       { Write-Err2 "Unbekannter Agent-Modus: $Mode"; exit 1 }
    }
}

function Get-AgentLabel([string]$Mode) {
    switch ($Mode) {
        "senity"      { return "Senity Code (Claude Code + Senity Proxy)" }
        "claude"      { return "Claude Code (Anthropic Auth/API)" }
        "codex"       { return "Codex CLI" }
        "antigravity" { return "Antigravity CLI" }
        default       { return $Mode }
    }
}

function Select-AgentMode {
    Write-Host ""
    Write-Host "Agent auswaehlen:" -ForegroundColor White
    Write-Host "  1) Senity       Claude Code ueber Senity Proxy (Default: qwen3.6:35b)" -ForegroundColor White
    Write-Host "  2) Claude       Claude Code upstream mit Anthropic Login/API-Key" -ForegroundColor White
    Write-Host "  3) Codex        OpenAI Codex CLI" -ForegroundColor White
    Write-Host "  4) Antigravity  Google Antigravity CLI (agy)" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "Auswahl [1]"
    switch (($choice.Trim()).ToLowerInvariant()) {
        ""             { return "senity" }
        "1"            { return "senity" }
        "senity"       { return "senity" }
        "2"            { return "claude" }
        "claude"       { return "claude" }
        "3"            { return "codex" }
        "codex"        { return "codex" }
        "4"            { return "antigravity" }
        "antigravity"  { return "antigravity" }
        "agy"          { return "antigravity" }
        default        { Write-Err2 "Ungueltige Auswahl: $choice"; exit 1 }
    }
}

# ---- Help -------------------------------------------------------------------
function Show-Help {
    @"
senity - Senity-Workspace-Container auf Knopfdruck

USAGE
  senity [agent] [options] [-- tool-args...]
  senity login
  senity comfyui [-- comfyui-args...]
  senity -h

AGENTS
  senity               Claude Code ueber Senity Proxy (Default: qwen3.6:35b)
  claude               Claude Code upstream mit Anthropic Login/API-Key
  codex                OpenAI Codex CLI
  antigravity          Google Antigravity CLI (agy)
  select               Interaktive Auswahl

OPTIONS
  -SkipUpdate           Ueberspringt docker pull + git pull beim Start
  -NoYolo               Permission-Prompts aktivieren (Default: Yolo an)
  -Yolo                 Yolo explizit an (Default)
  -Mount H:C[:ro]       Zusatz-Mount, mehrfach erlaubt
  -Image <ref>          Image-Tag ueberschreiben
  -ComfyUIPort <port>   Host-Port fuer ComfyUI (Default: 8188)
  -ComfyUIGpu           Docker mit --gpus all starten
  -h                    Diese Hilfe

SUBCOMMANDS
  login                 Senity-Proxy-Key in ~/.senity/.env hinterlegen
  comfyui               ComfyUI statt Agent starten
  gitea-login           OAuth2 Device-Flow gegen git.senity.ai (Browser-Login)
                        Flags: -Headless (Env SENITY_GITEA_RT)
  gitea-token           Frischen Access-Token sicherstellen / ausgeben
                        Flags: -EnsureFresh (Default), -WriteDockerConfig, -Print
  gitea-status          Status der gespeicherten Auth (User, Scopes, Expires)
  gitea-logout          Token revoken und ~/.senity/auth.json loeschen

EXIT-CODES (gitea-*)
  0  ok           2  auth.json fehlt    3  refresh invalid_grant
  4  expired      5  access_denied      6  Netzwerk / Sonstiges
"@ | Write-Host
}

if ($HelpRequest) { Show-Help; exit 0 }
if ($ComfyUIPort -lt 1 -or $ComfyUIPort -gt 65535) {
    Write-Err2 "-ComfyUIPort muss zwischen 1 und 65535 liegen."
    exit 1
}

# ---- Subcommand extrahieren -------------------------------------------------
$KnownSubs = @("login", "gitea-login", "gitea-token", "gitea-status", "gitea-logout")
$Subcommand = ""
$AgentMode = "senity"
$ClaudeArgs = @()
$afterSeparator = $false
foreach ($arg in $Rest) {
    if (-not $afterSeparator -and $arg -eq "--") { $afterSeparator = $true; continue }
    if (-not $afterSeparator -and $Subcommand -eq "" -and ($arg -eq "comfyui" -or $KnownSubs -contains $arg)) { $Subcommand = $arg; continue }
    if (-not $afterSeparator -and $Subcommand -eq "" -and $AgentMode -eq "senity" -and @("senity","claude","codex","antigravity","agy","select") -contains $arg) {
        switch ($arg) {
            "senity"      { $AgentMode = "senity" }
            "claude"      { $AgentMode = "claude" }
            "codex"       { $AgentMode = "codex" }
            "antigravity" { $AgentMode = "antigravity" }
            "agy"         { $AgentMode = "antigravity" }
            "select"      { $AgentMode = Select-AgentMode }
        }
        continue
    }
    $ClaudeArgs += $arg
}

$AgentMode = Normalize-AgentMode $AgentMode
$AgentLabel = Get-AgentLabel $AgentMode

if (-not $Image) { $Image = $DefaultImage }

# ---- Prerequisites ----------------------------------------------------------
function Test-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Err2 "Docker ist nicht installiert. Siehe https://docs.docker.com/desktop/install/windows-install/"
        exit 1
    }
    try { docker info *>$null } catch {
        Write-Err2 "Docker-Daemon laeuft nicht. Bitte Docker Desktop starten."
        exit 1
    }
}

function Initialize-Dirs {
    foreach ($d in @($SenityHome, $SenityCacheDir, $SenityWsDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

# ---- Env Laden / Schreiben --------------------------------------------------
function Read-EnvFile {
    $data = @{}
    if (Test-Path $SenityEnvFile) {
        foreach ($line in Get-Content $SenityEnvFile) {
            if ($line -match '^\s*#') { continue }
            if ($line -match '^\s*([A-Z_]+)=(.*)$') { $data[$Matches[1]] = $Matches[2] }
        }
    }
    return $data
}

function Save-EnvFile([hashtable]$Data) {
    $content = ($Data.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
    Set-Content -Path $SenityEnvFile -Value $content -Encoding UTF8 -NoNewline
}

# ---- Key-/Lizenz-Validierung gegen den Senity-Proxy -------------------------
# Rueckgabe: @{ valid=$bool; status=<int>; reason=<string>; model=<string|$null> }
# 401/403 liefern die Server-Meldung im Anthropic-Format (error.message),
# z.B. die Lizenz-Ablehnung "Senity Code" (SDRv4-2444: fehlende, gesperrte
# oder abgelaufene claude-code-Lizenz). status=0 bedeutet Netzwerkfehler,
# der Key wurde dabei NICHT als ungueltig erkannt.
# model: Inhalt des Response-Headers X-Senity-Model (tatsaechlich geroutetes
# Modell "<provider>/<model>", CLI-2429). $null wenn der Header fehlt.
function Test-SenityProxyKey([string]$Url, [string]$Key) {
    $endpoint = $Url.TrimEnd('/') + '/v1/messages'
    $body = '{"model":"claude-3-5-haiku-latest","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
    try {
        $resp = Invoke-WebRequest -Uri $endpoint -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec 45 -SkipHttpErrorCheck `
            -Headers @{ 'x-api-key' = $Key; 'anthropic-version' = '2023-06-01' }
    } catch {
        return @{ valid = $false; status = 0; reason = "Proxy nicht erreichbar: $($_.Exception.Message)"; model = $null }
    }
    $model = $null
    try {
        $headerVal = $resp.Headers['X-Senity-Model']
        if ($headerVal) { $model = ([string[]]$headerVal)[0].Trim() }
        if ($model -eq '') { $model = $null }
    } catch {}
    $sc = [int]$resp.StatusCode
    if ($sc -eq 401 -or $sc -eq 403) {
        $serverMsg = $null
        try {
            $parsed = $resp.Content | ConvertFrom-Json
            if ($parsed.error -and $parsed.error.message) { $serverMsg = [string]$parsed.error.message }
        } catch {}
        $reason = if ($serverMsg) { $serverMsg } else { "Key ungueltig (HTTP $sc)" }
        return @{ valid = $false; status = $sc; reason = $reason; model = $model }
    }
    if ($sc -eq 404) {
        return @{ valid = $false; status = 404; reason = "Endpoint nicht gefunden (HTTP 404), Proxy-URL pruefen"; model = $model }
    }
    # 200 sowie 400/422/429/5xx: Auth + Lizenz-Gate wurden passiert
    return @{ valid = $true; status = $sc; reason = "HTTP $sc"; model = $model }
}

# ---- Modell-Transparenz (CLI-2429, Plan 3.4) ---------------------------------
# Der Proxy ignoriert das Client-Modell und routet ueber die cli_chat-Chain.
# Erwartet wird qwen3.6; meldet der Header ein anderes Modell, wird der
# Senity-Start geblockt (Server-Fallback-Chain pruefen). Fehlt der Header
# (offline/Fehler), bleibt es beim fail-open mit Warnung.
$ExpectedSenityModel = "qwen3.6"

function Test-SenityModelGate([string]$Model) {
    if (-not $Model) {
        Write-Warn2 "Modell: unbekannt (Proxy-Header X-Senity-Model nicht erhalten, $ExpectedSenityModel nicht verifizierbar)"
        return
    }
    Write-Log "Modell: $Model"
    if ($Model -notmatch [regex]::Escape($ExpectedSenityModel)) {
        Write-Err2 "Proxy routet aktuell auf '$Model', erwartet war $ExpectedSenityModel."
        Write-Err2 "Server-Fallback-Chain (cli_chat) im SDR pruefen. Start abgebrochen."
        exit 1
    }
}

function Invoke-Login {
    Initialize-Dirs
    $existing = Read-EnvFile
    $url = if ($existing.SENITY_CHAT_PROXY_URL) { $existing.SENITY_CHAT_PROXY_URL } else { $DefaultProxyUrl }

    $promptUrl = Read-Host "Senity Proxy URL [$url]"
    if ($promptUrl) { $url = $promptUrl }
    $secureKey = Read-Host "Senity Proxy Key" -AsSecureString
    $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey))

    if (-not $key) {
        Write-Err2 "Kein Key angegeben. Abbruch."
        exit 1
    }

    Write-Log "Pruefe Key und Senity-Code-Lizenz gegen $url ..."
    $check = Test-SenityProxyKey -Url $url -Key $key
    if (-not $check.valid) {
        if ($check.status -eq 0) {
            Write-Warn2 $check.reason
            Write-Warn2 "Key konnte nicht geprueft werden, wird trotzdem gespeichert."
        } else {
            Write-Err2 "Key abgelehnt: $($check.reason)"
            exit 1
        }
    } else {
        Write-Log "Key und Lizenz OK."
        if ($check.model) { Write-Log "Modell: $($check.model)" }
    }

    Save-EnvFile @{ SENITY_CHAT_PROXY_URL = $url; SENITY_CHAT_PROXY_KEY = $key }
    Write-Log "Konfiguration geschrieben nach $SenityEnvFile"
}

function Get-Env {
    if (-not (Test-Path $SenityEnvFile)) {
        Write-Warn2 "Kein Proxy-Key konfiguriert. Starte 'senity login'..."
        Invoke-Login
    }
    $data = Read-EnvFile
    if (-not $data.SENITY_CHAT_PROXY_URL) { $data.SENITY_CHAT_PROXY_URL = $DefaultProxyUrl }
    if (-not $data.SENITY_CHAT_PROXY_KEY) {
        Write-Err2 "SENITY_CHAT_PROXY_KEY fehlt in $SenityEnvFile."
        exit 1
    }

    # Lizenz-Gate (SDRv4-2444): ohne gueltige Senity-Code-Lizenz kein Start.
    # Netzwerkfehler blocken nicht (Proxy prueft serverseitig ohnehin erneut).
    Write-Log "Pruefe Senity-Code-Lizenz ..."
    $check = Test-SenityProxyKey -Url $data.SENITY_CHAT_PROXY_URL -Key $data.SENITY_CHAT_PROXY_KEY
    if (-not $check.valid) {
        if ($check.status -eq 0) {
            Write-Warn2 $check.reason
            Write-Warn2 "Lizenz-Pruefung uebersprungen (Proxy nicht erreichbar). Die erste Anfrage schlaegt ggf. fehl."
        } else {
            Write-Err2 "Zugriff verweigert: $($check.reason)"
            Write-Err2 "Anderen Key hinterlegen mit: senity login"
            exit 1
        }
    }
    # Modell-Gate (CLI-2429): tatsaechlich geroutetes Modell anzeigen,
    # Start bei bekanntem Fremdmodell blocken.
    if ($check.status -ne 0) { Test-SenityModelGate $check.model }
    return $data
}

# ---- Update -----------------------------------------------------------------
function Update-Repo([string]$Url, [string]$Dest) {
    if (Test-Path (Join-Path $Dest ".git")) {
        try { git -C $Dest pull --ff-only --quiet 2>$null | Out-Null }
        catch { Write-Warn2 "git pull fehlgeschlagen fuer $Dest (offline?), nutze lokalen Stand" }
    } else {
        if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
        try { git clone --quiet --depth 1 $Url $Dest 2>$null | Out-Null }
        catch { Write-Warn2 "git clone fehlgeschlagen fuer $Url, ueberspringe" }
    }
}

function Invoke-Update {
    Write-Log "Update laeuft (-SkipUpdate zum Ueberspringen)"
    $pullOk = $true
    try { docker pull --quiet $script:Image 2>$null | Out-Null } catch { $pullOk = $false }
    if (-not $pullOk) {
        Write-Warn2 "docker pull fehlgeschlagen fuer $script:Image"
        $imgExists = $false
        try { docker image inspect $script:Image *>$null; $imgExists = ($LASTEXITCODE -eq 0) } catch {}
        if (-not $imgExists) {
            $fbExists = $false
            try { docker image inspect $FallbackImage *>$null; $fbExists = ($LASTEXITCODE -eq 0) } catch {}
            if ($fbExists) {
                Write-Warn2 "Fallback auf lokales Image $FallbackImage"
                $script:Image = $FallbackImage
            } else {
                Write-Err2 "Kein verwendbares Image (weder $script:Image noch $FallbackImage lokal)."
                Write-Err2 "Pruefe Netzwerk/Registry-Zugriff auf ghcr.io."
                exit 1
            }
        }
    }

    Update-Repo $SkillsRepo   (Join-Path $SenityCacheDir "skills")
    Update-Repo $CommandsRepo (Join-Path $SenityCacheDir "commands")
    Update-Repo $AgentsRepo   (Join-Path $SenityCacheDir "agents")
    Update-Repo $McpsRepo     (Join-Path $SenityCacheDir "senity-mcps")
}

function Confirm-Image {
    $exists = $false
    try { docker image inspect $script:Image *>$null; $exists = ($LASTEXITCODE -eq 0) } catch {}
    if (-not $exists) {
        $fb = $false
        try { docker image inspect $FallbackImage *>$null; $fb = ($LASTEXITCODE -eq 0) } catch {}
        if ($fb) {
            Write-Warn2 "Image $script:Image lokal nicht vorhanden, nutze Fallback $FallbackImage"
            $script:Image = $FallbackImage
        } else {
            Write-Err2 "Image fehlt und -SkipUpdate verhindert Pull. Aufruf ohne -SkipUpdate wiederholen."
            exit 1
        }
    }
}

# ---- Pfad-Konvertierung Windows -> Docker -----------------------------------
function ConvertTo-DockerPath([string]$Path) {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($resolved) { $Path = $resolved.Path }
    if ($Path -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1].ToLower()
        $rest  = $Matches[2] -replace '\\', '/'
        return "/$drive/$rest"
    }
    return ($Path -replace '\\', '/')
}

# ---- Container starten ------------------------------------------------------
function Invoke-Container([hashtable]$Env, [string]$Mode = "claude") {
    $cwd = (Get-Location).Path
    $containerName = "senity-$PID-$([int][double]::Parse((Get-Date -UFormat %s)))"
    $isComfyUI = ($Mode -eq "comfyui")

    $dockerArgs = @(
        "run", "--rm", "-it",
        "--name", $containerName,
        "-e", "SENITY_AGENT_MODE=$AgentMode",
        "-e", "TERM=xterm-256color",
        "-v", "$($SenityWsDir):/workspace",
        "-v", "$($cwd):/workspace/cwd"
    )
    if ($AgentMode -eq "senity") {
        $dockerArgs += @(
            "-e", "SENITY_CHAT_PROXY_URL=$($Env.SENITY_CHAT_PROXY_URL)",
            "-e", "SENITY_CHAT_PROXY_KEY=$($Env.SENITY_CHAT_PROXY_KEY)",
            "-e", "ANTHROPIC_BASE_URL=$($Env.SENITY_CHAT_PROXY_URL)",
            "-e", "ANTHROPIC_API_KEY=$($Env.SENITY_CHAT_PROXY_KEY)"
        )
    } else {
        $dockerArgs += @(
            "-e", "SENITY_NO_BANNER=1",
            "-e", "SENITY_MODEL_SYNC=0",
            "-e", "SENITY_THEME_DEFAULT=0"
        )
        foreach ($envName in @(
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_FABLE_MODEL",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "OPENAI_API_KEY",
            "GOOGLE_API_KEY"
        )) {
            $envValue = [Environment]::GetEnvironmentVariable($envName)
            if ($envValue) { $dockerArgs += @("-e", "$envName=$envValue") }
        }
    }
    if ($isComfyUI) {
        $dockerArgs += @(
            "-p", "127.0.0.1:${ComfyUIPort}:8188",
            "-e", "SENITY_COMFYUI_PORT=8188",
            "-e", "SENITY_COMFYUI_HOST_PORT=$ComfyUIPort",
            "-e", "SENITY_MODEL_SYNC=0"
        )
        if ($ComfyUIGpu) { $dockerArgs += @("--gpus", "all") }
    }

    $skillsSrc   = Join-Path $SenityCacheDir "skills\skills"
    $commandsSrc = Join-Path $SenityCacheDir "commands\commands"
    $agentsSrc   = Join-Path $SenityCacheDir "agents\agents"
    $mcpsSrc     = Join-Path $SenityCacheDir "senity-mcps"

    if (Test-Path $skillsSrc)   { $dockerArgs += @("-v", "$($skillsSrc):/workspace/.claude/skills/intern:ro") }
    if (Test-Path $commandsSrc) { $dockerArgs += @("-v", "$($commandsSrc):/workspace/.claude/commands/intern:ro") }
    if (Test-Path $agentsSrc)   { $dockerArgs += @("-v", "$($agentsSrc):/workspace/.claude/agents/intern:ro") }
    if (Test-Path $mcpsSrc)     { $dockerArgs += @("-v", "$($mcpsSrc):/workspace/.mcp/senity-mcps") }
    if (Test-Path $SenityMcpConfig) { $dockerArgs += @("-v", "$($SenityMcpConfig):/workspace/.mcp-config.json:ro") }

    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    if (Test-Path $sshDir) { $dockerArgs += @("-v", "$($sshDir):/home/node/.ssh:ro") }

    foreach ($m in $Mount) { if ($m) { $dockerArgs += @("-v", $m) } }

    $dockerArgs += @("-w", "/workspace/cwd", $script:Image)
    if ($isComfyUI) {
        Write-Log "Starte ComfyUI: http://127.0.0.1:$ComfyUIPort"
        $dockerArgs += "senity-comfyui"
        foreach ($a in $ClaudeArgs) { if ($a) { $dockerArgs += $a } }
    } else {
        Write-Log "Starte $AgentLabel"
        switch ($AgentMode) {
            "senity" {
                $dockerArgs += @("senity-mascot-filter", "claude")
                if (-not $NoYolo) { $dockerArgs += "--dangerously-skip-permissions" }
            }
            "claude" {
                $dockerArgs += "claude-upstream"
                if (-not $NoYolo) { $dockerArgs += "--dangerously-skip-permissions" }
            }
            "codex" {
                $dockerArgs += "codex"
            }
            "antigravity" {
                $dockerArgs += "agy"
            }
            default {
                Write-Err2 "Unbekannter Agent-Modus: $AgentMode"
                exit 1
            }
        }
        foreach ($a in $ClaudeArgs) { if ($a) { $dockerArgs += $a } }
    }

    & docker @dockerArgs
    exit $LASTEXITCODE
}

# ---- Gitea Device-Flow Subcommands ------------------------------------------
function Confirm-GiteaAvailable {
    if (-not $SenityGiteaAvailable) {
        Write-Err2 "gitea-device-flow.ps1 nicht gefunden (Reinstall: install.ps1)."
        exit 6
    }
}

function Invoke-GiteaLogin {
    Confirm-GiteaAvailable
    Initialize-Dirs
    $depRc = Test-GiteaDeps
    if ($depRc -ne 0) { exit $depRc }

    # Headless: SENITY_GITEA_RT via Env, sofort persistieren ueber Refresh-Cycle
    if ($Headless) {
        if (-not $env:SENITY_GITEA_RT) {
            Write-Err2 "Headless-Mode braucht SENITY_GITEA_RT in der Umgebung."
            exit 6
        }
        $refreshed = Invoke-GiteaRefresh -RefreshToken $env:SENITY_GITEA_RT
        if ($refreshed.__exit) { exit $refreshed.__exit }
        if (-not (Save-GiteaAuth -TokenResponse $refreshed)) { exit 6 }
        Write-Log "Headless-Login OK (auth.json geschrieben)"
        exit 0
    }

    $init = Invoke-GiteaDeviceInit
    if (-not $init) { exit 6 }
    $deviceCode  = $init.device_code
    $userCode    = $init.user_code
    $uri         = $init.verification_uri
    $uriComplete = $init.verification_uri_complete
    $interval    = if ($init.interval) { [int]$init.interval } else { 5 }
    if (-not $deviceCode -or -not $userCode) {
        Write-Err2 "Device-Init-Response unvollstaendig"
        exit 6
    }

    Show-GiteaUserCode -UserCode $userCode -Uri $uri -UriComplete $uriComplete

    # Browser oeffnen (best-effort)
    if ($uriComplete) {
        try { Start-Process $uriComplete | Out-Null } catch {}
    }

    $tokenResp = Invoke-GiteaPollToken -DeviceCode $deviceCode -Interval $interval
    if ($tokenResp.__exit) { exit $tokenResp.__exit }
    if (-not (Save-GiteaAuth -TokenResponse $tokenResp)) { exit 6 }
    Write-Log "Login OK"
    exit 0
}

function Get-GiteaFreshAccessToken {
    # Liefert PSCustomObject mit @{ status; access_token } oder $null
    # status: missing / fresh / refreshed / stale_no_rt / invalid_grant / net_err
    $freshness = Get-GiteaTokenFreshness
    if ($freshness -eq "missing") { return @{ status = "missing" } }
    $auth = Read-GiteaAuth
    if (-not $auth) { return @{ status = "missing" } }
    if ($freshness -eq "fresh") {
        return @{ status = "fresh"; access_token = $auth.access_token }
    }
    # stale -> refresh
    if (-not $auth.refresh_token) {
        return @{ status = "stale_no_rt" }
    }
    $r = Invoke-GiteaRefresh -RefreshToken $auth.refresh_token
    if ($r.__exit -eq 3) { return @{ status = "invalid_grant" } }
    if ($r.__exit) { return @{ status = "net_err" } }
    # Saven (uebernimmt neuen rt falls Server rotiert)
    if (-not (Save-GiteaAuth -TokenResponse $r)) { return @{ status = "net_err" } }
    return @{ status = "refreshed"; access_token = $r.access_token }
}

function Invoke-GiteaToken {
    Confirm-GiteaAvailable
    $depRc = Test-GiteaDeps
    if ($depRc -ne 0) { exit $depRc }

    # Default = -EnsureFresh (Wrapper-Vertrag)
    $shouldEnsure = $true
    if ($PSBoundParameters.ContainsKey('EnsureFresh') -and -not $EnsureFresh) { $shouldEnsure = $false }
    if (-not $EnsureFresh -and -not $WriteDockerConfig -and -not $Print) { $shouldEnsure = $true }

    $res = Get-GiteaFreshAccessToken
    switch ($res.status) {
        "missing"       { Write-Err2 "Kein auth.json. 'senity gitea-login' ausfuehren."; exit 2 }
        "stale_no_rt"   { Write-Err2 "auth.json hat keinen refresh_token. Neu einloggen."; exit 2 }
        "invalid_grant" { Write-Err2 "refresh_token ungueltig (revoked/expired). 'senity gitea-login' wiederholen."; exit 3 }
        "net_err"       { exit 6 }
        default { }
    }

    if ($WriteDockerConfig) {
        if (Write-GiteaDockerConfig -AccessToken $res.access_token) {
            Write-Log "~/.docker/config.json aktualisiert (oauth2:<token>)"
        } else {
            Write-Err2 "Docker-Config konnte nicht geschrieben werden"
            exit 6
        }
    }
    if ($Print) {
        # Token nur ueber stdout, NIE ueber Logger
        [Console]::Out.Write($res.access_token)
        [Console]::Out.WriteLine()
    }
    exit 0
}

function Invoke-GiteaStatus {
    Confirm-GiteaAvailable
    $auth = Read-GiteaAuth
    if (-not $auth) {
        Write-Host "Status: kein Login (auth.json fehlt)"
        exit 2
    }
    $freshness = Get-GiteaTokenFreshness
    $expEpoch = [int]$auth.access_token_expires_at
    $expDate = [DateTimeOffset]::FromUnixTimeSeconds($expEpoch).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz")
    $connEpoch = [int]$auth.connected_at
    $connDate = [DateTimeOffset]::FromUnixTimeSeconds($connEpoch).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz")

    Write-Host "Status:"
    Write-Host "  Gitea-User:   $($auth.gitea_user) (id=$($auth.gitea_user_id))"
    Write-Host "  Scopes:       $($auth.scopes)"
    Write-Host "  Connected:    $connDate"
    Write-Host "  Access-Token: $freshness (expires $expDate)"
    Write-Host "  Auth-File:    $script:GiteaAuthFile"
    Write-Host ""
    Write-Host "(Tokens werden absichtlich NICHT angezeigt.)"
    exit 0
}

function Invoke-GiteaLogout {
    Confirm-GiteaAvailable
    $auth = Read-GiteaAuth
    if ($auth -and $auth.refresh_token) {
        Invoke-GiteaRevoke -RefreshToken $auth.refresh_token
    }
    if (Test-Path $script:GiteaAuthFile) {
        Remove-Item -LiteralPath $script:GiteaAuthFile -Force
        Write-Log "auth.json geloescht"
    }
    if (Remove-GiteaDockerEntry) {
        Write-Log "Docker-Auth-Entry entfernt (falls vorhanden)"
    }
    Write-Log "Logout OK"
    exit 0
}

# ---- Main -------------------------------------------------------------------
switch ($Subcommand) {
    "login"         { Invoke-Login; exit 0 }
    "gitea-login"   { Invoke-GiteaLogin }
    "gitea-token"   { Invoke-GiteaToken }
    "gitea-status"  { Invoke-GiteaStatus }
    "gitea-logout"  { Invoke-GiteaLogout }
}

Test-Docker
Initialize-Dirs
if ($Subcommand -eq "comfyui" -or $AgentMode -ne "senity") {
    $envData = Read-EnvFile
    if (-not $envData.SENITY_CHAT_PROXY_URL) { $envData.SENITY_CHAT_PROXY_URL = $DefaultProxyUrl }
    if (-not $envData.SENITY_CHAT_PROXY_KEY) { $envData.SENITY_CHAT_PROXY_KEY = "" }
} else {
    $envData = Get-Env
}

if ($SkipUpdate) {
    Write-Log "Auto-Update uebersprungen (-SkipUpdate)"
    Confirm-Image
} else {
    Invoke-Update
}

$mode = if ($Subcommand -eq "comfyui") { "comfyui" } else { "claude" }
Invoke-Container -Env $envData -Mode $mode
