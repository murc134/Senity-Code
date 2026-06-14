#requires -version 5.1
<#
  senity-prereqs.ps1 - Reboot-faehige Voraussetzungs-Installation fuer senity.

  Installiert die zwei reboot-pflichtigen Host-Dependencies in der richtigen
  Reihenfolge mit je einem Neustart dazwischen:

    PHASE 0  WSL2-Features (dism) + moderne Store-WSL (winget Microsoft.WSL)
             -> Reboot
    PHASE 1  Docker Desktop (winget Docker.DockerDesktop)
             -> Reboot
    PHASE 2  Docker-Daemon starten + auf 'docker info' warten, Cleanup
             -> fertig, Hinweis 'senity login'

  Wird normalerweise von der senity-setup.exe (Inno) am Ende der Installation
  gestartet. Nach jedem Reboot setzt sich das Skript ueber HKCU\...\RunOnce
  selbst fort. Der State (aktuelle Phase) liegt in HKCU\Software\Senity\Setup.

  Das Skript self-elevatet beim Start (UAC), damit dism/winget Admin-Rechte
  haben. Nach jedem Reboot erscheint daher genau ein UAC-Prompt.

  Manuell aufrufbar:
    powershell -ExecutionPolicy Bypass -File senity-prereqs.ps1
    powershell -ExecutionPolicy Bypass -File senity-prereqs.ps1 -Unattended
    powershell -ExecutionPolicy Bypass -File senity-prereqs.ps1 -Reset
#>

[CmdletBinding()]
param(
    # Interner Parameter: vom RunOnce-Resume gesetzt. Leer = aus Registry lesen.
    [int]$Phase = -1,
    # Ohne Rueckfrage neu starten (Countdown statt Enter-Prompt).
    [switch]$Unattended,
    # State + RunOnce loeschen und beenden (Wiederholung von vorn ermoeglichen).
    [switch]$Reset
)

$ErrorActionPreference = "Stop"

# ---- Konstanten -------------------------------------------------------------
$RegRoot     = "HKCU:\Software\Senity\Setup"
$RunOnceKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$RunOnceName = "SenityPrereqs"
$LogDir      = Join-Path $env:LOCALAPPDATA "Senity"
$LogFile     = Join-Path $LogDir "setup.log"
$ScriptPath  = $MyInvocation.MyCommand.Path

# ---- Logging ----------------------------------------------------------------
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Line([string]$Msg, [string]$Color, [string]$Level) {
    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[senity-setup] $Msg" -ForegroundColor $Color
    try { Add-Content -Path $LogFile -Value "$stamp [$Level] $Msg" -Encoding UTF8 } catch {}
}
function Write-INFO([string]$M) { Write-Line $M "Cyan"    "INFO" }
function Write-OK  ([string]$M) { Write-Line $M "Green"   "OK"   }
function Write-WARN([string]$M) { Write-Line $M "Yellow"  "WARN" }
function Write-ERR ([string]$M) { Write-Line $M "Red"     "ERR"  }
function Write-STEP([string]$M) { Write-Line $M "Magenta" "STEP" }

