# senity-setup.exe (Windows-Installer)

Gefuehrte Windows-Installation der `senity`-CLI inklusive der zwei
reboot-pflichtigen Voraussetzungen **WSL2** und **Docker Desktop**. Ein
Doppelklick, je ein UAC-Klick nach den Neustarts, fertig.

## Bestandteile

| Datei | Rolle |
|---|---|
| `senity.iss` | Inno-Setup-Skript. Erzeugt `dist\senity-setup.exe`. Installiert die CLI nach `%ProgramFiles%\Senity`, traegt sie in den System-PATH ein, startet den Prereq-Bootstrapper. Laeuft elevated (`PrivilegesRequired=admin`). |
| `senity-prereqs.ps1` | Reboot-State-Machine. Richtet WSL2 + Docker Desktop in der richtigen Reihenfolge mit Neustarts ein. Wiederverwendet die erprobte `claude-senity.ps1`-Logik. |
| `senity.bat` | cmd/pwsh-Shim, damit `senity` ueberall im Terminal funktioniert. |
| `build.ps1` | Kompiliert `senity.iss` via ISCC.exe (Inno Setup 6). |

Die eigentliche CLI (`senity.ps1`) liegt eine Ebene hoeher in `senity-cli/` und
wird vom Inno-Skript per `..\senity.ps1` eingebunden.

## Bauen

```powershell
# Inno Setup 6 muss installiert sein, sonst:
.\build.ps1 -Install      # installiert Inno Setup via winget, dann Build
.\build.ps1               # Build -> dist\senity-setup.exe
.\build.ps1 -Version 1.2.0
```

## Installations-Ablauf (Kundensicht)

```
Doppelklick senity-setup.exe
  -> UAC (einmal)
  -> CLI nach %ProgramFiles%\Senity, System-PATH erweitert
  -> Prereq-Bootstrapper startet (Task "Voraussetzungen" gewaehlt)

  PHASE 0/2  WSL2-Features (dism) + Microsoft.WSL (winget)
    -> Reboot (Setup setzt sich via RunOnce selbst fort)
  PHASE 1/2  Docker Desktop (winget)
    -> Reboot
  PHASE 2/2  Docker-Daemon starten + auf "docker info" warten
    -> fertig

Danach einmalig:
  senity login        # Senity-Proxy-Key hinterlegen
Dann im Projektordner:
  senity              # Container starten
```

**Fast-Path:** Sind WSL (modern) und Docker bereits installiert, ueberspringt
der Bootstrapper die jeweilige Phase und die zugehoerigen Neustarts.

## Reboot-State-Machine (Details)

- **State:** `HKCU:\Software\Senity\Setup`, DWORD `Phase` (0/1/2).
- **Resume:** `HKCU:\...\RunOnce\SenityPrereqs` wird vor jedem Reboot gesetzt und
  startet das Skript beim naechsten Logon erneut. RunOnce ist one-shot; das
  Skript setzt den Eintrag vor jedem weiteren Reboot neu.
- **Elevation:** RunOnce laeuft nicht elevated. Das Skript prueft `Test-Admin`
  und startet sich bei Bedarf via `-Verb RunAs` neu. Daher genau ein UAC-Prompt
  pro Phase.
- **Log:** `%LOCALAPPDATA%\Senity\setup.log`.

### Manuelle Bedienung

```powershell
# Voraussetzungs-Setup manuell starten:
powershell -ExecutionPolicy Bypass -File senity-prereqs.ps1
# Unattended (Auto-Reboot mit 20s-Countdown, Esc bricht ab):
powershell -ExecutionPolicy Bypass -File senity-prereqs.ps1 -Unattended
# State + RunOnce zuruecksetzen (von Phase 0 neu beginnen):
powershell -ExecutionPolicy Bypass -File senity-prereqs.ps1 -Reset
```

## Deinstallation

Ueber "Apps & Features" -> "Senity CLI" -> Deinstallieren. Entfernt die
CLI-Dateien, den System-PATH-Eintrag und ein eventuell offenes RunOnce-Resume.

**Bleibt erhalten:** Benutzerdaten unter `%USERPROFILE%\.senity` (Proxy-Key,
Cache, Workspace). Bei Bedarf manuell loeschen. WSL2 und Docker Desktop werden
ebenfalls nicht entfernt (eigenstaendige Produkte).

## Voraussetzungen am Host

- **winget** (App Installer aus dem Microsoft Store). Fehlt es, bricht der
  Bootstrapper mit Hinweis ab: <https://aka.ms/getwinget>.
- **x64-Windows 10/11.** Auf Windows 10 19045 ist `wsl --install` bekannt
  fehlerhaft (schaltet die Features nicht ein); deshalb dism + winget getrennt.
