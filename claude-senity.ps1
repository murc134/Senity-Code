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
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$AllArgs
)

# Manuelles Argument-Parsing statt dedizierter [switch]-Parameter.
# Grund: PowerShells eigenes Param-Binding wirft "parameter name '' is
# ambiguous", sobald ein leerer String oder ein Unix-Style-Token wie
# --yolo (Doppel-Dash) reinkommt. Beides passiert in der Praxis: die
# README/Usage zeigt --yolo, und cmd.exe schickt bei manchen Aufrufen
# leere Tokens via %*. Wir sammeln alle Args via ValueFromRemainingArguments
# ein und mappen sie hier von Hand auf die Switch-/Wert-Variablen.
$Yolo = $false
$NoYolo = $false
$Model = $null
$Rebuild = $false
$CreateShortcut = $false
$UpdateWsl = $false
$Help = $false
$Rest = @()

if ($AllArgs) {
    for ($i = 0; $i -lt $AllArgs.Count; $i++) {
        $a = $AllArgs[$i]
        if ([string]::IsNullOrWhiteSpace($a)) { continue }
        $key = ($a -replace '^--', '-').ToLowerInvariant()
        switch ($key) {
            '-yolo'            { $Yolo = $true }
            '-no-yolo'         { $NoYolo = $true }
            '-noyolo'          { $NoYolo = $true }
            '-model'           {
                $i++
                if ($i -lt $AllArgs.Count) { $Model = $AllArgs[$i] }
            }
            '-rebuild'         { $Rebuild = $true }
            '-create-shortcut' { $CreateShortcut = $true }
            '-createshortcut'  { $CreateShortcut = $true }
            '-update-wsl'      { $UpdateWsl = $true }
            '-updatewsl'       { $UpdateWsl = $true }
            '-help'            { $Help = $true }
            '-h'               { $Help = $true }
            '-?'               { $Help = $true }
            default            { $Rest += $a }
        }
    }
}

$ErrorActionPreference = "Continue"

# ScriptDir ermitteln — mehrere Fallbacks
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = $PWD.Path }

# Kanonische Klon-URL fuer das claude-local Repo (Self-Update + Bootstrap).
# Wird direkt mit Port :2200 angesprochen, damit kein ~/.ssh/config-Alias
# auf der User-Maschine vorausgesetzt wird.
$ClaudeLocalRepoUrl = 'ssh://git@git.senity.ai:2200/senity-admin/senity-claude-code.git'

# Originalargumente fuer einen moeglichen Re-Exec nach Self-Update sichern.
function Get-OriginalLauncherArgs {
    $a = @()
    if ($Yolo)           { $a += '-Yolo' }
    if ($NoYolo)         { $a += '-NoYolo' }
    if ($Model)          { $a += '-Model'; $a += $Model }
    if ($Rebuild)        { $a += '-Rebuild' }
    if ($CreateShortcut) { $a += '-CreateShortcut' }
    if ($UpdateWsl)      { $a += '-UpdateWsl' }
    if ($Help)           { $a += '-Help' }
    if ($Rest)           { $a += $Rest }
    return ,$a
}

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

# Prueft ob das auf dem System verfuegbare wsl.exe die moderne Store-WSL ist.
# Die Inbox-WSL (Windows-Komponente bis ~19041) versteht weder 'wsl --version'
# noch 'wsl --update'. Detection: 'wsl --version' aufrufen. Modern: Exit 0
# und eine Zeile, die "WSL" enthaelt. Inbox: Exit != 0 oder Usage-Output ohne
# "WSL"-Header.
function Test-ModernWSL {
    try {
        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        $proc = Start-Process -FilePath "wsl.exe" -ArgumentList "--version" `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $proc.WaitForExit(10000)) {
            try { $proc.Kill() } catch {}
            Remove-Item $outFile,$errFile -ErrorAction SilentlyContinue
            return $false
        }
        $rc  = $proc.ExitCode
        $out = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue) + "`n" +
               (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
        Remove-Item $outFile,$errFile -ErrorAction SilentlyContinue
        if ($rc -ne 0) { return $false }
        return ($out -match 'WSL\s*-?\s*Version' -or $out -match 'WSL\s*version' -or $out -match 'WSL-Version')
    } catch {
        return $false
    }
}

# Aktiviert die zwei Windows-Optional-Features, die WSL2 zwingend braucht:
# 'Microsoft-Windows-Subsystem-Linux' + 'VirtualMachinePlatform'. Auf
# Windows 10 19045 ist 'wsl --install --no-distribution' bekanntermassen
# kaputt und schaltet diese Features nicht ein — der Store-WSL-Client
# laeuft dann zwar, aber Docker Desktop kommt nicht hoch.
#
# dism.exe ist idempotent: wenn ein Feature bereits aktiv ist, gibt der
# Befehl Exit 0 zurueck und macht nichts. Beide Calls laufen in einem
# einzigen elevated cmd, damit nur ein UAC-Prompt erscheint.
# Rueckgabe: $true wenn dism erfolgreich war (auch bei No-Op).
function Enable-WslFeatures {
    Write-INFO "Aktiviere Windows-Features fuer WSL2 (Microsoft-Windows-Subsystem-Linux + VirtualMachinePlatform)..."
    Write-INFO "Ein UAC-Prompt erscheint. dism.exe laeuft elevated; ein Reboot ist danach noetig."
    $dismCmd = 'dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart && dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart'
    try {
        $proc = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c", $dismCmd `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Write-OK "WSL-Windows-Features aktiviert (dism /enable-feature)."
            return $true
        }
        Write-WARN "dism /enable-feature fehlgeschlagen (ExitCode $($proc.ExitCode))."
        return $false
    } catch {
        Write-WARN "DISM-Aufruf fehlgeschlagen oder UAC abgelehnt: $($_.Exception.Message)"
        return $false
    }
}