# ---- Elevation --------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Startet sich selbst elevated neu und reicht Phase/Unattended durch.
function Invoke-SelfElevate([int]$ForPhase) {
    Write-INFO "Fordere Administrator-Rechte an (UAC)..."
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$ScriptPath`"",
        "-Phase", $ForPhase
    )
    if ($Unattended) { $argList += "-Unattended" }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList $argList -Verb RunAs -ErrorAction Stop | Out-Null
        exit 0
    } catch {
        Write-ERR "UAC abgelehnt oder Elevation fehlgeschlagen. Setup kann ohne Admin-Rechte nicht fortfahren."
        Write-ERR "Bitte das Setup erneut starten und die UAC-Abfrage bestaetigen."
        exit 1
    }
}

# ---- State (Registry) -------------------------------------------------------
function Get-Phase {
    if (-not (Test-Path $RegRoot)) { return 0 }
    $v = (Get-ItemProperty -Path $RegRoot -Name "Phase" -ErrorAction SilentlyContinue).Phase
    if ($null -eq $v) { return 0 }
    return [int]$v
}
function Set-Phase([int]$P) {
    if (-not (Test-Path $RegRoot)) { New-Item -Path $RegRoot -Force | Out-Null }
    Set-ItemProperty -Path $RegRoot -Name "Phase" -Value $P -Type DWord
}
function Set-Resume([int]$NextPhase) {
    # RunOnce ruft beim naechsten Logon dieses Skript erneut auf. RunOnce laeuft
    # NICHT elevated; das Skript self-elevatet dann selbst.
    $pwshExe = (Get-Process -Id $PID).Path
    $cmd = "`"$pwshExe`" -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Phase $NextPhase"
    if ($Unattended) { $cmd += " -Unattended" }
    if (-not (Test-Path $RunOnceKey)) { New-Item -Path $RunOnceKey -Force | Out-Null }
    Set-ItemProperty -Path $RunOnceKey -Name $RunOnceName -Value $cmd
}
function Clear-Resume {
    if (Test-Path $RunOnceKey) {
        Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue
    }
}
function Clear-State {
    Clear-Resume
    if (Test-Path $RegRoot) { Remove-Item -Path $RegRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- Reboot ----------------------------------------------------------------
function Request-Reboot([int]$NextPhase, [string]$Reason) {
    Set-Phase $NextPhase
    Set-Resume $NextPhase
    Write-OK $Reason
    Write-WARN "Ein Neustart ist erforderlich. Das Setup fuehrt sich danach automatisch fort."
    if ($Unattended) {
        $sec = 20
        Write-WARN "Neustart in $sec Sekunden. Esc bricht ab (dann spaeter manuell neu starten)."
        for ($i = $sec; $i -gt 0; $i--) {
            Write-Host "`r  Neustart in $i s ... [Esc = abbrechen]   " -NoNewline -ForegroundColor Yellow
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq "Escape") {
                    Write-Host ""
                    Write-WARN "Neustart abgebrochen. Bitte spaeter manuell neu starten; das Setup laeuft beim naechsten Logon weiter."
                    exit 0
                }
            }
            Start-Sleep -Seconds 1
        }
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "  Druecke ENTER zum sofortigen Neustart." -ForegroundColor Yellow
        Write-Host "  Oder schliesse dieses Fenster und starte spaeter manuell (Setup laeuft beim Logon weiter)." -ForegroundColor Yellow
        [void](Read-Host)
    }
    Write-INFO "Starte Windows neu..."
    Restart-Computer -Force
    exit 0
}

# =============================================================================
#  Wiederverwendete, erprobte WSL/Docker-Logik (aus claude-senity.ps1)
# =============================================================================

# Inbox-WSL (Windows-Komponente bis ~19041) versteht weder 'wsl --version' noch
# 'wsl --update'. Modern: Exit 0 und Output mit "WSL ... Version".
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

