# ══════════════════════════════════════════════════════════════
# claude-senity.ps1 — Senity Workspace (Container Start)
#
# Usage:
#   .\claude-senity.ps1                           # Senity Claude-Proxy (Default)
#   .\claude-senity.ps1 --msh                     # MSH Gateway (qwen3.6)
#   .\claude-senity.ps1 --senity                  # Senity Ollama Cloud (qwen3:8b)
#   .\claude-senity.ps1 --anthropic --yolo        # Direkt Anthropic + Yolo
#   .\claude-senity.ps1 --ollama --model llama3.1 # Lokaler Ollama
# ══════════════════════════════════════════════════════════════
param(
    [switch]$Proxy,
    [switch]$Senity,
    [switch]$Msh,
    [switch]$Anthropic,
    [switch]$Ollama,
    [switch]$Yolo,
    [switch]$NoYolo,
    [string]$Model,
    [string]$Endpoint,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Continue"

# ScriptDir ermitteln — mehrere Fallbacks
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = $PWD.Path }

# ── Ausgabe-Hilfsfunktionen ──
function Write-OK   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-FAIL { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-WARN { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-INFO { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor Cyan }
function Write-DBG  { param([string]$m) Write-Host "  [DBG]  $m" -ForegroundColor DarkGray }
function Write-Sep  { Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray }
function ConvertTo-DockerPath { param([string]$p) return ($p -replace '\\', '/') }

function Exit-Error {
    param([string]$msg, [int]$code = 1)
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║  FEHLER                                  ║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Red
    foreach ($line in ($msg -split "`n")) {
        Write-Host "  $line" -ForegroundColor Red
    }
    Write-Host ""
    exit $code
}

# ── Banner (ALLERERSTE Ausgabe — so sieht man sofort ob das Script laeuft) ──
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║   Senity Workspace  —  Claude Code CLI   ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-DBG "ScriptDir  : $ScriptDir"
Write-DBG "PowerShell : $($PSVersionTable.PSVersion)"
Write-DBG "User       : $($env:USERNAME)  PID: $PID"
Write-DBG "Args       : Proxy=$Proxy Senity=$Senity Msh=$Msh Anthropic=$Anthropic Ollama=$Ollama Yolo=$Yolo Model=$Model"
Write-Host ""

# ── Help ──
if ($Help) {
    Write-Host "  Usage: .\claude-senity.ps1 [OPTIONS]" -ForegroundColor White
    Write-Host ""
    Write-Host "  Provider (Standard: --proxy):" -ForegroundColor White
    Write-Host "    --proxy          Senity Chat Proxy (sdr.senity.ai)" -ForegroundColor White
    Write-Host "    --msh            MSH Gateway (qwen3.6)" -ForegroundColor White
    Write-Host "    --senity         Senity Ollama Cloud (qwen3:8b)" -ForegroundColor White
    Write-Host "    --anthropic      Direkte Anthropic API" -ForegroundColor White
    Write-Host "    --ollama         Lokaler Ollama" -ForegroundColor White
    Write-Host ""
    Write-Host "  Optionen:" -ForegroundColor White
    Write-Host "    --model NAME     Modell ueberschreiben" -ForegroundColor White
    Write-Host "    --yolo           Yolo Mode (ungefragte Ausfuehrung)" -ForegroundColor White
    Write-Host "    --no-yolo        Yolo Mode explizit deaktivieren" -ForegroundColor White
    Write-Host "    --endpoint URL   Ollama/Custom Endpoint URL" -ForegroundColor White
    Write-Host "    --help           Diese Hilfe" -ForegroundColor White
    Write-Host ""
    exit 0
}

# ══════════════════════════════════════════════════════════════
# [1] .env laden
# ══════════════════════════════════════════════════════════════
Write-INFO "[1/7] .env laden..."
$envFile = Join-Path $ScriptDir ".env"
$envVars = @{}
if (Test-Path $envFile) {
    Write-OK ".env gefunden: $envFile"
    $loadedCount = 0
    Get-Content $envFile -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line -match '^#') { return }
        if ($line -match '^[^=]+=') {
            $idx  = $line.IndexOf('=')
            $key  = $line.Substring(0, $idx).Trim()
            $val  = $line.Substring($idx + 1).Trim()
            if ($val -match '^".*"$') { $val = $val.Substring(1, $val.Length - 2) }
            elseif ($val -match "^'.*'$") { $val = $val.Substring(1, $val.Length - 2) }
            $envVars[$key] = $val
            $loadedCount++
            $display = if ($key -match 'KEY|SECRET|TOKEN|PASSWORD') { '[REDACTED]' } else { $val }
            Write-DBG "  $key = $display"
        }
    }
    Write-OK "$loadedCount Variablen geladen"
} else {
    Write-WARN ".env nicht gefunden: $envFile"
    Write-INFO "Fahre ohne .env fort — System-Umgebungsvariablen werden geprueft"
}