# Installiert/aktualisiert die moderne Store-WSL via winget (Paket
# Microsoft.WSL). Loest die Inbox-WSL implizit ab. Braucht UAC; winget
# zeigt den Prompt selbst an. Rueckgabe: $true bei Erfolg.
#
# winget gibt bei 'Paket bereits installiert, kein Upgrade verfuegbar' einen
# Non-Zero-ExitCode zurueck (z.B. -1978335189 = NO_APPLICABLE_UPGRADE),
# obwohl das fuer uns ein Erfolg ist: Microsoft.WSL ist drauf, das Ziel ist
# erreicht. Wir capturen daher die Output und werten die DE/EN-Wortlaute
# als zweites Erfolgskriterium.
function Install-ModernWSL {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-WARN "winget nicht verfuegbar — moderne WSL bitte manuell installieren: https://aka.ms/wsl"
        return $false
    }
    Write-INFO "Installiere moderne WSL via winget (Paket: Microsoft.WSL)..."
    Write-INFO "Ein UAC-Prompt erscheint. Nach Abschluss kann ein Reboot oder Terminal-Neustart noetig sein."
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath "winget" `
            -ArgumentList "install","--id","Microsoft.WSL","-e",
                          "--accept-source-agreements","--accept-package-agreements" `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $rc = $proc.ExitCode
        $outStr = ((Get-Content $outFile -Raw -ErrorAction SilentlyContinue) + "`n" +
                   (Get-Content $errFile -Raw -ErrorAction SilentlyContinue))
        if ($outStr.Trim()) { Write-Host $outStr }

        if ($rc -eq 0) {
            Write-OK "Moderne WSL installiert (Microsoft.WSL)."
            return $true
        }
        # 'Bereits installiert / kein Upgrade verfuegbar' ist fuer uns Erfolg.
        # winget meldet das in DE und EN; wir matchen beide Locales.
        $alreadyInstalled = ($outStr -match 'bereits ein vorhandenes Paket') `
                       -or  ($outStr -match 'keine neueren Paketversionen') `
                       -or  ($outStr -match 'Kein verf.{1,3}gbares Upgrade') `
                       -or  ($outStr -match 'No applicable upgrade') `
                       -or  ($outStr -match 'No newer package versions') `
                       -or  ($outStr -match 'No available upgrade found') `
                       -or  ($outStr -match 'already installed')
        if ($alreadyInstalled) {
            Write-OK "Microsoft.WSL ist bereits installiert (winget: kein Upgrade noetig, ExitCode $rc)."
            return $true
        }
        Write-WARN "winget install Microsoft.WSL fehlgeschlagen (ExitCode $rc)."
        return $false
    } catch {
        Write-WARN "winget-Aufruf fehlgeschlagen: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item $outFile,$errFile -ErrorAction SilentlyContinue
    }
}

# Stellt sicher, dass die moderne Store-WSL2 installiert UND die noetigen
# Windows-Features aktiviert sind (Docker-Desktop-Voraussetzung). Wenn WSL
# ganz fehlt ODER nur die alte Inbox-WSL vorhanden ist, schaltet der
# Launcher zuerst die Optional-Features ('Microsoft-Windows-Subsystem-Linux'
# + 'VirtualMachinePlatform') per dism.exe ein und installiert anschliessend
# Microsoft.WSL via winget. Auf bereits modernen Systemen passiert ohne
# -UpdateWsl nichts (Auto-Update kann laufende Distros killen).
function Ensure-WSL {
    $wslBin = Get-Command wsl -ErrorAction SilentlyContinue
    $needsFix = (-not $wslBin) -or (-not (Test-ModernWSL))

    if ($needsFix) {
        if (-not $wslBin) {
            Write-WARN "WSL nicht im PATH — Windows-Features fehlen oder Store-Client ist nicht installiert."
        } else {
            Write-WARN "Veraltete Inbox-WSL erkannt ($($wslBin.Source))."
            Write-WARN "Diese Version unterstuetzt weder 'wsl --version' noch 'wsl --update' — Docker Desktop wird damit nicht zuverlaessig starten."
        }

        # Zwei-Phasen-Fix:
        # 1) dism.exe schaltet die Optional-Features ein. Notwendig fuer
        #    Windows 10 19045 (dort schaltet 'wsl --install' die Features
        #    NICHT ein, bekannter Bug). Idempotent — schadet auf neueren
        #    Builds nicht, wenn die Features schon aktiv sind.
        # 2) winget zieht die moderne Store-WSL (Paket Microsoft.WSL),
        #    loest die Inbox-Variante ab.
        $featuresOk = Enable-WslFeatures
        $wingetOk   = Install-ModernWSL

        if ($featuresOk -or $wingetOk) {
            Write-WARN "WSL-Setup angestossen. Bitte Windows NEU STARTEN und den Launcher danach erneut aufrufen."
            Write-WARN "Ohne Reboot greift die Feature-Aktivierung nicht und Docker Desktop wird nicht starten."
            exit 0
        }

        Write-WARN "WSL-Setup fehlgeschlagen. Manuell als Admin ausfuehren:"
        Write-WARN "  dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart"
        Write-WARN "  dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart"
        Write-WARN "  winget install --id Microsoft.WSL -e"
        Write-WARN "Danach Windows neu starten."
        return $false
    }

    # Moderne WSL ist installiert. KEIN automatisches 'wsl --update' mehr:
    # das hat in der Praxis laufende Distros (insb. die von Docker Desktop)
    # abrupt beendet und Docker in einen kaputten Zustand gebracht
    # (ERROR_ALREADY_EXISTS beim Re-Import). Wer den Kernel aktualisieren
    # will, ruft den Launcher einmalig mit '-UpdateWsl' auf.
    if (-not $UpdateWsl) {
        Write-DBG "WSL-Update uebersprungen (nutze -UpdateWsl zum Erzwingen)"
        return $true
    }
    Write-INFO "Aktualisiere WSL-Kernel ('wsl --update', max. 120s)..."
    Write-WARN "Docker Desktop sollte vorher beendet sein, sonst kann die Distro abrupt sterben."
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $proc = Start-Process -FilePath "wsl.exe" -ArgumentList "--update" -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $proc.WaitForExit(120000)) {
        try { $proc.Kill() } catch {}
        Write-WARN "wsl --update Timeout nach 120s, abgebrochen"
    } else {
        Write-OK "WSL-Update durchgelaufen"
    }
    Remove-Item $outFile,$errFile -ErrorAction SilentlyContinue
    return $true
}

