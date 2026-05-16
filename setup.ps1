# ══════════════════════════════════════════════════════════════
# setup.ps1 — Senity Workspace Setup (Windows)
#
# 1. Docker Desktop pruefen + auto-install
# 2. Docker Image bauen
# 3. Desktop-Verknuepfung erstellen
# 4. Bindings.md pruefen/erstellen
# 5. Modell + Yolo waehlen (Provider ist fix: Senity Chat Proxy)
# 6. Container starten (mit config mount)
# ══════════════════════════════════════════════════════════════
param(
    [switch]$NoInteractive,
    [string]$Model,
    [switch]$Yolo,
    [switch]$NoYolo,
    [string]$BindingsFile
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Hilfsfunktionen ──
function Write-Step {
    param([int]$Num, [string]$Text)
    Write-Host ""
    Write-Host "  [$Num/6] $Text..." -ForegroundColor Cyan
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ══════════════════════════════════════════════════════════════
# [1/6] Docker Desktop pruefen + installieren
# ══════════════════════════════════════════════════════════════
Write-Step 1 "Docker Desktop pruefen"

$dockerExists = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerExists) {
    Write-Host ""
    Write-Host "  Docker Desktop nicht gefunden." -ForegroundColor Yellow
    if ($NoInteractive) {
        Write-Host "  Non-interactive: Docker muss installiert sein." -ForegroundColor Red
        exit 1
    }

    $install = Read-Host "  Docker Desktop jetzt installieren? (j/N)"
    if ($install -eq "j" -or $install -eq "J") {
        Write-Host ""
        Write-Host "  Installation starte..." -ForegroundColor Green

        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Host "  [winget] Docker.DockerDesktop installieren..." -ForegroundColor Yellow
            $proc = Start-Process -FilePath "winget" -ArgumentList "install --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements" -Wait -NoNewWindow -PassThru
            if ($proc.ExitCode -eq 0) {
                Write-Host "  Docker Desktop installiert. Bitte neu starten." -ForegroundColor Green
                Write-Host "  Nach dem Neustart: .\setup.bat erneut ausfuehren." -ForegroundColor Yellow
                exit 0
            }
        }

        Write-Host ""
        Write-Host "  Bitte manuell installieren:" -ForegroundColor Yellow
        Write-Host "  https://docs.docker.com/desktop/install/windows-install/"
        Write-Host ""
        Write-Host "  Oder per winget: winget install Docker.DockerDesktop"
        Write-Host ""
        $continue = Read-Host "  Installation abgeschlossen? (j/N)"
        if ($continue -ne "j" -and $continue -ne "J") {
            exit 1
        }

        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Host "  Docker immer noch nicht gefunden." -ForegroundColor Red
            exit 1
        }
    } else {
        exit 1
    }
}

$dockerVersion = docker --version
Write-Host "  Docker: $dockerVersion" -ForegroundColor Green

# ══════════════════════════════════════════════════════════════
# [2/6] Docker Image bauen
# ══════════════════════════════════════════════════════════════
Write-Step 2 "Docker Image bauen"

docker build -t senity-claude:latest "$ScriptDir"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  FEHLER: Image-Build fehlgeschlagen." -ForegroundColor Red
    exit 1
}
Write-Host "  Image gebaut: senity-claude:latest" -ForegroundColor Green

# ══════════════════════════════════════════════════════════════
# [3/6] Desktop-Verknüpfung erstellen
# ══════════════════════════════════════════════════════════════
Write-Step 3 "Desktop-Verknüpfung"

$logoPath = Join-Path $ScriptDir "logo.ico"
$batPath = Join-Path $ScriptDir "claude-msh.bat"
$createShortcut = $false

if (Test-Path $logoPath -ErrorAction SilentlyContinue) {
    if ($NoInteractive) {
        $createShortcut = $true
    } else {
        $short = Read-Host "  Desktop-Verknüpfung erstellen? (j/N)"
        if ($short -eq "j" -or $short -eq "J") {
            $createShortcut = $true
        }
    }
}