# ══════════════════════════════════════════════════════════════
# [2] Provider ermitteln
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[2/7] Provider ermitteln..."
$modeFlags = @()
if ($Proxy)     { $modeFlags += "proxy" }
if ($Senity)    { $modeFlags += "senity" }
if ($Msh)       { $modeFlags += "msh" }
if ($Anthropic) { $modeFlags += "anthropic" }
if ($Ollama)    { $modeFlags += "ollama" }
if ($modeFlags.Count -gt 1) {
    Exit-Error "Mehrere Provider-Flags gesetzt ($($modeFlags -join ', ')). Bitte nur einen angeben: --proxy, --senity, --msh, --anthropic oder --ollama"
}
$Mode = if ($modeFlags.Count -eq 1) { $modeFlags[0] } else { "proxy" }
Write-OK "Modus: $Mode"

# ══════════════════════════════════════════════════════════════
# [3] Credentials und URL ermitteln
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[3/7] Credentials pruefen..."
$token        = ""
$baseUrl      = ""
$defaultModel = "claude-sonnet-4-6"

switch ($Mode) {
    "proxy" {
        $token = $envVars['SENITY_CHAT_PROXY_KEY']
        if (-not $token) { $token = $env:SENITY_CHAT_PROXY_KEY }
        if (-not $token) {
            Exit-Error "SENITY_CHAT_PROXY_KEY nicht gesetzt.`nBitte in .env eintragen: SENITY_CHAT_PROXY_KEY=<dein-container-key>"
        }
        Write-OK "SENITY_CHAT_PROXY_KEY: gesetzt (Laenge: $($token.Length))"

        if ($token -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            Write-OK "Key-Format: UUID (gueltig)"
        } elseif ($token -match '^[0-9a-fA-F]{64}$') {
            Write-OK "Key-Format: 64-Hex (gueltig)"
        } else {
            Write-WARN "Key-Format: unbekannt (Laenge=$($token.Length))"
            Write-INFO "Erwartet: UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) oder 64-Hex"
        }

        $baseUrl = $envVars['SENITY_CHAT_PROXY_URL']
        if (-not $baseUrl) { $baseUrl = "https://sdr.senity.ai/api/claude-proxy" }
        $defaultModel = "claude-sonnet-4-6"
        Write-OK "Proxy-URL: $baseUrl"
    }
    "senity" {
        $token = $envVars['SENITY_OLLAMA_API_KEY']
        if (-not $token) { $token = $env:SENITY_OLLAMA_API_KEY }
        if (-not $token) {
            Exit-Error "SENITY_OLLAMA_API_KEY nicht gesetzt.`nBitte in .env eintragen: SENITY_OLLAMA_API_KEY=<key>"
        }
        Write-OK "SENITY_OLLAMA_API_KEY: gesetzt"
        $baseUrl      = $envVars['SENITY_OLLAMA_URL']
        if (-not $baseUrl) { $baseUrl = "https://ollama.senity.ai" }
        $defaultModel = $envVars['SENITY_OLLAMA_MODEL']
        if (-not $defaultModel) { $defaultModel = "qwen3:8b" }
        Write-OK "Ollama-URL: $baseUrl"
    }
    "msh" {
        $token = $envVars['MSH_API_KEY']
        if (-not $token) { $token = $env:MSH_API_KEY }
        if (-not $token) {
            Exit-Error "MSH_API_KEY nicht gesetzt.`nBitte in .env eintragen: MSH_API_KEY=<key>"
        }
        Write-OK "MSH_API_KEY: gesetzt"
        $baseUrl      = $envVars['MSH_API_URL']
        if (-not $baseUrl) { $baseUrl = "https://gateway.missionstarkeshandwerk.de" }
        $defaultModel = $envVars['MSH_VLLM_MODEL']
        if (-not $defaultModel) { $defaultModel = "qwen3.6" }
        Write-OK "MSH-URL: $baseUrl"
    }
    "anthropic" {
        $token = $env:ANTHROPIC_API_KEY
        if (-not $token) { $token = $envVars['ANTHROPIC_API_KEY'] }
        if (-not $token) {
            Exit-Error "ANTHROPIC_API_KEY nicht gesetzt.`nBitte in .env eintragen: ANTHROPIC_API_KEY=sk-ant-..."
        }
        Write-OK "ANTHROPIC_API_KEY: gesetzt"
        $baseUrl      = ""
        $defaultModel = "claude-sonnet-4-6"
    }
    "ollama" {
        $token        = "ollama"
        $baseUrl      = if ($Endpoint) { $Endpoint } else { "http://host.docker.internal:11434" }
        $defaultModel = ""
        Write-OK "Ollama-Endpoint: $baseUrl"
        if (-not $Model) { Write-WARN "Kein --model angegeben fuer Ollama. Bitte Modell-ID uebergeben, z.B.: --model llama3.1" }
    }
    default {
        Exit-Error "Unbekannter Modus '$Mode'. Gueltige Modi: proxy, senity, msh, anthropic, ollama"
    }
}