# Stellt sicher, dass git auf dem Host vorhanden ist (Repo-Setup + Self-Update
# brauchen es; im Container ist git ohnehin im Image).
function Ensure-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) { return $true }
    Write-WARN "git nicht gefunden — Installationsversuch via winget..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Git.Git -e --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        # PATH aus der Registry neu laden + Git-Standardpfade explizit anhaengen
        # (winget kehrt teils zurueck, bevor der Registry-PATH geschrieben ist).
        $env:Path = (@(
            [System.Environment]::GetEnvironmentVariable('Path','Machine'),
            [System.Environment]::GetEnvironmentVariable('Path','User'),
            "$env:ProgramFiles\Git\cmd",
            "$env:LOCALAPPDATA\Programs\Git\cmd"
        ) | Where-Object { $_ }) -join ';'
    } else {
        Write-WARN "winget nicht verfuegbar — git manuell installieren: https://git-scm.com/download/win"
    }
    if (Get-Command git -ErrorAction SilentlyContinue) { Write-OK "git installiert"; return $true }
    Write-WARN "git weiterhin nicht verfuegbar — Repo-Setup wird uebersprungen."
    return $false
}

# Stellt sicher, dass Docker Desktop auf dem Host installiert ist.
# Wird VOR Phase [3/6] definiert und dort aufgerufen, wenn `docker` fehlt.
# Hinweis: Docker Desktop benoetigt UAC-Elevation und ggf. einen Reboot
# (WSL2-Aktivierung). winget kuemmert sich um die UAC-Anforderung.
function Ensure-DockerDesktop {
    if (Get-Command docker -ErrorAction SilentlyContinue) { return $true }
    Write-WARN "Docker-CLI nicht gefunden. Installationsversuch via winget..."
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-WARN "winget nicht verfuegbar. Docker Desktop manuell installieren: https://docs.docker.com/desktop/install/windows-install/"
        return $false
    }
    Write-INFO "Installiere Docker Desktop (UAC-Bestaetigung erforderlich)..."
    winget install --id Docker.DockerDesktop -e --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    # PATH neu laden + Docker-Standardpfad explizit anhaengen.
    $env:Path = (@(
        [System.Environment]::GetEnvironmentVariable('Path','Machine'),
        [System.Environment]::GetEnvironmentVariable('Path','User'),
        "$env:ProgramFiles\Docker\Docker\resources\bin"
    ) | Where-Object { $_ }) -join ';'
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-OK "Docker Desktop installiert."
        Write-WARN "Falls Docker beim ersten Start einen Reboot anfordert, bitte neu starten und Launcher erneut aufrufen."
        return $true
    }
    Write-WARN "Docker weiterhin nicht verfuegbar. Eventuell ist ein Reboot noetig oder die Installation laeuft im Hintergrund."
    return $false
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
        $req.Timeout       = 45000
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

# ── Helper: Deploy-Key on-demand dekodieren ──
# Wird sowohl vom Self-Update (oben) als auch vom Repo-Setup (Phase [4/6])
# verwendet. Gibt den Pfad zur dekodierten Key-Datei zurueck oder $null.
function Get-DeployKeyFile {
    param([string]$KeyName, [string]$ScriptDir)
    $sharedEnv = Join-Path $ScriptDir ".env.shared"
    if (-not (Test-Path $sharedEnv)) { return $null }
    $keyDir = Join-Path $ScriptDir ".deploy-keys"
    if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
    $kf = Join-Path $keyDir $KeyName
    if (Test-Path $kf) { return $kf }
    foreach ($line in (Get-Content $sharedEnv -Encoding UTF8)) {
        $l = $line.Trim()
        if ($l -eq '' -or $l -match '^#') { continue }
        if ($l -match "^$([regex]::Escape($KeyName))_B64=(.+)$") {
            try {
                [System.IO.File]::WriteAllBytes($kf, [Convert]::FromBase64String($Matches[1]))
                icacls $kf /inheritance:r /grant:r "$($env:USERNAME):F" 2>&1 | Out-Null
                return $kf
            } catch {
                if (Test-Path $kf) { Remove-Item $kf -Force -ErrorAction SilentlyContinue }
                return $null
            }
        }
    }
    return $null
}