if ($createShortcut) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $desktop = [Environment]::GetFolderPath("Desktop")
        $linkPath = Join-Path $desktop "Senity Workspace.lnk"

        $link = $shell.CreateShortcut($linkPath)
        $link.TargetPath = "pwsh.exe"
        $link.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $ScriptDir 'claude-senity.ps1')`""
        $link.WorkingDirectory = $ScriptDir
        if (Test-Path $logoPath) {
            $link.IconLocation = $logoPath
        }
        $link.Save()

        Write-Host "  Verknüpfung erstellt: $linkPath" -ForegroundColor Green
    } catch {
        Write-Host "  Hinweis: Shortcut konnte nicht erstellt werden: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ══════════════════════════════════════════════════════════════
# [4/6] Bindings.md prüfen/erstellen
# ══════════════════════════════════════════════════════════════
Write-Step 4 "Mount-Pfade"

$bindingsFile = $BindingsFile
if (-not $bindingsFile) {
    $bindingsFile = Join-Path $ScriptDir "Bindings.md"
}

$hasMounts = $false
if (Test-Path $bindingsFile) {
    $activeLines = Get-Content $bindingsFile | Where-Object {
        $line = $_.Trim()
        $line -ne '' -and $line -notmatch '^#'
    }
    if ($activeLines) {
        $hasMounts = $true
        Write-Host "  Bindings.md gefunden mit $($activeLines.Count) Pfad/enge" -ForegroundColor Green
        foreach ($l in $activeLines) { Write-Host "    $l" -ForegroundColor DarkGray }
    }
}

if (-not $hasMounts) {
    Write-Host ""
    Write-Host "  Hinweis: Bindings.md existiert nicht oder hat keine Mount-Pfade." -ForegroundColor Yellow
    Write-Host "  Default: ./workspace wird eingebunden."
    Write-Host ""
    if (-not $NoInteractive) {
        $edit = Read-Host "  Pfade bearbeiten? (j/N)"
        if ($edit -eq "j" -or $edit -eq "J") {
            $content = @"
# Senity Workspace — Mount-Pfade
# Format: <host-path>=<container-path>
# Kommentare beginnen mit #, leere Zeilen werden ignoriert

./workspace=/workspace
"@
            Set-Content -Path $bindingsFile -Value $content -Encoding UTF8
            Write-Host "  Bindings.md erstellt mit Default-Inhalt." -ForegroundColor Green
        }
    }
}

# ══════════════════════════════════════════════════════════════
# [5/6] Modell + Yolo waehlen (Provider fix: Senity Chat Proxy)
# ══════════════════════════════════════════════════════════════
Write-Step 5 "Modell + Yolo"

# .env lesen
$envFile = Join-Path $ScriptDir ".env"
$envVars = @{}
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line -match '^#') { return }
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

# Credentials: Senity Chat Proxy
$token = $envVars['SENITY_CHAT_PROXY_KEY']
if (-not $token) { $token = $env:SENITY_CHAT_PROXY_KEY }
if (-not $token) {
    if ($NoInteractive) {
        Write-Host "  FEHLER: SENITY_CHAT_PROXY_KEY nicht gesetzt." -ForegroundColor Red
        exit 1
    }
    $token = Read-Host "  Senity Chat Proxy Key eingeben"
    if (-not $token) { exit 1 }
}
$baseUrl = $envVars['SENITY_CHAT_PROXY_URL']
if (-not $baseUrl) { $baseUrl = "https://sdr.senity.ai/api/claude-proxy" }
$defaultModel = "claude-sonnet-4-6"
Write-Host "  Provider: Senity Chat Proxy ($baseUrl)" -ForegroundColor Green

# Modell
if (-not $Model) {
    if ($NoInteractive) {
        $Model = $defaultModel
    } else {
        $Model = Read-Host "  Modell [$defaultModel]"
        if (-not $Model -or $Model -eq "") { $Model = $defaultModel }
    }
}
Write-Host "  Modell: $Model" -ForegroundColor Green

# Yolo
$yolo = $false
if ($Yolo) { $yolo = $true }
if ($NoYolo) { $yolo = $false }

if (-not ($Yolo -or $NoYolo)) {
    if ($NoInteractive) {
        $yolo = $false
    } else {
        $yoloChoice = Read-Host "  Yolo Mode (ungefragte Execution erlauben)? [y/N]"
        $yolo = ($yoloChoice -eq "y" -or $yoloChoice -eq "Y")
    }
}

Write-Host "  Yolo: $([bool]$yolo)" -ForegroundColor Green
if ($yolo) {
    Write-Host "  (Achtung: Claude Code wird ohne Zustimmung ausfuehren)" -ForegroundColor Yellow
}

# ══════════════════════════════════════════════════════════════
# [6/6] Container starten
# ══════════════════════════════════════════════════════════════
Write-Step 6 "Container starten"

$containerName = "senity-workspace-$($env:USERNAME)-$PID"
$workspacePath = Join-Path $ScriptDir "workspace"

if (-not (Test-Path $workspacePath)) {
    New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
    Write-Host "  Workspace-Verzeichnis erstellt: $workspacePath" -ForegroundColor Yellow
}

$claudeDir = Join-Path $ScriptDir ".claude"
if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

$dockerArgs = @(
    "-it", "--rm",
    "--name", $containerName,
    "-v", "${workspacePath}:/workspace",
    "-w", "/workspace"
)

$dockerArgs += "-v"
$dockerArgs += "${claudeDir}:/workspace/.claude"

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
            $resolved = Join-Path $ScriptDir $hostBinding
            if (Test-Path $resolved) {
                $dockerArgs += "-v"
                $dockerArgs += "${resolved}:${containerBinding}"
            }
        }
    }
}

# SSH-Key + Git-Config
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

Write-Host ""
Write-Host "  Provider:  Senity Chat Proxy" -ForegroundColor Cyan
Write-Host "  Modell:    $Model" -ForegroundColor Cyan
Write-Host "  Yolo:      $([bool]$yolo)" -ForegroundColor Cyan
Write-Host "  Container: $containerName" -ForegroundColor Cyan
Write-Host ""

$claudeArgs = @("--model", $Model)
if ($yolo) {
    $claudeArgs += "--dangerously-skip-permissions"
}

docker run @dockerArgs senity-claude:latest @claudeArgs
