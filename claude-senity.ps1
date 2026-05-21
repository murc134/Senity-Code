# ══════════════════════════════════════════════════════════════
# claude-senity.ps1 — Senity Workspace (Container Start)
#
# Usage:
#   .\claude-senity.ps1                    # Senity Chat Proxy (einziger Provider)
#   .\claude-senity.ps1 --yolo             # Yolo Mode (ungefragte Ausfuehrung)
#   .\claude-senity.ps1 --model NAME       # Modell ueberschreiben
#   .\claude-senity.ps1 --create-shortcut  # Desktop-Verknuepfung erstellen
# ══════════════════════════════════════════════════════════════
param(
    [switch]$Yolo,
    [switch]$NoYolo,
    [string]$Model,
    [switch]$Rebuild,
    [switch]$CreateShortcut,
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
function Write-WARN { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Magenta }
function Write-INFO { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor Magenta }
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

# ── .env-Datei lesen/schreiben ──
function Read-EnvFile {
    param([string]$Path)
    $vars = @{}
    if (-not (Test-Path $Path)) { return $vars }
    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line -match '^#') { return }
        if ($line -match '^[^=]+=') {
            $idx = $line.IndexOf('=')
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Trim()
            if ($val -match '^".*"$')      { $val = $val.Substring(1, $val.Length - 2) }
            elseif ($val -match "^'.*'$")  { $val = $val.Substring(1, $val.Length - 2) }
            $vars[$key] = $val
        }
    }
    return $vars
}

function Set-EnvVar {
    param([string]$Path, [string]$Key, [string]$Value)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $lines = @()
    if (Test-Path $Path) { $lines = @(Get-Content $Path -Encoding UTF8) }

    $pattern  = "^\s*$([regex]::Escape($Key))\s*="
    $newLines = @()
    $found    = $false
    foreach ($line in $lines) {
        if ($line -match $pattern) {
            $newLines += "$Key=$Value"
            $found = $true
        } else {
            $newLines += $line
        }
    }
    if (-not $found) {
        if ($newLines.Count -gt 0 -and $newLines[$newLines.Count - 1] -ne '') {
            $newLines += ''
        }
        $newLines += "$Key=$Value"
    }
    Set-Content -Path $Path -Value $newLines -Encoding UTF8
}

# ── Senity-Key gegen Proxy validieren ──
# Rueckgabe: Hashtable @{ valid=$bool; status=<int>; reason=<string> }
function Test-SenityKey {
    param([string]$Url, [string]$Key)
    $endpoint = $Url.TrimEnd('/') + '/v1/messages'
    $body     = '{"model":"claude-3-5-haiku-latest","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
    try {
        $req = [System.Net.HttpWebRequest]::Create($endpoint)
        $req.Method        = 'POST'
        $req.Timeout       = 15000
        $req.ContentType   = 'application/json'
        $req.UserAgent     = 'senity-workspace/1.0'
        $req.Headers.Add('x-api-key', $Key)
        $req.Headers.Add('anthropic-version', '2023-06-01')
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        try {
            $resp = $req.GetResponse()
            $sc   = [int]$resp.StatusCode
            $resp.Close()
            return @{ valid = $true; status = $sc; reason = "HTTP $sc" }
        } catch [System.Net.WebException] {
            $we = $_.Exception
            if ($we.Response) {
                $sc = [int]$we.Response.StatusCode
                $we.Response.Close()
                if ($sc -eq 401 -or $sc -eq 403) {
                    return @{ valid = $false; status = $sc; reason = "Unauthorized (HTTP $sc) - Key ungueltig" }
                } elseif ($sc -eq 404) {
                    return @{ valid = $false; status = $sc; reason = "Endpoint nicht gefunden (HTTP 404) - URL pruefen" }
                } else {
                    # 400, 422, 429, 500 etc.: Auth selbst hat geklappt; akzeptieren
                    return @{ valid = $true; status = $sc; reason = "Auth OK (HTTP $sc)" }
                }
            } else {
                $msg = $we.Message
                $st  = $we.Status
                if ($st -eq [System.Net.WebExceptionStatus]::NameResolutionFailure) {
                    return @{ valid = $false; status = 0; reason = "DNS-Fehler - URL nicht aufloesbar" }
                } elseif ($st -eq [System.Net.WebExceptionStatus]::ConnectFailure) {
                    return @{ valid = $false; status = 0; reason = "Verbindung abgelehnt - Server nicht erreichbar" }
                } elseif ($st -eq [System.Net.WebExceptionStatus]::Timeout) {
                    return @{ valid = $false; status = 0; reason = "Timeout - Server antwortet nicht" }
                } else {
                    return @{ valid = $false; status = 0; reason = "Netzwerkfehler: $msg" }
                }
            }
        }
    } catch {
        return @{ valid = $false; status = 0; reason = "Unerwarteter Fehler: $($_.Exception.Message)" }
    }
}