# ── Self-Update / Bootstrap des Launcher-Repos ──
# Zieht VOR allem anderen die neueste Version des claude-local-Repos
# (oder klont es initial, wenn das ScriptDir noch kein Git-Repo ist).
# Bei HEAD-Aenderung wird die neue Version per Re-Exec gestartet.
function Invoke-LauncherSelfUpdate {
    param([string]$ScriptDir, [string]$RepoUrl)

    if ($env:SENITY_SELF_UPDATE_DONE -eq '1') {
        Write-DBG "Self-Update bereits gelaufen, ueberspringe"
        return
    }

    if (-not (Ensure-Git)) {
        Write-WARN "git fehlt — Launcher-Self-Update uebersprungen."
        return
    }

    # Key-Reihenfolge: erst ein spezifischer claude-local-Key (falls je hinzu-
    # gefuegt), dann der senity-workspace-Key (gleicher Git-Server :2200,
    # vermutlich auf beiden Repos als Deploy-Key registriert), dann ~/.ssh.
    $keyCandidates = @()
    foreach ($k in @('claude-local','senity-workspace')) {
        $kf = Get-DeployKeyFile -KeyName $k -ScriptDir $ScriptDir
        if ($kf) { $keyCandidates += $kf }
    }

    $sshCmds = @()
    foreach ($kf in $keyCandidates) {
        $sshCmds += "ssh -i `"$kf`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    }
    $sshCmds += "ssh -o StrictHostKeyChecking=accept-new"

    if (Test-Path (Join-Path $ScriptDir '.git')) {
        Write-INFO "Pruefe auf neue Launcher-Version (git pull)..."
        $oldHead = (& git -C $ScriptDir rev-parse HEAD 2>$null)
        if ($oldHead) { $oldHead = $oldHead.Trim() }
        $pulled = $false
        foreach ($cmd in $sshCmds) {
            $env:GIT_SSH_COMMAND = $cmd
            & git -C $ScriptDir pull --ff-only --quiet 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $pulled = $true; break }
        }
        $env:GIT_SSH_COMMAND = $null
        if (-not $pulled) {
            Write-WARN "Launcher-Self-Update fehlgeschlagen — bestehende Version wird genutzt."
            return
        }
        $newHead = (& git -C $ScriptDir rev-parse HEAD 2>$null)
        if ($newHead) { $newHead = $newHead.Trim() }
        if ($newHead -and $oldHead -and $newHead -ne $oldHead) {
            $shortOld = $oldHead.Substring(0, [Math]::Min(7,$oldHead.Length))
            $shortNew = $newHead.Substring(0, [Math]::Min(7,$newHead.Length))
            Write-OK "Launcher aktualisiert ($shortOld -> $shortNew). Re-Start mit neuer Version..."
            $env:SENITY_SELF_UPDATE_DONE = '1'
            $exeArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath) + (Get-OriginalLauncherArgs)
            & pwsh @exeArgs
            exit $LASTEXITCODE
        }
        Write-OK "Launcher ist aktuell"
        return
    }

    # ScriptDir ist kein Git-Repo -> Bootstrap.
    Write-INFO "Launcher-Verzeichnis ist kein Git-Repo — initialer Bootstrap"
    Write-DBG "Klon-URL: $RepoUrl"
    Push-Location $ScriptDir
    try {
        & git init --quiet 2>&1 | Out-Null
        & git remote remove origin 2>$null | Out-Null
        & git remote add origin $RepoUrl 2>&1 | Out-Null
        $fetched = $false
        foreach ($cmd in $sshCmds) {
            $env:GIT_SSH_COMMAND = $cmd
            & git fetch --quiet origin main 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $fetched = $true; break }
        }
        $env:GIT_SSH_COMMAND = $null
        if (-not $fetched) {
            Write-WARN "Bootstrap-Fetch fehlgeschlagen — Launcher laeuft mit dem aktuellen Stand weiter."
            $dotGit = Join-Path $ScriptDir '.git'
            if (Test-Path $dotGit) { Remove-Item $dotGit -Recurse -Force -ErrorAction SilentlyContinue }
            return
        }
        & git checkout -fB main origin/main 2>&1 | Out-Null
        & git reset --hard origin/main 2>&1 | Out-Null
        $head = (& git rev-parse --short HEAD 2>$null)
        if ($head) { $head = $head.Trim() }
        Write-OK "Launcher-Repo initialisiert (HEAD=$head). Re-Start mit verifizierter Version..."
        $env:SENITY_SELF_UPDATE_DONE = '1'
        $exeArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath) + (Get-OriginalLauncherArgs)
        & pwsh @exeArgs
        exit $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

# ── Banner (ALLERERSTE Ausgabe) ──
# Launcher-Phase: Logo bewusst weiss (neutraler Setup-Look). Die farbige
# Variante mit pink-Akzent erscheint erst beim Claude-Code-Start im Container
# (docker-entrypoint.sh) -- das markiert visuell den Uebergang Host -> Senity.
Write-Host ""
Write-Host "   ███████╗███████╗███╗   ██╗██╗████████╗██╗   ██╗" -ForegroundColor White
Write-Host "   ██╔════╝██╔════╝████╗  ██║██║╚══██╔══╝╚██╗ ██╔╝" -ForegroundColor White
Write-Host "   ███████╗█████╗  ██╔██╗ ██║██║   ██║    ╚████╔╝ " -ForegroundColor White
Write-Host "   ╚════██║██╔══╝  ██║╚██╗██║██║   ██║     ╚██╔╝  " -ForegroundColor White
Write-Host "   ███████║███████╗██║ ╚████║██║   ██║      ██║   ●" -ForegroundColor White
Write-Host "   ╚══════╝╚══════╝╚═╝  ╚═══╝╚═╝   ╚═╝      ╚═╝   " -ForegroundColor White
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
    Write-Host "    --update-wsl       'wsl --update' einmalig erzwingen (Docker vorher beenden!)" -ForegroundColor White
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
# Launcher-Self-Update / Bootstrap (vor allem anderen Setup)
# Holt die neueste Version des claude-local-Repos. Wenn das ScriptDir
# noch kein Git-Repo ist (Marco-Fall: Files manuell kopiert), wird es
# initial geklont. Bei HEAD-Aenderung Re-Exec mit der neuen Version.
# ══════════════════════════════════════════════════════════════
Write-Sep
Write-INFO "Launcher-Update pruefen..."
Invoke-LauncherSelfUpdate -ScriptDir $ScriptDir -RepoUrl $ClaudeLocalRepoUrl

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
        # Erstmalige Eingabe (oder nach explizitem Verwurf)
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

    # status=0 = Netzwerkfehler (Timeout/DNS/ConnectFailure). Key NICHT verwerfen,
    # User fragen ob trotzdem gestartet werden soll. Bei echtem Auth-Fehler
    # (401/403/404) Key verwerfen und neuen abfragen.
    $networkError = ($result.status -eq 0)

    if ($networkError) {
        Write-WARN "Proxy nicht erreichbar oder antwortet zu langsam. Der Key wurde NICHT als ungueltig erkannt."
        $skipResp = (Read-Host "  Trotzdem starten und Key-Check ueberspringen? [Y/n]").Trim().ToLower()
        if ($skipResp -eq '' -or $skipResp -eq 'y' -or $skipResp -eq 'j' -or $skipResp -eq 'yes' -or $skipResp -eq 'ja') {
            Write-WARN "Key-Validierung uebersprungen. Wenn der Key falsch ist, schlaegt die erste Claude-Anfrage fehl."
            $keyOk = $true
            if ($shouldPersist) {
                try {
                    Set-EnvVar -Path $envFile -Key 'SENITY_CHAT_PROXY_URL' -Value $baseUrl
                    Set-EnvVar -Path $envFile -Key 'SENITY_CHAT_PROXY_KEY' -Value $token
                    Write-OK ".env aktualisiert: $envFile"
                } catch {
                    Write-WARN ".env konnte nicht geschrieben werden: $($_.Exception.Message)"
                }
            }
            break
        }
    }

    if ($attempts -ge $maxAttempts) {
        Exit-Error "Nach $maxAttempts Versuchen kein gueltiger Key. Abbruch."
    }
    Write-INFO "Versuch $attempts/$maxAttempts fehlgeschlagen. Bitte Key erneut eingeben."
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

# WSL2 ist Docker-Desktop-Voraussetzung — immer einmal pruefen/updaten.
Ensure-WSL | Out-Null

$dockerBin = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerBin) {
    Ensure-DockerDesktop
    $dockerBin = Get-Command docker -ErrorAction SilentlyContinue
}
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
    # Bei -Rebuild ohne Cache bauen, damit alte CRLF-/Layer-Reste sicher weg sind.
    $buildArgs = @('build', '-t', 'senity-claude:latest')
    if ($Rebuild) { $buildArgs += '--no-cache' }
    $buildArgs += "$ScriptDir"
    docker @buildArgs
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

# Fest hinterlegte Repos (Teil des Setups, nicht ueber .bindings steuerbar).
# Mode: fresh = bei jedem Start loeschen + neu klonen; pull = klonen-oder-pullen.
# Hinweis: senity-workspace ist KEIN Managed Repo — der Pfad wird interaktiv
# beim Erst-Start abgefragt (Ensure-SenityWorkspace), damit Nutzer einen
# bereits vorhandenen lokalen Workspace mounten koennen statt ihn neben den
# eigenen zu klonen.
$ManagedRepos = @(
    @{ Key='claude-skills';    Url='git@github.com:murc134/Claude-Skills.git';            Dir='workspace/.claude/skills/intern';   Mode='fresh' }
    @{ Key='claude-commands';  Url='git@github.com:murc134/Claude-Commands.git';          Dir='workspace/.claude/commands/intern'; Mode='fresh' }
    @{ Key='claude-agents';    Url='git@github.com:murc134/Claude-Agents.git';            Dir='workspace/.claude/agents/intern';   Mode='fresh' }
    @{ Key='senity-mcps';      Url='ssh://git@git.senity.ai:2200/senity/senity-mcps.git'; Dir='workspace/.mcp/senity-mcps';        Mode='pull'  }
)
$keyDir = Join-Path $ScriptDir ".deploy-keys"

# Marker fuer den auto-verwalteten Block in .bindings
$ManagedBindBegin = '# >>> SENITY-VERWALTET (auto-generiert vom Repo-Setup) >>>'
$ManagedBindEnd   = '# <<< SENITY-VERWALTET <<<'

# Marker fuer den interaktiv konfigurierten senity-workspace-Block in .bindings.
# Wird von Ensure-SenityWorkspace geschrieben (einmalig beim Erst-Start oder
# bei verlorenem Host-Pfad). Eigene Eintraege ausserhalb der Marker bleiben.
$WorkspaceBindBegin     = '# >>> SENITY-WORKSPACE (interaktiv konfiguriert) >>>'
$WorkspaceBindEnd       = '# <<< SENITY-WORKSPACE <<<'
$WorkspaceContainerPath = '/workspace/projects/senity-workspace'
$WorkspaceRepoUrl       = 'ssh://git@git.senity.ai:2200/senity/senity-workspace.git'

# Repo-Mounts als auto-verwalteten Block in .bindings schreiben/aktualisieren.
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
        '# Auto-generiert vom Repo-Setup, Aenderungen hier werden bei jedem',
        '# Start ueberschrieben. Enthaelt die Mounts fuer die intern/private',
        '# .claude-Quellen. Der senity-workspace-Mount steht in einem eigenen',
        '# Block (# >>> SENITY-WORKSPACE >>>), interaktiv konfiguriert.')
    foreach ($sub in @('skills','commands','agents')) {
        if (Test-Path (Join-Path $ScriptDir "workspace\.claude\$sub\intern")) {
            $block += "workspace/.claude/$sub/intern=/workspace/.claude/$sub/intern:ro"
        }
        $block += "workspace/.claude/$sub/private=/workspace/.claude/$sub/private:rw"
    }
    # Repo-eigener Skill-Ordner (read-only) des claude-local-Launchers.
    if (Test-Path (Join-Path $ScriptDir "skills")) {
        $block += "skills=/workspace/.claude/skills/senity-workspace:ro"
    }
    # Hinweis: INITIAL_PROMPT.md wird NICHT als File-Bind-Mount gemountet —
    # Docker Desktop macOS (virtiofs) lehnt geschachtelte File-Mounts in den
    # /workspace-Mount ab ("mountpoint is outside of rootfs"). Stattdessen
    # spiegelt Sync-AutostartInitialPrompt die Datei bidirektional zwischen
    # Repo-Root und workspace/projects/autostart/, das ueber den vorhandenen
    # /workspace-Mount sichtbar ist.
    $block += $ManagedBindEnd
    Set-Content -Path $Path -Value ($kept + @('') + $block) -Encoding UTF8
}

# INITIAL_PROMPT.md bidirektional zwischen Repo-Root und der gitignorierten
# Workspace-Kopie spiegeln. Loest das Mac/virtiofs-Problem: statt eines
# geschachtelten File-Bind-Mounts liegt die Datei innerhalb des bestehenden
# /workspace-Mounts und ist damit auf allen Plattformen erreichbar.
# Newer-wins beim Start; Container-Edits propagieren beim naechsten Launcher-Start.
function Sync-AutostartInitialPrompt {
    $root = Join-Path $ScriptDir "INITIAL_PROMPT.md"
    if (-not (Test-Path $root)) { return }
    $autoDir = Join-Path $ScriptDir "workspace\projects\autostart"
    if (-not (Test-Path $autoDir)) {
        New-Item -ItemType Directory -Path $autoDir -Force | Out-Null
    }
    $copy = Join-Path $autoDir "INITIAL_PROMPT.md"
    if (-not (Test-Path $copy)) {
        Copy-Item -LiteralPath $root -Destination $copy -Force
        return
    }
    $rootTime = (Get-Item -LiteralPath $root).LastWriteTimeUtc
    $copyTime = (Get-Item -LiteralPath $copy).LastWriteTimeUtc
    if ($copyTime -gt $rootTime) {
        Copy-Item -LiteralPath $copy -Destination $root -Force
        Write-OK "INITIAL_PROMPT.md: Container-Edit -> Repo-Root uebernommen"
    } elseif ($rootTime -gt $copyTime) {
        Copy-Item -LiteralPath $root -Destination $copy -Force
    }
}

# ══════════════════════════════════════════════════════════════
# senity-workspace: interaktiver Mount-Setup
# Liest den Host-Pfad aus dem WORKSPACE-Block in .bindings. Fehlt der
# Block oder zeigt er auf einen nicht (mehr) existierenden Pfad, wird
# der Nutzer gefragt: bereits installiert (Pfad eingeben) oder klonen.
# Beim Pfad-Modus wird NICHT gepullt (User-Verantwortung).
# ══════════════════════════════════════════════════════════════
function Get-WorkspaceHostFromBindings {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $inBlock = $false
    foreach ($raw in Get-Content $Path -Encoding UTF8) {
        $ln = $raw.TrimEnd("`r")
        if ($ln -eq $WorkspaceBindBegin) { $inBlock = $true; continue }
        if ($ln -eq $WorkspaceBindEnd)   { $inBlock = $false; continue }
        if (-not $inBlock) { continue }
        $t = $ln.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        # Host-Teil greedy bis zum letzten '=', Container-Teil ohne Space/'='.
        if ($t -match '^(.+)=(/[^\s=]+)$') {
            $h = $Matches[1].Trim().Trim('"').Trim("'")
            $c = $Matches[2]
            if ($c -match '^(.+):(ro|rw)$') { $c = $Matches[1] }
            if ($c -eq $WorkspaceContainerPath) { return $h }
        }
    }
    return $null
}