# Modell
if (-not $Model) { $Model = $defaultModel }
Write-OK "Modell: $Model"

# Yolo
$yolo = [bool]$Yolo
if ($NoYolo) { $yolo = $false }
Write-OK "Yolo-Mode: $([bool]$yolo)$(if ($yolo) { '  (Achtung: ungefragte Ausfuehrung!)' })"

# ══════════════════════════════════════════════════════════════
# [4] Netzwerk pruefen
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[4/7] Netzwerk pruefen..."
if ($baseUrl -and $baseUrl -match '^https?://') {
    Write-DBG "Pruefe: $baseUrl"
    try {
        $req = [System.Net.HttpWebRequest]::Create($baseUrl)
        $req.Method = "HEAD"
        $req.Timeout = 8000
        $req.UserAgent = "senity-workspace/1.0"
        try {
            $resp = $req.GetResponse()
            $statusCode = [int]$resp.StatusCode
            $resp.Close()
            Write-OK "HTTP-Antwort: $statusCode $(([System.Net.HttpStatusCode]$statusCode).ToString())"
            if ($statusCode -eq 401) {
                Write-INFO "401 = URL erreichbar, API-Key wird beim Container-Start validiert"
            } elseif ($statusCode -ge 500) {
                Write-WARN "Server antwortet mit $statusCode — Proxy moeglicherweise nicht verfuegbar"
            }
        } catch [System.Net.WebException] {
            $webEx = $_.Exception
            if ($webEx.Response) {
                $statusCode = [int]$webEx.Response.StatusCode
                $webEx.Response.Close()
                Write-OK "HTTP-Antwort: $statusCode (erwartet bei falscher Auth)"
            } else {
                $errMsg    = $webEx.Message
                $errStatus = $webEx.Status
                if ($errMsg -match "SSL|TLS|certificate|trust") {
                    Exit-Error "TLS/SSL-Fehler bei $baseUrl`nDetails: $errMsg`nMoeglicherweise falsches Zertifikat oder falscher Hostname."
                } elseif ($errStatus -eq [System.Net.WebExceptionStatus]::NameResolutionFailure) {
                    Exit-Error "DNS-Fehler: '$baseUrl' nicht aufloesbar.`nInternetverbindung pruefen oder URL in .env korrigieren."
                } elseif ($errStatus -eq [System.Net.WebExceptionStatus]::Timeout) {
                    Write-WARN "Timeout (8s) beim Erreichen von $baseUrl - Netzwerkprobleme moeglich"
                } elseif ($errStatus -eq [System.Net.WebExceptionStatus]::ConnectFailure) {
                    Exit-Error "Verbindung abgelehnt: $baseUrl`nServer nicht erreichbar (Port gesperrt oder Service down)."
                } else {
                    Write-WARN "Netzwerkfehler ($errStatus): $errMsg"
                }
            }
        }
    } catch {
        Write-WARN "Netzwerktest fehlgeschlagen: $($_.Exception.Message)"
    }
} elseif ($Mode -eq "ollama") {
    Write-INFO "Ollama (lokal) — Netzwerktest wird im Container durchgefuehrt"
} else {
    Write-INFO "Kein externer Endpunkt — Netzwerktest uebersprungen"
}