# ── Banner (ALLERERSTE Ausgabe) ──
Write-Host ""
$esc = [char]27
Write-Host "   $esc[38;2;135;95;175m███████╗███████╗███╗   ██╗██╗████████╗██╗   ██╗$esc[0m"
Write-Host "   $esc[38;2;157;111;200m██╔════╝██╔════╝████╗  ██║██║╚══██╔══╝╚██╗ ██╔╝$esc[0m"
Write-Host "   $esc[38;2;175;135;255m███████╗█████╗  ██╔██╗ ██║██║   ██║    ╚████╔╝ $esc[0m"
Write-Host "   $esc[38;2;201;95;210m╚════██║██╔══╝  ██║╚██╗██║██║   ██║     ╚██╔╝  $esc[0m"
Write-Host "   $esc[38;2;230;46;190m███████║███████╗██║ ╚████║██║   ██║      ██║   $esc[38;2;255;0;175m●$esc[0m"
Write-Host "   $esc[38;2;255;0;175m╚══════╝╚══════╝╚═╝  ╚═══╝╚═╝   ╚═╝      ╚═╝   $esc[0m"
Write-Host ""
Write-DBG "ScriptDir  : $ScriptDir"
Write-DBG "PowerShell : $($PSVersionTable.PSVersion)"
Write-DBG "User       : $($env:USERNAME)  PID: $PID"
Write-DBG "Args       : Yolo=$Yolo Model=$Model"
Write-Host ""

# ── Help ──
if ($Help) {
    Write-Host "  Usage: .\claude-senity.ps1 [OPTIONS]" -ForegroundColor White
    Write-Host ""
    Write-Host "  Provider: Senity Chat Proxy (fest, kein anderer Provider verfuegbar)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Optionen:" -ForegroundColor White
    Write-Host "    --model NAME       Modell ueberschreiben (Default: Senity Proxy)" -ForegroundColor White
    Write-Host "    --yolo             Yolo Mode (Default: an, Container ist isoliert)" -ForegroundColor White
    Write-Host "    --no-yolo          Yolo Mode deaktivieren (Permission-Prompts)" -ForegroundColor White
    Write-Host "    --rebuild          Docker-Image neu bauen (force)" -ForegroundColor White
    Write-Host "    --create-shortcut  Desktop-Verknuepfung erstellen und beenden" -ForegroundColor White
    Write-Host "    --help             Diese Hilfe" -ForegroundColor White
    Write-Host ""
    exit 0
}