function Resolve-WorkspaceHost {
    param([string]$HostPath)
    if ($HostPath -eq '~') { return $HOME }
    if ($HostPath.StartsWith('~/') -or $HostPath.StartsWith('~\')) {
        return (Join-Path $HOME $HostPath.Substring(2))
    }
    if ([System.IO.Path]::IsPathRooted($HostPath)) { return $HostPath }
    return (Join-Path $ScriptDir $HostPath)
}

function Remove-WorkspaceBlock {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $lines = @(Get-Content $Path -Encoding UTF8)
    $kept = @(); $skip = $false
    foreach ($ln in $lines) {
        if ($ln -eq $WorkspaceBindBegin) { $skip = $true; continue }
        if ($ln -eq $WorkspaceBindEnd)   { $skip = $false; continue }
        if (-not $skip) { $kept += $ln }
    }
    Set-Content -Path $Path -Value $kept -Encoding UTF8
}

function Write-WorkspaceBlock {
    param([string]$Path, [string]$HostPath)
    Remove-WorkspaceBlock -Path $Path
    $existing = @(Get-Content $Path -Encoding UTF8)
    $block = @(
        $WorkspaceBindBegin,
        '# Vom Launcher interaktiv beim Erst-Start gesetzt. Pfad existiert',
        '# nicht mehr -> Block wird verworfen und Dialog erneut gestartet.',
        "${HostPath}=${WorkspaceContainerPath}:rw",
        $WorkspaceBindEnd
    )
    Set-Content -Path $Path -Value ($existing + @('') + $block) -Encoding UTF8
}

function Invoke-WorkspaceClone {
    param([string]$Url, [string]$TargetDir, [string]$KeyFile)
    $parent = Split-Path -Parent $TargetDir
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $cloned = $false
    if (Test-Path $KeyFile) {
        $env:GIT_SSH_COMMAND = "ssh -i `"$KeyFile`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
        git clone --quiet --branch main $Url $TargetDir 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $cloned = $true }
    }
    if (-not $cloned) {
        $env:GIT_SSH_COMMAND = "ssh -o StrictHostKeyChecking=accept-new"
        git clone --quiet --branch main $Url $TargetDir 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $cloned = $true }
    }
    $env:GIT_SSH_COMMAND = $null
    return $cloned
}

function Ensure-SenityWorkspace {
    param([string]$Path)
    $hostPath = Get-WorkspaceHostFromBindings -Path $Path
    if ($hostPath) {
        $resolved = Resolve-WorkspaceHost -HostPath $hostPath
        if (Test-Path $resolved -PathType Container) {
            Write-OK "senity-workspace: $hostPath"
            return
        }
        Write-WARN "senity-workspace-Pfad fehlt: $resolved — Konfiguration wird neu abgefragt."
        Remove-WorkspaceBlock -Path $Path
    }

    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Write-WARN "senity-workspace nicht konfiguriert und kein interaktives Terminal — bitte Launcher interaktiv starten."
        return
    }

    Write-Host ""
    Write-INFO "senity-workspace ist noch nicht konfiguriert."
    $answer = Read-Host "Hast du den senity-workspace bereits lokal installiert? [j/N]"
    if ($answer -match '^(j|J|y|Y)') {
        while ($true) {
            $input = Read-Host "Pfad zum bestehenden senity-workspace"
            $input = $input.Trim().TrimEnd('\','/')
            if (-not $input) {
                Write-WARN "Leerer Pfad — Konfiguration abgebrochen."
                return
            }
            $check = Resolve-WorkspaceHost -HostPath $input
            if (Test-Path $check -PathType Container) {
                Write-WorkspaceBlock -Path $Path -HostPath $input
                Write-OK "senity-workspace eingetragen: $input"
                return
            }
            Write-WARN "Pfad nicht gefunden: $check"
        }
    }

    $answer = Read-Host "Soll ich den senity-workspace nach workspace/projects/senity-workspace klonen? [j/N]"
    if ($answer -match '^(j|J|y|Y)') {
        $rel = 'workspace/projects/senity-workspace'
        $dir = Join-Path $ScriptDir ($rel -replace '/', '\')
        $kf  = Join-Path $keyDir 'senity-workspace'
        if (Test-Path $dir) {
            Write-WARN "Zielverzeichnis existiert bereits — Block wird ohne Klonen eingetragen."
            Write-WorkspaceBlock -Path $Path -HostPath $rel
            Write-OK "senity-workspace eingetragen: $rel"
            return
        }
        Write-INFO "Klone senity-workspace nach $rel..."
        if (Invoke-WorkspaceClone -Url $WorkspaceRepoUrl -TargetDir $dir -KeyFile $kf) {
            Write-WorkspaceBlock -Path $Path -HostPath $rel
            Write-OK "senity-workspace geklont und eingetragen: $rel"
        } else {
            Write-WARN "Klonen fehlgeschlagen (Deploy-Key evtl. nicht registriert, kein ~/.ssh-Zugang)."
        }
    } else {
        Write-WARN "senity-workspace bleibt unkonfiguriert — Container startet ohne Workspace-Mount."
    }
}

# Ensure-Git ist oben im File definiert (wird vom Self-Update bereits gebraucht).

$null = Ensure-Git
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
            # fresh: erst in ein Temp-Verzeichnis klonen, dann atomar tauschen —
            # so bleibt der vorherige Stand bei fehlgeschlagenem Clone erhalten.
            $cloneTarget = $dir
            if ($repo.Mode -eq 'fresh') {
                Write-INFO "Repo frisch klonen: $($repo.Dir)"
                $cloneTarget = "$dir.tmp.$PID"
                if (Test-Path $cloneTarget) { Remove-Item $cloneTarget -Recurse -Force -ErrorAction SilentlyContinue }
            } else {
                Write-INFO "Repo klonen: $($repo.Dir)"
            }
            $parent = Split-Path -Parent $cloneTarget
            if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $cloned = $false
            if ($hasKey) {
                $env:GIT_SSH_COMMAND = "ssh -i `"$kf`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
                git clone --quiet --branch main $repo.Url $cloneTarget 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $cloned = $true }
            }
            if (-not $cloned) {
                $env:GIT_SSH_COMMAND = "ssh -o StrictHostKeyChecking=accept-new"
                git clone --quiet --branch main $repo.Url $cloneTarget 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $cloned = $true }
            }
            $env:GIT_SSH_COMMAND = $null
            if ($cloned) {
                if ($cloneTarget -ne $dir) {
                    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
                    Move-Item $cloneTarget $dir -Force
                }
            } else {
                if ($cloneTarget -ne $dir -and (Test-Path $cloneTarget)) { Remove-Item $cloneTarget -Recurse -Force -ErrorAction SilentlyContinue }
                Write-WARN "Klonen fehlgeschlagen ($($repo.Url)) — vorhandener Stand bleibt erhalten."
                Write-WARN "Deploy-Key evtl. nicht registriert und kein ~/.ssh-Zugang."
            }
        }
    }

    # 3) private/-Verzeichnisse anlegen — Mount-Quelle fuer selbst angelegte
    #    Skills/Commands/Agents. Die Mounts kommen aus .bindings.
    foreach ($sub in @('skills','commands','agents')) {
        $p = Join-Path $ScriptDir "workspace\.claude\$sub\private"
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}
Write-OK "Repo-Setup abgeschlossen"