# ══════════════════════════════════════════════════════════════
# [5] TTY pruefen
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[5/7] TTY pruefen..."
Write-DBG "IsInputRedirected  : $([System.Console]::IsInputRedirected)"
Write-DBG "IsOutputRedirected : $([System.Console]::IsOutputRedirected)"
Write-DBG "IsErrorRedirected  : $([System.Console]::IsErrorRedirected)"

$hasTTY = -not [System.Console]::IsInputRedirected

if (-not $hasTTY) {
    Write-WARN "Kein TTY verfuegbar. 'docker run -it' benoetigt echtes Terminal."
    $wt = Get-Command wt -ErrorAction SilentlyContinue
    if ($wt) {
        Write-OK "Windows Terminal (wt.exe) gefunden: $($wt.Source)"
        Write-INFO "Starte Senity Workspace in neuem Windows Terminal Fenster..."

        $scriptPath = $MyInvocation.MyCommand.Path
        if (-not $scriptPath) { $scriptPath = Join-Path $ScriptDir "claude-senity.ps1" }

        $flagParts = @()
        if ($Proxy)     { $flagParts += "-Proxy" }
        if ($Senity)    { $flagParts += "-Senity" }
        if ($Msh)       { $flagParts += "-Msh" }
        if ($Anthropic) { $flagParts += "-Anthropic" }
        if ($Ollama)    { $flagParts += "-Ollama" }
        if ($Yolo)      { $flagParts += "-Yolo" }
        if ($NoYolo)    { $flagParts += "-NoYolo" }
        if ($Model -and $Model -ne $defaultModel) { $flagParts += "-Model '$Model'" }
        if ($Endpoint)  { $flagParts += "-Endpoint '$Endpoint'" }
        foreach ($r in $Rest) { $flagParts += $r }
        $argStr = $flagParts -join " "

        # Temp-Wrapper-Script: haelt Fenster bei Fehler offen, raeumt sich selbst auf
        $tempScript        = [System.IO.Path]::Combine($env:TEMP, "senity-launch-$PID.ps1")
        $escapedScriptDir  = $ScriptDir.Replace("'", "''")
        $escapedScriptPath = $scriptPath.Replace("'", "''")
        $wrapperContent = @"
Set-Location '$escapedScriptDir'
& '$escapedScriptPath' $argStr
`$ec = `$LASTEXITCODE
if (`$ec -ne 0 -and `$ec -ne 130) {
    Write-Host ""
    Write-Host "  Container beendet mit Fehler (Exit-Code: `$ec)" -ForegroundColor Red
    Write-Host "  Bitte Ausgabe oben pruefen." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Druecke Enter zum Schliessen..." -ForegroundColor DarkGray
    Read-Host
}
Remove-Item -Path `$MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue
"@
        Set-Content -Path $tempScript -Value $wrapperContent -Encoding UTF8
        Write-DBG "Wrapper-Script: $tempScript"

        $wtArgs = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
        Start-Process "wt" -ArgumentList $wtArgs
        Write-OK "Windows Terminal gestartet."
        exit 0
    } else {
        Exit-Error "Kein TTY und Windows Terminal (wt.exe) nicht gefunden.`nBitte direkt aus Windows Terminal starten:`n  1. Windows Terminal oeffnen (Win+R: wt)`n  2. In diesen Ordner navigieren: cd '$ScriptDir'`n  3. Script starten: .\claude-senity.ps1"
    }
} else {
    Write-OK "TTY verfuegbar"
}

$safeUser = ($env:USERNAME -replace '[^a-zA-Z0-9_.-]', '_').ToLower()

# ══════════════════════════════════════════════════════════════
# [6] Docker pruefen
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[6/7] Docker pruefen..."

# Docker-CLI
$dockerBin = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerBin) {
    Exit-Error "Docker-CLI nicht im PATH gefunden.`nDocker Desktop installieren: https://docs.docker.com/desktop/install/windows-install/`nOder per winget: winget install Docker.DockerDesktop"
}
Write-OK "Docker-CLI: $($dockerBin.Source)"

$dockerVerOutput = docker --version 2>&1
Write-OK "Docker-Version: $dockerVerOutput"

# Docker Desktop Exe
$dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (Test-Path $dockerDesktopExe) {
    Write-OK "Docker Desktop: gefunden ($dockerDesktopExe)"
} else {
    Write-WARN "Docker Desktop nicht unter Standardpfad gefunden"
    Write-INFO "Pruefe Docker-Daemon direkt (Docker koennte auch via WSL laufen)..."
}

# Docker Daemon
Write-INFO "Pruefe Docker Daemon (docker info)..."
$daemonOutput = docker info 2>&1
$daemonOk = ($LASTEXITCODE -eq 0)

if (-not $daemonOk) {
    $daemonText = $daemonOutput -join "`n"
    Write-WARN "Docker Daemon nicht erreichbar."
    Write-DBG "docker info Output: $daemonText"

    if ($daemonText -match "permission denied|Access is denied|Zugriff verweigert") {
        Exit-Error "Docker: Zugriff verweigert.`nLoesung 1: Als Administrator ausfuehren`nLoesung 2: Benutzer '$($env:USERNAME)' zur Gruppe 'docker-users' hinzufuegen`n  (lusrmgr.msc -> docker-users -> Mitglieder -> Hinzufuegen)"
    } elseif ($daemonText -match "pipe|socket|named pipe") {
        Write-INFO "Docker Socket nicht erreichbar. Starte Docker Desktop..."
    } elseif ($daemonText -match "Cannot connect") {
        Write-INFO "Docker Desktop nicht laufend. Starte..."
    }

    if (Test-Path $dockerDesktopExe) {
        Write-INFO "Starte Docker Desktop..."
        Start-Process $dockerDesktopExe
        $timeout = 120
        $elapsed = 0
        $ready   = $false
        while ($elapsed -lt $timeout) {
            Start-Sleep -Seconds 3
            $elapsed += 3
            docker info 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            Write-Host "  [WAIT] Warte auf Docker Desktop... ($elapsed/$timeout s)" -ForegroundColor DarkGray
        }
        if (-not $ready) {
            Exit-Error "Docker Desktop nach $timeout Sekunden nicht bereit.`nBitte Docker Desktop manuell starten und erneut versuchen."
        }
        Write-OK "Docker Desktop bereit"
    } else {
        Exit-Error "Docker Daemon nicht erreichbar und Docker Desktop nicht gefunden.`nBitte Docker Desktop installieren und starten.`nhttps://docs.docker.com/desktop/install/windows-install/"
    }
} else {
    Write-OK "Docker Daemon: bereit"
    Write-DBG "$(($daemonOutput | Select-String 'Server Version|Operating System|Architecture' | ForEach-Object { $_.Line }) -join ' | ')"
}

# Image pruefen
Write-INFO "Pruefe Docker Image 'senity-claude:latest'..."
docker image inspect senity-claude:latest 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-WARN "Image 'senity-claude:latest' nicht gefunden."
    $dockerfilePath = Join-Path $ScriptDir "Dockerfile"
    if (-not (Test-Path $dockerfilePath)) {
        Exit-Error "Dockerfile nicht gefunden: $dockerfilePath`nBitte im richtigen Verzeichnis ausfuehren oder 'setup.ps1' zuerst starten."
    }
    Write-INFO "Starte Image-Build (kann 2-5 Minuten dauern)..."
    docker build -t senity-claude:latest "$ScriptDir"
    if ($LASTEXITCODE -ne 0) {
        Exit-Error "Image-Build fehlgeschlagen (Exit $LASTEXITCODE).`nBitte manuell pruefen: docker build -t senity-claude:latest '$ScriptDir'"
    }
    Write-OK "Image gebaut: senity-claude:latest"
} else {
    $imageCreated = docker image inspect senity-claude:latest --format "{{.Created}}" 2>&1
    Write-OK "Image vorhanden (erstellt: $imageCreated)"
}