# Aktiviert die zwei WSL2-Optional-Features. dism ist idempotent; beide Calls in
# einem cmd, damit nur ein UAC-Prompt erscheint. Wir laufen bereits elevated,
# also direkt cmd /c statt -Verb RunAs.
function Enable-WslFeatures {
    Write-INFO "Aktiviere Windows-Features fuer WSL2 (Microsoft-Windows-Subsystem-Linux + VirtualMachinePlatform)..."
    $dismCmd = 'dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart && dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart'
    try {
        $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $dismCmd `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Write-OK "WSL-Windows-Features aktiviert (dism /enable-feature)."
            return $true
        }
        Write-WARN "dism /enable-feature fehlgeschlagen (ExitCode $($proc.ExitCode))."
        return $false
    } catch {
        Write-WARN "DISM-Aufruf fehlgeschlagen: $($_.Exception.Message)"
        return $false
    }
}

# Installiert/aktualisiert die moderne Store-WSL via winget. winget meldet
# 'bereits installiert' mit Non-Zero-Exit; wir werten DE/EN-Wortlaute als Erfolg.
# Rueckgabe: 'installed' | 'already' | 'failed'.
function Install-ModernWSL {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-WARN "winget nicht verfuegbar - moderne WSL bitte manuell installieren: https://aka.ms/wsl"
        return 'failed'
    }
    Write-INFO "Installiere moderne WSL via winget (Paket: Microsoft.WSL)..."
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
        if ($rc -eq 0) { Write-OK "Moderne WSL installiert (Microsoft.WSL)."; return 'installed' }
        $alreadyInstalled = ($outStr -match 'bereits ein vorhandenes Paket') `
                       -or  ($outStr -match 'keine neueren Paketversionen') `
                       -or  ($outStr -match 'Kein verf.{1,3}gbares Upgrade') `
                       -or  ($outStr -match 'No applicable upgrade') `
                       -or  ($outStr -match 'No newer package versions') `
                       -or  ($outStr -match 'No available upgrade found') `
                       -or  ($outStr -match 'already installed')
        if ($alreadyInstalled) {
            Write-OK "Microsoft.WSL ist bereits installiert (winget: kein Upgrade noetig, ExitCode $rc)."
            return 'already'
        }
        Write-WARN "winget install Microsoft.WSL fehlgeschlagen (ExitCode $rc)."
        return 'failed'
    } catch {
        Write-WARN "winget-Aufruf fehlgeschlagen: $($_.Exception.Message)"
        return 'failed'
    } finally {
        Remove-Item $outFile,$errFile -ErrorAction SilentlyContinue
    }
}

# Installiert Docker Desktop via winget. Rueckgabe: 'installed' | 'already' | 'failed'.
function Install-DockerDesktop {
    if (Get-Command docker -ErrorAction SilentlyContinue) { return 'already' }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-WARN "winget nicht verfuegbar. Docker Desktop manuell installieren: https://docs.docker.com/desktop/install/windows-install/"
        return 'failed'
    }
    Write-INFO "Installiere Docker Desktop via winget (Paket: Docker.DockerDesktop)..."
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath "winget" `
            -ArgumentList "install","--id","Docker.DockerDesktop","-e",
                          "--accept-source-agreements","--accept-package-agreements" `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $rc = $proc.ExitCode
        $outStr = ((Get-Content $outFile -Raw -ErrorAction SilentlyContinue) + "`n" +
                   (Get-Content $errFile -Raw -ErrorAction SilentlyContinue))
        if ($outStr.Trim()) { Write-Host $outStr }
        # PATH neu laden, damit 'docker' in dieser Session sichtbar wird.
        $env:Path = (@(
            [System.Environment]::GetEnvironmentVariable('Path','Machine'),
            [System.Environment]::GetEnvironmentVariable('Path','User'),
            "$env:ProgramFiles\Docker\Docker\resources\bin"
        ) | Where-Object { $_ }) -join ';'
        if ($rc -eq 0) { Write-OK "Docker Desktop installiert."; return 'installed' }
        $alreadyInstalled = ($outStr -match 'bereits ein vorhandenes Paket') `
                       -or  ($outStr -match 'keine neueren Paketversionen') `
                       -or  ($outStr -match 'Kein verf.{1,3}gbares Upgrade') `
                       -or  ($outStr -match 'No applicable upgrade') `
                       -or  ($outStr -match 'No newer package versions') `
                       -or  ($outStr -match 'No available upgrade found') `
                       -or  ($outStr -match 'already installed')
        if ($alreadyInstalled) { Write-OK "Docker Desktop ist bereits installiert."; return 'already' }
        Write-WARN "winget install Docker.DockerDesktop fehlgeschlagen (ExitCode $rc)."
        return 'failed'
    } catch {
        Write-WARN "winget-Aufruf fehlgeschlagen: $($_.Exception.Message)"
        return 'failed'
    } finally {
        Remove-Item $outFile,$errFile -ErrorAction SilentlyContinue
    }
}

# Startet die Docker-Desktop-Engine und wartet, bis 'docker info' antwortet.
function Start-DockerDaemon([int]$TimeoutSec = 180) {
    $exe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $exe) {
        $running = Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue
        if (-not $running) {
            Write-INFO "Starte Docker Desktop..."
            Start-Process -FilePath $exe | Out-Null
        }
    } else {
        Write-WARN "Docker Desktop.exe nicht am Standardpfad gefunden ($exe)."
    }
    Write-INFO "Warte auf Docker-Daemon (max. ${TimeoutSec}s)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            docker info *>$null
            if ($LASTEXITCODE -eq 0) { Write-OK "Docker-Daemon laeuft."; return $true }
        } catch {}
        Start-Sleep -Seconds 5
    }
    Write-WARN "Docker-Daemon antwortet noch nicht. Beim ersten Start kann das laenger dauern oder eine WSL-Einrichtung anstossen."
    Write-WARN "Pruefe Docker Desktop manuell, danach: senity"
    return $false
}