# ══════════════════════════════════════════════════════════════
# [5/6] Mounts vorbereiten (.bindings, Workspace, .claude)
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

# .bindings ist im Repo enthalten (initial state nach Klon), aber lokale
# Aenderungen sollen git nicht stoeren -> einmalig --skip-worktree setzen.
$bindingsFile = Join-Path $ScriptDir ".bindings"
if (-not (Test-Path $bindingsFile)) {
    # Fallback falls die Datei manuell geloescht wurde.
    $defaultBindings = @"
# Format: <host>=<container>[:ro|:rw]   Excludes: !<glob>
"@
    Set-Content -Path $bindingsFile -Value $defaultBindings -Encoding UTF8
    Write-OK ".bindings angelegt (war nicht vorhanden)"
}
# skip-worktree fuer .bindings setzen, damit lokale Edits nicht im git-status
# auftauchen. Idempotent: nur setzen, wenn noch nicht aktiv.
if (Get-Command git -ErrorAction SilentlyContinue) {
    & git -C $ScriptDir rev-parse --git-dir *> $null
    if ($LASTEXITCODE -eq 0) {
        $bindingsStatus = (& git -C $ScriptDir ls-files -v -- .bindings 2>$null)
        if ($bindingsStatus -and $bindingsStatus.Substring(0,1) -ne 'S') {
            & git -C $ScriptDir update-index --skip-worktree .bindings 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-OK ".bindings: skip-worktree gesetzt (lokale Edits werden nicht getrackt)"
            }
        }
    }
}