# Zombie-Container aufraemen
Write-INFO "Pruefe auf veraltete Senity-Container..."
$zombies = docker ps -a --filter "name=senity-workspace-$safeUser" --filter "status=exited" --format "{{.Names}}" 2>&1
if ($zombies -and $LASTEXITCODE -eq 0) {
    $exactPattern = "^senity-workspace-$([regex]::Escape($safeUser))-\d+$"
    $matchedZombies = $zombies -split "`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and $_ -match $exactPattern }
    if ($matchedZombies) {
        foreach ($z in $matchedZombies) {
            Write-WARN "Entferne veralteten Container: $z"
            docker rm -f "$z" 2>&1 | Out-Null
        }
    } else {
        Write-OK "Keine veralteten Container gefunden"
    }
} else {
    Write-OK "Keine veralteten Container gefunden"
}

# ══════════════════════════════════════════════════════════════
# [7] Container starten
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[7/7] Container starten..."

$containerName = "senity-workspace-$safeUser-$PID"
$workspacePath = Join-Path $ScriptDir "workspace"
$claudeDir     = Join-Path $ScriptDir ".claude"

# Verzeichnisse erstellen und pruefen
foreach ($dir in @($workspacePath, $claudeDir)) {
    if (-not (Test-Path $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-OK "Erstellt: $dir"
        } catch {
            Exit-Error "Kann Verzeichnis nicht erstellen: $dir`nFehler: $($_.Exception.Message)"
        }
    } else {
        Write-OK "Verzeichnis OK: $dir"
    }
}