# =============================================================================
#  State-Machine
# =============================================================================
function Invoke-Phase0 {
    Write-STEP "PHASE 0/2  -  WSL2 einrichten"
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-ERR "winget (App Installer) fehlt. Bitte aus dem Microsoft Store installieren: https://aka.ms/getwinget"
        Write-ERR "Danach das Setup erneut starten."
        Clear-State
        exit 1
    }

    if (Test-ModernWSL) {
        Write-OK "Moderne WSL ist bereits vorhanden - WSL-Phase wird uebersprungen."
        Invoke-Phase1   # direkt weiter zu Docker, kein Reboot noetig
        return
    }

    $wingetState = Install-ModernWSL
    $featuresOk  = Enable-WslFeatures

    if ($wingetState -eq 'failed' -and -not $featuresOk) {
        Write-ERR "WSL-Setup fehlgeschlagen. Manuell als Admin ausfuehren:"
        Write-ERR "  dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart"
        Write-ERR "  dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart"
        Write-ERR "  winget install --id Microsoft.WSL -e"
        Clear-State
        exit 1
    }

    Request-Reboot 1 "WSL2 eingerichtet (Features + Microsoft.WSL)."
}

function Invoke-Phase1 {
    Write-STEP "PHASE 1/2  -  Docker Desktop installieren"
    $state = Install-DockerDesktop
    if ($state -eq 'failed') {
        Write-ERR "Docker-Desktop-Installation fehlgeschlagen. Manuell: winget install --id Docker.DockerDesktop -e"
        Clear-State
        exit 1
    }
    if ($state -eq 'already') {
        # Schon installiert: kein Reboot noetig, direkt zur Daemon-Pruefung.
        Write-OK "Docker Desktop war bereits installiert - Reboot uebersprungen."
        Invoke-Phase2
        return
    }
    Request-Reboot 2 "Docker Desktop installiert."
}

function Invoke-Phase2 {
    Write-STEP "PHASE 2/2  -  Docker starten und abschliessen"
    Start-DockerDaemon | Out-Null
    Clear-State
    Write-Host ""
    Write-OK "Voraussetzungen vollstaendig eingerichtet."
    Write-Host ""
    Write-Host "  Naechster Schritt - einmalig den Senity-Proxy-Key hinterlegen:" -ForegroundColor Cyan
    Write-Host "      senity login" -ForegroundColor White
    Write-Host ""
    Write-Host "  Danach in einem Projektordner einfach:" -ForegroundColor Cyan
    Write-Host "      senity" -ForegroundColor White
    Write-Host ""
    if (-not $Unattended) {
        Write-Host "  ENTER zum Schliessen." -ForegroundColor DarkGray
        [void](Read-Host)
    }
}

# ---- Main -------------------------------------------------------------------
if ($Reset) {
    Clear-State
    Write-OK "Setup-State und RunOnce-Resume entfernt. Naechster Start beginnt bei Phase 0."
    exit 0
}

# Bei Resume aus RunOnce: RunOnce-Eintrag ist von Windows bereits geloescht
# (RunOnce ist one-shot). Wir setzen ihn vor jedem Reboot neu.
Clear-Resume

# Phase bestimmen: -Phase gewinnt (RunOnce/SelfElevate), sonst aus Registry.
$current = if ($Phase -ge 0) { $Phase } else { Get-Phase }

# Elevation sicherstellen (dism/winget brauchen Admin).
if (-not (Test-Admin)) { Invoke-SelfElevate $current }

Write-Host ""
Write-INFO "senity Voraussetzungs-Setup  (Phase $current)  -  Log: $LogFile"
Write-Host ""

switch ($current) {
    0 { Invoke-Phase0 }
    1 { Invoke-Phase1 }
    2 { Invoke-Phase2 }
    default {
        Write-WARN "Unbekannte Phase '$current'. Setze auf 0 zurueck und beginne von vorn."
        Set-Phase 0
        Invoke-Phase0
    }
}