# Repo-Mounts als auto-verwalteten Block in .bindings schreiben/aktualisieren
Update-ManagedBindings -Path $bindingsFile

# INITIAL_PROMPT.md zwischen Repo-Root und workspace/projects/autostart/ syncen
Sync-AutostartInitialPrompt

# senity-workspace-Mount interaktiv setzen (oder ueberspringen falls schon ok)
Ensure-SenityWorkspace -Path $bindingsFile

# Pre-Scan: '!<glob>'-Excludes einsammeln (gelten global fuer alle Mounts).
$excludePatterns = @()
Get-Content $bindingsFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq '' -or $line -match '^#') { return }
    if ($line -match '^!(.+)$') {
        $pat = $Matches[1].Trim()
        if ($pat) { $excludePatterns += $pat }
    }
}
$excludePatterns = @($excludePatterns | Sort-Object -Unique)

# Empty-Stage (leerer Ordner + leere Datei) als Overlay-Quelle fuer Excludes.
$mountStageDir = Join-Path $ScriptDir '.mount-stage'
$emptyDir      = Join-Path $mountStageDir 'empty'
$emptyFile     = Join-Path $mountStageDir 'empty.file'
if ($excludePatterns.Count -gt 0) {
    if (-not (Test-Path $emptyDir))  { New-Item -ItemType Directory -Path $emptyDir  -Force | Out-Null }
    if (-not (Test-Path $emptyFile)) { New-Item -ItemType File      -Path $emptyFile -Force | Out-Null }
    Write-INFO "Excludes aktiv: $($excludePatterns -join ', ')"
}