$sshDir   = Join-Path $env:USERPROFILE ".ssh"
$gitconfig = Join-Path $env:USERPROFILE ".gitconfig"
if (Test-Path $sshDir)    { Write-OK "SSH-Dir: $sshDir (wird eingebunden)" }
else                      { Write-WARN "SSH-Dir nicht gefunden: $sshDir (kein Mount)" }
if (Test-Path $gitconfig) { Write-OK ".gitconfig: gefunden (wird eingebunden)" }
else                      { Write-WARN ".gitconfig nicht gefunden: $gitconfig" }

# Docker-Argumente aufbauen
$dockerArgs = @(
    "-it", "--rm",
    "--name", $containerName,
    "-v", "$(ConvertTo-DockerPath $workspacePath):/workspace",
    "-v", "$(ConvertTo-DockerPath $claudeDir):/workspace/.claude",
    "-w", "/workspace"
)

# Bindings aus Bindings.md
$bindingsFile = Join-Path $ScriptDir "Bindings.md"
if (Test-Path $bindingsFile) {
    Write-INFO "Bindings.md wird ausgewertet..."
    $bindCount     = 0
    $scriptDirFull = [System.IO.Path]::GetFullPath($ScriptDir)
    $sep           = [System.IO.Path]::DirectorySeparatorChar
    $blockedCPaths = @('/workspace', '/workspace/.claude')
    Get-Content $bindingsFile -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line -match '^#') { return }
        if ($line -match '^([^\s=]+)=([^\s]+)$') {
            $hostPart      = $Matches[1]
            $containerPart = $Matches[2]

            # Container-Pfad: muss /workspace/<sub> sein — kein Ueberschreiben der Haupt-Mounts
            if ($containerPart -in $blockedCPaths -or -not $containerPart.StartsWith('/workspace/')) {
                Write-WARN "Binding '$line' uebersprungen: '$containerPart' nicht erlaubt (muss /workspace/<sub> sein, z.B. /workspace/mein-projekt)"
                return
            }

            # Host-Pfad: Path-Traversal verhindern — muss innerhalb Projektverzeichnis liegen
            try {
                $canonicalized = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir $hostPart))
                $inProject     = $canonicalized.StartsWith($scriptDirFull + $sep) -or ($canonicalized -eq $scriptDirFull)
                if (-not $inProject) {
                    Write-WARN "Binding '$line' uebersprungen: Host-Pfad liegt ausserhalb des Projektverzeichnisses"
                    return
                }
            } catch {
                Write-WARN "Binding '$line' uebersprungen: Pfad konnte nicht aufgeloest werden"
                return
            }

            if (Test-Path $canonicalized) {
                $dockerArgs += "-v"
                $dockerArgs += "$(ConvertTo-DockerPath $canonicalized):${containerPart}"
                Write-OK "Mount: $canonicalized => $containerPart"
                $bindCount++
            } else {
                Write-WARN "Binding-Pfad nicht gefunden (uebersprungen): $canonicalized"
            }
        } else {
            Write-WARN "Ungueltige Binding-Zeile (Format: hostpfad=/containerpfad): '$line'"
        }
    }
    Write-OK "$bindCount Bindings aktiv"
}