# ── Desktop-Shortcut erstellen und beenden ──
if ($CreateShortcut) {
    Write-INFO "Erstelle Desktop-Verknuepfung..."
    try {
        $shell    = New-Object -ComObject WScript.Shell
        $desktop  = [Environment]::GetFolderPath("Desktop")
        $linkPath = Join-Path $desktop "Senity Workspace.lnk"
        $link     = $shell.CreateShortcut($linkPath)
        $link.TargetPath       = "pwsh.exe"
        $link.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $ScriptDir 'claude-senity.ps1')`""
        $link.WorkingDirectory = $ScriptDir
        $logoPath = Join-Path $ScriptDir "logo.ico"
        if (Test-Path $logoPath) { $link.IconLocation = $logoPath }
        $link.Save()
        Write-OK "Verknuepfung erstellt: $linkPath"
    } catch {
        Exit-Error "Shortcut konnte nicht erstellt werden: $($_.Exception.Message)"
    }
    exit 0
}

# ══════════════════════════════════════════════════════════════
# [1/6] TTY pruefen (bei Bedarf in Windows Terminal relaunchen)
# ══════════════════════════════════════════════════════════════
Write-INFO "[1/6] TTY pruefen..."
Write-DBG "IsInputRedirected  : $([System.Console]::IsInputRedirected)"
Write-DBG "IsOutputRedirected : $([System.Console]::IsOutputRedirected)"

$hasTTY = -not [System.Console]::IsInputRedirected
if (-not $hasTTY) {
    Write-WARN "Kein TTY verfuegbar. Interaktive Eingaben (Key-Abfrage) brauchen Terminal."
    $wt = Get-Command wt -ErrorAction SilentlyContinue
    if ($wt) {
        Write-OK "Windows Terminal (wt.exe) gefunden: $($wt.Source)"
        Write-INFO "Starte Senity Workspace in neuem Windows Terminal Fenster..."

        $scriptPath = $MyInvocation.MyCommand.Path
        if (-not $scriptPath) { $scriptPath = Join-Path $ScriptDir "claude-senity.ps1" }

        $flagParts = @()
        if ($Yolo)    { $flagParts += "-Yolo" }
        if ($NoYolo)  { $flagParts += "-NoYolo" }
        if ($Rebuild) { $flagParts += "-Rebuild" }
        if ($Model)   { $flagParts += "-Model '$Model'" }
        foreach ($r in $Rest) { $flagParts += $r }
        $argStr = $flagParts -join " "

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
    Write-Host "  Bitte Ausgabe oben pruefen." -ForegroundColor Magenta
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
        Exit-Error "Kein TTY und Windows Terminal (wt.exe) nicht gefunden.`nBitte direkt aus Windows Terminal starten:`n  1. Windows Terminal oeffnen (Win+R: wt)`n  2. cd '$ScriptDir'`n  3. .\claude-senity.ps1"
    }
} else {
    Write-OK "TTY verfuegbar"
}

# ══════════════════════════════════════════════════════════════
# [2/6] .env laden + Credentials sicherstellen (interaktiv + Validierung)
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[2/6] Credentials (Senity Chat Proxy)..."

$envFile  = Join-Path $ScriptDir ".env"
$envVars  = Read-EnvFile -Path $envFile
$defaultUrl = "https://sdr.senity.ai/api/claude-proxy"

if (Test-Path $envFile) {
    Write-OK ".env gefunden: $envFile ($($envVars.Count) Variablen)"
} else {
    Write-INFO ".env existiert noch nicht — wird beim ersten gueltigen Key angelegt"
}

# URL: aus .env, sonst Env-Var, sonst Default
$baseUrl = $envVars['SENITY_CHAT_PROXY_URL']
if (-not $baseUrl) { $baseUrl = $env:SENITY_CHAT_PROXY_URL }
if (-not $baseUrl) { $baseUrl = $defaultUrl }

# Key: aus .env, sonst Env-Var
$token = $envVars['SENITY_CHAT_PROXY_KEY']
if (-not $token) { $token = $env:SENITY_CHAT_PROXY_KEY }

$keyOk         = $false
$attempts      = 0
$maxAttempts   = 3
$shouldPersist = $false

while (-not $keyOk) {
    if (-not $token) {
        # Erstmalige Eingabe
        Write-Host ""
        Write-INFO "SENITY_CHAT_PROXY_KEY ist nicht gesetzt."
        Write-Host ""
        $urlInput = Read-Host "  Proxy-URL [$defaultUrl]"
        if ($urlInput) { $baseUrl = $urlInput.Trim() } else { $baseUrl = $defaultUrl }

        $token = (Read-Host "  Senity Chat Proxy Key").Trim()
        if (-not $token) {
            Exit-Error "Kein Key eingegeben. Abbruch."
        }
        $shouldPersist = $true
    }

    Write-INFO "Validiere Key gegen $baseUrl ..."
    $result = Test-SenityKey -Url $baseUrl -Key $token
    if ($result.valid) {
        Write-OK "Key valide ($($result.reason))"
        if ($baseUrl -match '^http://' -and $baseUrl -notmatch '^http://(localhost|127\.)') {
            Write-WARN "Proxy-URL nutzt HTTP (unverschluesselt). API-Key wird im Klartext uebertragen!"
            Write-INFO "Empfehlung: HTTPS-Endpunkt verwenden."
        }
        $keyOk = $true

        if ($shouldPersist) {
            try {
                Set-EnvVar -Path $envFile -Key 'SENITY_CHAT_PROXY_URL' -Value $baseUrl
                Set-EnvVar -Path $envFile -Key 'SENITY_CHAT_PROXY_KEY' -Value $token
                Write-OK ".env aktualisiert: $envFile"
            } catch {
                Write-WARN ".env konnte nicht geschrieben werden: $($_.Exception.Message)"
                Write-INFO "Key wird fuer diese Session genutzt, beim naechsten Start aber wieder abgefragt."
            }
        }
        break
    }

    $attempts++
    Write-FAIL "Key-Validierung fehlgeschlagen: $($result.reason)"
    if ($attempts -ge $maxAttempts) {
        Exit-Error "Nach $maxAttempts Versuchen kein gueltiger Key. Abbruch."
    }
    Write-INFO "Versuch $attempts/$maxAttempts fehlgeschlagen. Bitte neuen Key eingeben."
    $token = $null
    $shouldPersist = $true
}

# Modell
$defaultModel      = "qwen3.6:35b"
$defaultModelLabel = "Senity Proxy"
if (-not $Model) { $Model = $defaultModel }
$modelLabel = if ($Model -eq $defaultModel) { "$defaultModelLabel ($defaultModel)" } else { $Model }
Write-OK "Modell: $modelLabel"

# Yolo — Default: an (Container ist isoliert). --no-yolo schaltet aus.
$yolo = $true
if ($NoYolo) { $yolo = $false }
if ($Yolo)   { $yolo = $true }
Write-OK "Yolo-Mode: $([bool]$yolo)$(if ($yolo) { '  (Skip-Permissions aktiv, Container isoliert)' })"

$safeUser = ($env:USERNAME -replace '[^a-zA-Z0-9_.-]', '_').ToLower()

# ══════════════════════════════════════════════════════════════
# [3/6] Docker pruefen
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[3/6] Docker pruefen..."

$dockerBin = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerBin) {
    Exit-Error "Docker-CLI nicht im PATH gefunden.`nDocker Desktop installieren: https://docs.docker.com/desktop/install/windows-install/`nOder per winget: winget install Docker.DockerDesktop"
}
Write-OK "Docker-CLI: $($dockerBin.Source)"
Write-OK "Docker-Version: $(docker --version 2>&1)"