function Get-BindingOverlayArgs {
    param(
        [string]   $Source,
        [string]   $ContainerBase,
        [string[]] $Patterns,
        [string]   $EmptyDir,
        [string]   $EmptyFile
    )
    $out = @()
    if (-not $Patterns -or $Patterns.Count -eq 0) { return ,$out }
    if (-not (Test-Path $Source -PathType Container)) { return ,$out }
    $base = [System.IO.Path]::GetFullPath($Source)
    $seen = @{}
    foreach ($pat in $Patterns) {
        $name = $pat
        $recursive = $false
        if ($pat -match '^\*\*/(.+)$') { $name = $Matches[1]; $recursive = $true }
        # nur reine Basename-Pattern, kein '/' im Restmuster
        if ($name -match '[\\/]') {
            Write-WARN "Exclude '$pat' uebersprungen (nur Basename-Pattern unterstuetzt)"
            continue
        }
        $gci = @{ Path = $base; Filter = $name; Force = $true; ErrorAction = 'SilentlyContinue' }
        if ($recursive) { $gci['Recurse'] = $true }
        Get-ChildItem @gci | ForEach-Object {
            $full = $_.FullName
            if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { return }
            $rel = $full.Substring($base.Length).TrimStart('\','/').Replace('\','/')
            if (-not $rel) { return }
            if ($seen.ContainsKey($rel)) { return }
            $seen[$rel] = $true
            $stageSrc = if ($_.PSIsContainer) { $EmptyDir } else { $EmptyFile }
            $out += '-v'
            $out += "$(ConvertTo-DockerPath $stageSrc):${ContainerBase}/${rel}:ro"
        }
    }
    return ,$out
}

Write-INFO ".bindings wird ausgewertet..."
$bindCount      = 0
$overlayCount   = 0
# Reservierte Container-Mountziele: kollidieren mit den eingebauten Mounts
$reservedCPaths = @('/workspace', '/workspace/.claude')
Get-Content $bindingsFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    # Leerzeilen und '#'-Kommentare ignorieren; '!'-Excludes wurden im Pre-Scan
    # bereits eingesammelt. Alles andere muss eine Mount-Zeile sein.
    if ($line -eq '' -or $line -match '^#') { return }
    if ($line -match '^!') { return }
    # Host-Teil greedy bis zum letzten '=', Container-Teil ohne Space/'='.
    # Erlaubt Host-Pfade mit Leerzeichen (z.B. 'C:\Users\x\Claude Workspace').
    if ($line -match '^(.+)=(/[^\s=]+)$') {
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
            $overlayArgs = Get-BindingOverlayArgs -Source $canonicalized -ContainerBase $containerPart -Patterns $excludePatterns -EmptyDir $emptyDir -EmptyFile $emptyFile
            if ($overlayArgs.Count -gt 0) {
                $dockerArgs += $overlayArgs
                $cnt = [int]($overlayArgs.Count / 2)
                $overlayCount += $cnt
                Write-INFO "  $cnt Exclude-Overlay(s) angehaengt"
            }
        } else {
            Write-WARN "Binding-Pfad nicht gefunden (uebersprungen): $canonicalized"
        }
    } else {
        Write-WARN "Ungueltige Binding-Zeile (Format: hostpfad=/containerpfad): '$line'"
    }
}
if ($overlayCount -gt 0) {
    Write-OK "$bindCount Bindings aktiv, $overlayCount Exclude-Overlay(s)"
} else {
    Write-OK "$bindCount Bindings aktiv"
}

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

# INITIAL_PROMPT.md dynamisch einlesen (bei jedem Start neu, kein Rebuild noetig).
# HTML-Kommentarbloecke <!-- ... --> werden entfernt. Der gereinigte Inhalt wird
# in eine Datei innerhalb /workspace geschrieben; der Entrypoint im Container
# liest sie und uebergibt den Inhalt Claude Code als erste User-Nachricht
# (sichtbar im Chat). Wenn der Nutzer einen eigenen positionalen Prompt
# uebergeben hat ($Rest enthaelt ein Argument ohne "-"-Praefix), wird die
# Datei NICHT geschrieben und Claude startet ohne automatische Nachricht.
$hasUserPrompt = $false
foreach ($r in $Rest) {
    if ($null -ne $r -and "$r".Length -gt 0 -and -not ("$r".StartsWith('-'))) {
        $hasUserPrompt = $true
        break
    }
}

$initialPromptHostFile = Join-Path $workspacePath ".senity-initial-prompt"
# Alt-Stand stets entfernen, damit kein Rest aus letztem Start uebrigbleibt.
if (Test-Path $initialPromptHostFile) {
    Remove-Item -LiteralPath $initialPromptHostFile -Force -ErrorAction SilentlyContinue
}

if (-not $hasUserPrompt) {
    $sysPromptFile = Join-Path $ScriptDir "INITIAL_PROMPT.md"
    if (Test-Path $sysPromptFile) {
        $sysRaw   = Get-Content $sysPromptFile -Raw -Encoding UTF8
        $sysClean = ([regex]::Replace($sysRaw, '(?s)<!--.*?-->', '')).Trim()
        if ($sysClean -ne '') {
            # LF-Zeilenenden erzwingen — wir laufen in Bash im Container.
            $sysCleanLF = $sysClean -replace "`r`n", "`n"
            [System.IO.File]::WriteAllText($initialPromptHostFile, $sysCleanLF, [System.Text.UTF8Encoding]::new($false))
            $dockerArgs += @("-e", "SENITY_INITIAL_PROMPT_FILE=/workspace/.senity-initial-prompt")
            Write-OK "INITIAL_PROMPT.md wird als erste User-Nachricht gesendet"
        }
    }
}

# Hinweis: Der Codex-/Gemini-Login passiert NICHT mehr hier im Launcher.
# Wer Codex/Gemini im Container nutzen will, fuehrt einmalig das separate
# Script aus:  .\codex-gemini-login.bat   (Linux/macOS: ./codex-gemini-login.sh)

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
