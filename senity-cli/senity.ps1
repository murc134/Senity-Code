#!/usr/bin/env pwsh
# senity - globaler CLI-Wrapper fuer den Senity-Workspace-Container (Windows / pwsh).
# Startet einen Ad-hoc-Container mit dem aktuellen cwd als /workspace/cwd.
#
# Defaults:
#   - Image:        git.senity.ai/senity-admin/senity-code:latest
#                   Fallback (kein Pull moeglich): senity-claude:latest
#   - Auto-Update:  bei jedem Start. -SkipUpdate ueberspringt.
#   - Yolo:         an. -NoYolo deaktiviert.
#
# Usage:
#   senity                      Container starten
#   senity -SkipUpdate          Ohne docker pull / git pull
#   senity -NoYolo              Permission-Prompts an
#   senity -Mount H:C[:ro]      Zusatz-Mount (mehrfach)
#   senity -Image <ref>         Image-Tag ueberschreiben
#   senity login                Senity-Proxy-Key einrichten
#   senity -h                   Hilfe

[CmdletBinding(PositionalBinding=$false)]
param(
    [switch]$SkipUpdate,
    [switch]$NoYolo,
    [switch]$Yolo,
    [string[]]$Mount = @(),
    [string]$Image = "",
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

$DefaultImage    = "git.senity.ai/senity-admin/senity-code:latest"
$FallbackImage   = "senity-claude:latest"
$DefaultProxyUrl = "https://sdr.senity.ai/api/claude-proxy"

$SkillsRepo      = "git@github.com:murc134/Claude-Skills.git"
$CommandsRepo    = "git@github.com:murc134/Claude-Commands.git"
$AgentsRepo      = "git@github.com:murc134/Claude-Agents.git"
$McpsRepo        = "ssh://git@git.senity.ai:2200/senity/senity-mcps.git"

# ---- Logging ----------------------------------------------------------------
function Write-Log  ([string]$Msg) { Write-Host "[senity] $Msg" -ForegroundColor Magenta }
function Write-Warn2([string]$Msg) { Write-Host "[senity] $Msg" -ForegroundColor Yellow }
function Write-Err2 ([string]$Msg) { Write-Host "[senity] $Msg" -ForegroundColor Red }

# ---- Help -------------------------------------------------------------------
function Show-Help {
    @"
senity - Senity-Workspace-Container auf Knopfdruck

USAGE
  senity [options] [-- claude-args...]
  senity login
  senity -h

OPTIONS
  -SkipUpdate           Ueberspringt docker pull + git pull beim Start
  -NoYolo               Permission-Prompts aktivieren (Default: Yolo an)
  -Yolo                 Yolo explizit an (Default)
  -Mount H:C[:ro]       Zusatz-Mount, mehrfach erlaubt
  -Image <ref>          Image-Tag ueberschreiben
  -h                    Diese Hilfe

SUBCOMMANDS
  login                 Senity-Proxy-Key in ~/.senity/.env hinterlegen
"@ | Write-Host
}

if ($HelpRequest) { Show-Help; exit 0 }

# ---- Subcommand extrahieren -------------------------------------------------
$Subcommand = ""
$ClaudeArgs = @()
foreach ($arg in $Rest) {
    if ($Subcommand -eq "" -and $arg -eq "login") { $Subcommand = "login"; continue }
    $ClaudeArgs += $arg
}

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
                Write-Err2 "Pruefe Login: docker login git.senity.ai"
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
function Invoke-Container([hashtable]$Env) {
    $cwd = (Get-Location).Path
    $containerName = "senity-$PID-$([int][double]::Parse((Get-Date -UFormat %s)))"

    $dockerArgs = @(
        "run", "--rm", "-it",
        "--name", $containerName,
        "-e", "SENITY_CHAT_PROXY_URL=$($Env.SENITY_CHAT_PROXY_URL)",
        "-e", "SENITY_CHAT_PROXY_KEY=$($Env.SENITY_CHAT_PROXY_KEY)",
        "-e", "ANTHROPIC_BASE_URL=$($Env.SENITY_CHAT_PROXY_URL)",
        "-e", "ANTHROPIC_API_KEY=$($Env.SENITY_CHAT_PROXY_KEY)",
        "-e", "TERM=xterm-256color",
        "-v", "$($SenityWsDir):/workspace",
        "-v", "$($cwd):/workspace/cwd"
    )

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

    $dockerArgs += @("-w", "/workspace/cwd", $script:Image, "senity-mascot-filter", "claude")
    if (-not $NoYolo) { $dockerArgs += "--dangerously-skip-permissions" }
    foreach ($a in $ClaudeArgs) { if ($a) { $dockerArgs += $a } }

    & docker @dockerArgs
    exit $LASTEXITCODE
}

# ---- Main -------------------------------------------------------------------
if ($Subcommand -eq "login") { Invoke-Login; exit 0 }

Test-Docker
Initialize-Dirs
$envData = Get-Env

if ($SkipUpdate) {
    Write-Log "Auto-Update uebersprungen (-SkipUpdate)"
    Confirm-Image
} else {
    Invoke-Update
}

Invoke-Container -Env $envData