# SSH + Git — HOME=/workspace, daher in /workspace/.ssh und /workspace/.gitconfig
if (Test-Path $sshDir)    { $dockerArgs += @("-v", "$(ConvertTo-DockerPath $sshDir):/workspace/.ssh:ro") }
if (Test-Path $gitconfig) { $dockerArgs += @("-v", "$(ConvertTo-DockerPath $gitconfig):/workspace/.gitconfig:ro") }

# Umgebungsvariablen
if ($baseUrl) { $dockerArgs += @("-e", "ANTHROPIC_BASE_URL=$baseUrl") }
$dockerArgs += @(
    "-e", "ANTHROPIC_API_KEY=$token",
    "-e", "HOME=/workspace",
    "-e", "TERM=xterm-256color"
)

if ($Mode -eq "ollama") {
    $dockerArgs += @("--add-host", "host.docker.internal:host-gateway")
}

# Claude-Argumente
$claudeArgs = @()
if ($Model) { $claudeArgs += @("--model", $Model) }
if ($yolo) { $claudeArgs += "--dangerously-skip-permissions" }

# Start-Zusammenfassung
Write-Host ""
Write-Host "  ════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Provider  : $Mode" -ForegroundColor White
Write-Host "  URL       : $(if ($baseUrl) { $baseUrl } else { '(direkte Anthropic API)' })" -ForegroundColor White
Write-Host "  Modell    : $Model" -ForegroundColor White
Write-Host "  Yolo      : $([bool]$yolo)" -ForegroundColor White
Write-Host "  Container : $containerName" -ForegroundColor White
Write-Host "  ════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Starte Claude Code... (Ctrl+C zum Beenden)" -ForegroundColor Green
Write-Host ""

docker run @dockerArgs senity-claude:latest claude @claudeArgs @Rest
$containerExit = $LASTEXITCODE

Write-Host ""
if ($containerExit -eq 0 -or $containerExit -eq 130) {
    Write-OK "Claude Code beendet (Exit: $containerExit)"
} else {
    Write-Host ""
    Write-FAIL "Container beendet mit Exit-Code: $containerExit"
    switch ($containerExit) {
        125 { Write-INFO "Exit 125: Docker konnte Container nicht starten (Image-Problem?)"; break }
        126 { Write-INFO "Exit 126: Entrypoint nicht ausfuehrbar (Dockerfile-Problem?)"; break }
        127 { Write-INFO "Exit 127: Befehl nicht gefunden im Container ('claude' nicht installiert?)"; break }
        1   { Write-INFO "Exit 1: Allgemeiner Fehler - moeglich: falscher API-Key, falsche URL, Auth-Fehler"; break }
        default { Write-INFO "Unbekannter Exit-Code. Bitte Container-Logs pruefen: docker logs $containerName" }
    }
    Write-Host ""
    Write-INFO "Debug-Tipp: docker run --rm senity-claude:latest claude --version"
    Write-INFO "Auth-Tipp : Proxy-Key in .env korrekt? (UUID-Format erwartet)"
}
Write-Host ""
exit $containerExit