# Docker Desktop Exe
$dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (Test-Path $dockerDesktopExe) {
    Write-OK "Docker Desktop: gefunden"
} else {
    Write-WARN "Docker Desktop nicht unter Standardpfad gefunden — pruefe Daemon direkt"
}

# Docker Daemon
Write-INFO "Pruefe Docker Daemon (docker info)..."
$daemonOutput = docker info 2>&1
$daemonOk = ($LASTEXITCODE -eq 0)

if (-not $daemonOk) {
    $daemonText = $daemonOutput -join "`n"
    Write-WARN "Docker Daemon nicht erreichbar."
    if ($daemonText -match "permission denied|Access is denied|Zugriff verweigert") {
        Exit-Error "Docker: Zugriff verweigert.`nLoesung: Als Administrator ausfuehren oder Benutzer '$($env:USERNAME)' in 'docker-users' aufnehmen."
    }
    if (Test-Path $dockerDesktopExe) {
        Write-INFO "Starte Docker Desktop..."
        Start-Process $dockerDesktopExe
        $timeout = 120; $elapsed = 0; $ready = $false
        while ($elapsed -lt $timeout) {
            Start-Sleep -Seconds 3; $elapsed += 3
            docker info 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            Write-Host "  [WAIT] Warte auf Docker Desktop... ($elapsed/$timeout s)" -ForegroundColor DarkGray
        }
        if (-not $ready) {
            Exit-Error "Docker Desktop nach $timeout Sekunden nicht bereit.`nBitte manuell starten und erneut versuchen."
        }
        Write-OK "Docker Desktop bereit"
    } else {
        Exit-Error "Docker Daemon nicht erreichbar und Docker Desktop nicht gefunden.`nhttps://docs.docker.com/desktop/install/windows-install/"
    }
} else {
    Write-OK "Docker Daemon: bereit"
}

# Image pruefen + ggf. bauen
Write-INFO "Pruefe Docker Image 'senity-claude:latest'..."
$needsBuild = $false
if ($Rebuild) {
    Write-INFO "Force-Rebuild angefordert. Loesche bestehendes Image (falls vorhanden)..."
    docker image rm senity-claude:latest 2>&1 | Out-Null
    $needsBuild = $true
} else {
    docker image inspect senity-claude:latest 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-WARN "Image 'senity-claude:latest' nicht gefunden."
        $needsBuild = $true
    } else {
        $imageCreated = docker image inspect senity-claude:latest --format "{{.Created}}" 2>&1
        Write-OK "Image vorhanden (erstellt: $imageCreated)"
    }
}
if ($needsBuild) {
    $dockerfilePath = Join-Path $ScriptDir "Dockerfile"
    if (-not (Test-Path $dockerfilePath)) {
        Exit-Error "Dockerfile nicht gefunden: $dockerfilePath"
    }
    Write-INFO "Starte Image-Build (kann 2-5 Minuten dauern)..."
    docker build -t senity-claude:latest "$ScriptDir"
    if ($LASTEXITCODE -ne 0) {
        Exit-Error "Image-Build fehlgeschlagen (Exit $LASTEXITCODE)."
    }
    Write-OK "Image gebaut: senity-claude:latest"
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
# [4/6] Verwaltete Repos klonen/pullen (vor dem Container-Start)
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[4/6] Repo-Setup (verwaltete Repos)..."

# Fest hinterlegte Repos (Teil des Setups, nicht ueber Bindings.md steuerbar).
# Mode: fresh = bei jedem Start loeschen + neu klonen; pull = klonen-oder-pullen.
# senity-workspace ist das Arbeits-Repo -> 'pull', sonst waere nicht-gepushte
# Arbeit nach jedem Neustart verloren.
$ManagedRepos = @(
    @{ Key='senity-workspace'; Url='ssh://git@git.senity.ai:2200/senity/senity-workspace.git'; Dir='workspace/senity-workspace';        Mode='pull'  }
    @{ Key='claude-skills';    Url='git@github.com:murc134/Claude-Skills.git';                 Dir='workspace/.claude/skills/intern';   Mode='fresh' }
    @{ Key='claude-commands';  Url='git@github.com:murc134/Claude-Commands.git';               Dir='workspace/.claude/commands/intern'; Mode='fresh' }
    @{ Key='claude-agents';    Url='git@github.com:murc134/Claude-Agents.git';                 Dir='workspace/.claude/agents/intern';   Mode='fresh' }
)
$keyDir = Join-Path $ScriptDir ".deploy-keys"

# Marker fuer den auto-verwalteten Block in Bindings.md
$ManagedBindBegin = '# >>> SENITY-VERWALTET (auto-generiert vom Repo-Setup) >>>'
$ManagedBindEnd   = '# <<< SENITY-VERWALTET <<<'

# Repo-Mounts als auto-verwalteten Block in Bindings.md schreiben/aktualisieren.
# Eigene Eintraege ausserhalb der Marker bleiben unangetastet.
function Update-ManagedBindings {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $lines = @(Get-Content $Path -Encoding UTF8)
    $kept = @(); $skip = $false
    foreach ($ln in $lines) {
        if ($ln -eq $ManagedBindBegin) { $skip = $true; continue }
        if ($ln -eq $ManagedBindEnd)   { $skip = $false; continue }
        if (-not $skip) { $kept += $ln }
    }
    $lastNonEmpty = -1
    for ($k = 0; $k -lt $kept.Count; $k++) { if ($kept[$k].Trim() -ne '') { $lastNonEmpty = $k } }
    if ($lastNonEmpty -ge 0) { $kept = @($kept[0..$lastNonEmpty]) } else { $kept = @() }
    $block = @($ManagedBindBegin,
        '# Auto-generiert vom Repo-Setup — Aenderungen hier werden bei jedem',
        '# Start ueberschrieben. senity-workspace liegt direkt in workspace/',
        '# und ist dadurch bereits unter /workspace/... sichtbar.')
    foreach ($sub in @('skills','commands','agents')) {
        if (Test-Path (Join-Path $ScriptDir "workspace\.claude\$sub\intern")) {
            $block += "workspace/.claude/$sub/intern=/workspace/.claude/$sub/intern:ro"
        }
        $block += "workspace/.claude/$sub/private=/workspace/.claude/$sub/private:rw"
        if (Test-Path (Join-Path $HOME ".claude\$sub")) {
            $block += "~/.claude/$sub=/workspace/.claude/$sub/global:rw"
        }
    }
    $block += $ManagedBindEnd
    Set-Content -Path $Path -Value ($kept + @('') + $block) -Encoding UTF8
}

$gitBin = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitBin) {
    Write-WARN "git nicht gefunden — Repo-Setup uebersprungen."
} else {
    # 1) Deploy-Keys aus .env.shared dekodieren (.deploy-keys/, ACL gesperrt)
    $sharedEnv = Join-Path $ScriptDir ".env.shared"
    if (Test-Path $sharedEnv) {
        if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
        Get-Content $sharedEnv -Encoding UTF8 | ForEach-Object {
            $l = $_.Trim()
            if ($l -eq '' -or $l -match '^#') { return }
            if ($l -match '^([A-Za-z0-9_-]+)_B64=(.+)$') {
                $kn = $Matches[1]; $kb64 = $Matches[2]
                $kf = Join-Path $keyDir $kn
                try {
                    [System.IO.File]::WriteAllBytes($kf, [Convert]::FromBase64String($kb64))
                    icacls $kf /inheritance:r /grant:r "$($env:USERNAME):F" 2>&1 | Out-Null
                    Write-OK "Deploy-Key dekodiert: $kn"
                } catch {
                    Write-WARN "Deploy-Key '$kn' nicht dekodierbar — uebersprungen."
                    if (Test-Path $kf) { Remove-Item $kf -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }

    # 2) Repos klonen / pullen (je nach Mode)
    foreach ($repo in $ManagedRepos) {
        $dir = Join-Path $ScriptDir ($repo.Dir -replace '/', '\')
        $kf  = Join-Path $keyDir $repo.Key
        $hasKey = Test-Path $kf

        if ($repo.Mode -eq 'pull' -and (Test-Path (Join-Path $dir '.git'))) {
            Write-INFO "Repo aktualisieren (pull): $($repo.Dir)"
            if ($hasKey) { $env:GIT_SSH_COMMAND = "ssh -i `"$kf`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" }
            else         { $env:GIT_SSH_COMMAND = "ssh -o StrictHostKeyChecking=accept-new" }
            git -C $dir pull --ff-only --quiet 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $env:GIT_SSH_COMMAND = "ssh -o StrictHostKeyChecking=accept-new"
                git -C $dir pull --ff-only --quiet 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-WARN "Pull fehlgeschlagen ($($repo.Dir)) — vorhandener Stand wird genutzt."
                }
            }
            $env:GIT_SSH_COMMAND = $null
        } else {
            if ($repo.Mode -eq 'fresh') {
                Write-INFO "Repo frisch klonen: $($repo.Dir)"
                if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
            } else {
                Write-INFO "Repo klonen: $($repo.Dir)"
            }
            $parent = Split-Path -Parent $dir
            if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $cloned = $false
            if ($hasKey) {
                $env:GIT_SSH_COMMAND = "ssh -i `"$kf`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
                git clone --quiet --branch main $repo.Url $dir 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $cloned = $true }
            }
            if (-not $cloned) {
                $env:GIT_SSH_COMMAND = "ssh -o StrictHostKeyChecking=accept-new"
                git clone --quiet --branch main $repo.Url $dir 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $cloned = $true }
            }
            $env:GIT_SSH_COMMAND = $null
            if (-not $cloned) {
                Write-WARN "Klonen fehlgeschlagen ($($repo.Url))."
                Write-WARN "Deploy-Key evtl. nicht registriert und kein ~/.ssh-Zugang."
            }
        }
    }

    # 3) private/-Verzeichnisse anlegen — Mount-Quelle fuer selbst angelegte
    #    Skills/Commands/Agents. Die Mounts kommen aus Bindings.md.
    foreach ($sub in @('skills','commands','agents')) {
        $p = Join-Path $ScriptDir "workspace\.claude\$sub\private"
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}
Write-OK "Repo-Setup abgeschlossen"

# ══════════════════════════════════════════════════════════════
# [5/6] Mounts vorbereiten (Bindings.md, Workspace, .claude)
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[5/6] Mounts vorbereiten..."

$containerName = "senity-workspace-$safeUser-$PID"
$workspacePath = Join-Path $ScriptDir "workspace"
$claudeDir     = Join-Path $ScriptDir ".claude"

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

$sshDir    = Join-Path $env:USERPROFILE ".ssh"
$gitconfig = Join-Path $env:USERPROFILE ".gitconfig"
if (Test-Path $sshDir)    { Write-OK "SSH-Dir: $sshDir (wird eingebunden)" }
else                      { Write-WARN "SSH-Dir nicht gefunden: $sshDir (kein Mount)" }
if (Test-Path $gitconfig) { Write-OK ".gitconfig: gefunden (wird eingebunden)" }
else                      { Write-WARN ".gitconfig nicht gefunden: $gitconfig" }

$dockerArgs = @(
    "-it", "--rm",
    "--name", $containerName,
    "-v", "$(ConvertTo-DockerPath $workspacePath):/workspace",
    "-v", "$(ConvertTo-DockerPath $claudeDir):/workspace/.claude",
    "-w", "/workspace"
)

# Bindings.md auto-create
$bindingsFile = Join-Path $ScriptDir "Bindings.md"
if (-not (Test-Path $bindingsFile)) {
    $defaultBindings = @"
# Senity Workspace — Mount-Pfade
# Format: <host-pfad>=<container-pfad>[:ro|:rw]
# Kommentare beginnen mit #, leere Zeilen werden ignoriert
#
# Host-Pfad:      beliebiges Verzeichnis — absolut (C:\Users\...), per ~ (~/projekte/foo)
#                 oder relativ zum Projektverzeichnis (../mein-projekt).
#                 Leerzeichen erlaubt; umschliessende '/" werden abgestreift.
# Container-Pfad: muss unterhalb von /workspace/ liegen (z.B. /workspace/mein-repo).
#                 /workspace selbst und /workspace/.claude sind reserviert.
# Modus:          optionales :ro (nur lesen) oder :rw (lesen+schreiben) am
#                 Container-Pfad. Ohne Angabe: rw.

# Beispiele:
# ~/projekte/mein-repo=/workspace/mein-repo
# C:\Users\ich\code\api=/workspace/api
# ../nachbar-projekt=/workspace/nachbar
# ~/docs/referenz=/workspace/referenz:ro
"@
    Set-Content -Path $bindingsFile -Value $defaultBindings -Encoding UTF8
    Write-OK "Bindings.md angelegt (workspace/ ist bereits eingebunden — eigene Pfade ergaenzen)"
}

# Repo-Mounts als auto-verwalteten Block in Bindings.md schreiben/aktualisieren
Update-ManagedBindings -Path $bindingsFile

Write-INFO "Bindings.md wird ausgewertet..."
$bindCount      = 0
# Reservierte Container-Mountziele: kollidieren mit den eingebauten Mounts
$reservedCPaths = @('/workspace', '/workspace/.claude')
Get-Content $bindingsFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq '' -or $line -match '^#') { return }
    # Host-Teil greedy bis zum letzten '=', Container-Teil ohne Space/'='.
    # Erlaubt Host-Pfade mit Leerzeichen (z.B. 'C:\Users\x\Claude Workspace').
    if ($line -match '^(.+)=([^\s=]+)$') {
        $hostPart      = $Matches[1].Trim().Trim('"').Trim("'")
        $containerPart = $Matches[2]

        # Optionales :ro/:rw-Suffix am Container-Pfad (Default: rw)
        $mountMode = 'rw'
        if ($containerPart -match '^(.+):(ro|rw)$') {
            $containerPart = $Matches[1]
            $mountMode     = $Matches[2]
        }

        # Container-Pfad muss unterhalb von /workspace/ liegen; /workspace und
        # /workspace/.claude sind reserviert (eingebaute Mounts).
        if ($containerPart -in $reservedCPaths -or $containerPart -notmatch '^/workspace/.+') {
            Write-WARN "Binding '$line' uebersprungen: '$containerPart' nicht erlaubt (muss /workspace/<sub> sein, nicht /workspace oder /workspace/.claude)"
            return
        }

        try {
            # ~ expandieren; absolute Pfade direkt, relative relativ zum Projektverzeichnis
            if ($hostPart -eq '~') {
                $hostPart = $HOME
            } elseif ($hostPart.StartsWith('~/') -or $hostPart.StartsWith('~\')) {
                $hostPart = Join-Path $HOME $hostPart.Substring(2)
            }
            if ([System.IO.Path]::IsPathRooted($hostPart)) {
                $canonicalized = [System.IO.Path]::GetFullPath($hostPart)
            } else {
                $canonicalized = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir $hostPart))
            }
        } catch {
            Write-WARN "Binding '$line' uebersprungen: Pfad nicht aufloesbar"
            return
        }

        if (Test-Path $canonicalized) {
            $dockerArgs += "-v"
            $dockerArgs += "$(ConvertTo-DockerPath $canonicalized):${containerPart}:${mountMode}"
            Write-OK "Mount: $canonicalized => $containerPart ($mountMode)"
            $bindCount++
        } else {
            Write-WARN "Binding-Pfad nicht gefunden (uebersprungen): $canonicalized"
        }
    } else {
        Write-WARN "Ungueltige Binding-Zeile (Format: hostpfad=/containerpfad): '$line'"
    }
}
Write-OK "$bindCount Bindings aktiv"

if (Test-Path $sshDir)    { $dockerArgs += @("-v", "$(ConvertTo-DockerPath $sshDir):/workspace/.ssh:ro") }
if (Test-Path $gitconfig) { $dockerArgs += @("-v", "$(ConvertTo-DockerPath $gitconfig):/workspace/.gitconfig:ro") }

$dockerArgs += @(
    "-e", "ANTHROPIC_BASE_URL=$baseUrl",
    "-e", "ANTHROPIC_API_KEY=$token",
    "-e", "HOME=/workspace",
    "-e", "TERM=xterm-256color"
)

$claudeArgs = @()
if ($Model) { $claudeArgs += @("--model", $Model) }
if ($yolo)  { $claudeArgs += "--dangerously-skip-permissions" }

# SYSTEM_PROMPT.md dynamisch einlesen (bei jedem Start neu, kein Rebuild noetig).
# HTML-Kommentarbloecke <!-- ... --> werden entfernt.
$sysPromptFile = Join-Path $ScriptDir "SYSTEM_PROMPT.md"
if (Test-Path $sysPromptFile) {
    $sysRaw   = Get-Content $sysPromptFile -Raw -Encoding UTF8
    $sysClean = ([regex]::Replace($sysRaw, '(?s)<!--.*?-->', '')).Trim()
    if ($sysClean -ne '') {
        $claudeArgs += @("--append-system-prompt", $sysClean)
        Write-OK "System-Prompt aus SYSTEM_PROMPT.md geladen"
    }
}

# ══════════════════════════════════════════════════════════════
# [6/6] Container starten
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "[6/6] Container starten..."

Write-Host ""
Write-Host "  ════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "  Provider  : Senity Chat Proxy" -ForegroundColor White
Write-Host "  URL       : $baseUrl" -ForegroundColor White
Write-Host "  Modell    : $modelLabel" -ForegroundColor White
Write-Host "  Yolo      : $([bool]$yolo)" -ForegroundColor White
Write-Host "  Container : $containerName" -ForegroundColor White
Write-Host "  ════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Starte Claude Code... (Ctrl+C zum Beenden)" -ForegroundColor Green
Write-Host ""

docker run @dockerArgs senity-claude:latest senity-mascot-filter claude @claudeArgs @Rest
$containerExit = $LASTEXITCODE

Write-Host ""
if ($containerExit -eq 0 -or $containerExit -eq 130) {
    Write-OK "Claude Code beendet (Exit: $containerExit)"
} else {
    Write-FAIL "Container beendet mit Exit-Code: $containerExit"
    switch ($containerExit) {
        125 { Write-INFO "Exit 125: Docker konnte Container nicht starten (Image-Problem?)"; break }
        126 { Write-INFO "Exit 126: Entrypoint nicht ausfuehrbar"; break }
        127 { Write-INFO "Exit 127: 'claude' nicht gefunden im Container"; break }
        1   { Write-INFO "Exit 1: Allgemeiner Fehler"; break }
        default { Write-INFO "Unbekannter Exit-Code. Logs: docker logs $containerName" }
    }
}
Write-Host ""
exit $containerExit
