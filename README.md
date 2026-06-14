# Senity Workspace — Docker-basierter Claude Code

Startet Claude Code in einem Docker Container, universell auf Windows, Linux und macOS.
Einziger Provider: **Senity Chat Proxy**.

## Voraussetzungen

- **Docker Desktop** muss installiert und laufend sein.
  - Windows: `winget install Docker.DockerDesktop`
  - macOS: `brew install --cask docker`
  - Linux: https://docs.docker.com/engine/install/
- **Windows zusaetzlich:** PowerShell 7 (`pwsh`). Der `.bat`-Launcher installiert es bei Bedarf automatisch via winget.
- **git** wird auf dem Host gebraucht (das Repo-Setup klont/pullt vor dem
  Container-Start). Fehlt es, installiert der Launcher es automatisch —
  winget (Windows), Homebrew/Xcode CLT (macOS), apt/dnf/pacman/zypper (Linux).
  `ssh`/`curl` bringt jedes unterstuetzte Betriebssystem bereits mit.

## Schnellstart

```powershell
# Windows
.\claude-senity.bat
.\claude-senity.bat --yolo
.\claude-senity.bat --create-shortcut   # Desktop-Verknuepfung einmalig anlegen
.\claude-senity.bat --test-links        # Datei-/Ordner-/Weblink-Klicks testen

# Linux / macOS
./claude-senity.sh
./claude-senity.sh --yolo
./claude-senity.sh --test-links
```

## Was beim ersten Start passiert

1. Docker-CLI + Daemon werden geprueft (Docker Desktop wird ggf. gestartet)
2. Image `senity-claude:latest` wird gebaut, falls noch nicht vorhanden
3. `.bindings` wird mit Default-Inhalt angelegt, falls fehlend
4. `workspace/` und `.claude/` werden angelegt
5. Container startet mit allen Mounts und Senity-Proxy-Credentials

## Provider

Es gibt nur einen Provider: **Senity Chat Proxy**.

| Provider | Default-Modell | Endpunkt | Token |
|---|---|---|---|
| Senity Chat Proxy | `Senity Proxy` (intern: `qwen3.6:35b`) | `SENITY_CHAT_PROXY_URL` (Default: `https://sdr.senity.ai/api/claude-proxy`) | `SENITY_CHAT_PROXY_KEY` |

Modell ueberschreiben:

```bash
./claude-senity.sh --model qwen3.6:35b
.\claude-senity.bat --model qwen3.6:35b
```

Hinweis: Der Senity Chat Proxy routet alle Modell-Strings intern uebers MSH-Gateway (`qwen3.6@coder-agent`). Der `--model`-Wert beeinflusst nur die Anzeige im Claude-Code-Header.

## Mount-Pfade

`.bindings` ist eine reine Mount-Config (keine Markdown-Datei). Leerzeilen und `#`-Kommentare werden ignoriert, alles andere muss eine Mount- oder Exclude-Zeile sein:

```
# Format: <host>=<container>[:ro|:rw]   Excludes: !<glob>
~/projekte/mein-repo=/workspace/mein-repo
C:\Users\ich\code\api=/workspace/api
~/docs/referenz=/workspace/referenz:ro

!**/node_modules
!**/.git
```

`workspace/` und `.claude/` werden automatisch gemountet. Der vom Launcher verwaltete Block zwischen `# >>> SENITY-VERWALTET >>>` und `# <<< SENITY-VERWALTET <<<` enthaelt die Skills/Commands/Agents-Mounts und wird bei jedem Start neu geschrieben, von Hand nichts darin aendern. `!`-Zeilen ueberlagern getroffene Unterpfade im Container mit einem leeren Read-Only-Ordner (kein Symlink, kein Admin noetig).

## Config Mount

`.claude/` vom Host wird nach `/workspace/.claude` im Container gemountet (HOME=/workspace im Container). So sind Claude Code-Einstellungen immer synchron.

```
.claude/
├── settings.local.json   # Persoenliche Einstellungen
```

## .env / Erst-Setup des Keys

Beim ersten Start prueft der Launcher, ob `SENITY_CHAT_PROXY_KEY` in `.env` (oder im Environment) gesetzt ist:

- **Gesetzt:** Key wird gegen den Proxy validiert; bei Erfolg startet Claude Code direkt.
- **Fehlt:** Launcher fragt interaktiv nach Proxy-URL (Default `https://sdr.senity.ai/api/claude-proxy`) und Key. Der Key wird gegen den Proxy getestet; bei Erfolg werden beide Werte in `.env` persistiert (max. 3 Versuche).

Manuell anlegen geht weiterhin:

```
SENITY_CHAT_PROXY_URL=https://sdr.senity.ai/api/claude-proxy
SENITY_CHAT_PROXY_KEY=<uuid-oder-64-hex-key>
```

Beide Werte koennen alternativ als Prozess-Environment gesetzt sein, das `.env`-File hat aber Vorrang. `.env` ist via `.gitignore` ausgeschlossen.

## Projekt-Repos (`workspace/projects/`)

`senity-workspace` und alle weiteren Projekt-Repos liegen unter
`workspace/projects/<name>` direkt im Repo. Da `workspace/` ohnehin nach
`/workspace` im Container gemountet ist, sind sie automatisch unter
`/workspace/projects/<name>` sichtbar, ohne zusaetzliche Mounts.

- `senity-workspace` wird vom Launcher als `pull`-Repo verwaltet:
  `workspace/projects/senity-workspace` (im Container:
  `/workspace/projects/senity-workspace`).
- Weitere Repos klont der Nutzer im Container ueber den Skill
  `/include-git-repository <git-url>`. Default-Ziel:
  `workspace/projects/<name-aus-url>`. Da der Klon im `/workspace`-Mount
  liegt, ist er sofort persistent auf dem Host, **kein Container-Neustart
  noetig**.

Postet der Nutzer eine Git-URL im Chat, schlaegt Claude proaktiv vor,
das Repo per `/include-git-repository` zu klonen, fuehrt es aber erst
nach Rueckfrage aus.

## Codex / Gemini CLI (optional)

Im Container sind zusaetzlich die `codex`- und `gemini`-CLI installiert. Es
gibt **keinen eigenen Login-Launcher mehr**: Der Login passiert beim ersten
Aufruf der Skills `codex-delegator` bzw. `gemini-delegator`. Fehlt das Token,
gibt der Skill den exakten `docker exec`-Befehl mit dem aktuellen Container-Namen
aus (Format: `senity-workspace-<user>-<pid>`). Du fuehrst ihn in einem zweiten
Terminal auf dem Host aus, etwa:

```bash
docker exec -it senity-workspace-c4rtw-12345 codex login    # OpenAI / ChatGPT
docker exec -it senity-workspace-c4rtw-12345 gemini         # Google
```

Nach dem OAuth-Flow landen die Anmeldedaten in `workspace/.codex/` bzw.
`workspace/.gemini/` und bleiben ueber kuenftige Container-Starts erhalten.
Einmal anmelden genuegt. Re-Login: `workspace/.codex/` bzw. `workspace/.gemini/`
loeschen, beim naechsten Skill-Trigger meldet sich der Auth-Check wieder.

## Docker Image

```dockerfile
FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y git openssh-client curl jq python3
RUN npm install -g @anthropic-ai/claude-code
ENV HOME=/workspace
WORKDIR /workspace
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["claude"]
```

`ANTHROPIC_BASE_URL` und `ANTHROPIC_API_KEY` werden zur Laufzeit vom Launcher gesetzt, nicht im Image fest verdrahtet.

Image wird einmalig gebaut: `docker build -t senity-claude:latest .`

## Yolo Mode

**Standard aktiviert.** Der Container ist isoliert (eigener User, Mounts klar abgegrenzt), daher startet Claude Code per Default mit `--dangerously-skip-permissions`.

```bash
# Deaktivieren (Permission-Prompts aktivieren)
.\claude-senity.bat --no-yolo
./claude-senity.sh --no-yolo

# Explizit aktivieren (no-op, ist Default)
.\claude-senity.bat --yolo
./claude-senity.sh --yolo
```

## Senity-Theme (Farben)

Alle Senity-Farben (Banner im Container, Welcome-Box im Claude-Code-CLI) werden aus `senity-theme.conf` gespeist:

```
PRIMARY_256=99        # dunkles Senity-Lila
SECONDARY_256=141     # helles Senity-Lila
ACCENT_256=199        # Pink-Glow
```

- `patch-claude-header.js` patcht beim Image-Build alle Anthropic-Orange-Farbcodes im Claude-Code-Bundle auf die Senity-Palette und ersetzt Welcome-Box-Strings ("Welcome back!" -> "Willkommen bei Senity!" etc.).
- `docker-entrypoint.sh` liest dieselbe Datei zur Laufzeit fuer das ASCII-Banner.
- `senity-mascot-filter.py` setzt zusaetzlich klickbare OSC-8-Links fuer Web-URLs und vorhandene Dateipfade (`/workspace/...`, relative Pfade, `.bindings`-Mounts), damit Strg+Klick im Terminal die Host-Datei oeffnet. Mit `--test-links` gibt der Launcher je einen Web-, Datei- und Ordnerlink aus.

### Klickbare Links / Warp

Der Linkifier erkennt Weblinks, Dateien und Ordner und mappt Containerpfade ueber `SENITY_LINK_PATH_MAP` auf Hostpfade. Relative Pfade werden gegen das aktuelle Arbeitsverzeichnis, `/workspace` und direkte Projektordner unter `/workspace/projects/` aufgeloest. Vorhandene OSC-8-Links werden respektiert; weitere Pfade im selben Output-Chunk werden trotzdem verlinkt.

Warp behandelt Claude Code als TUI/Fullscreen-App und reicht Mausereignisse standardmaessig an die App weiter. Deshalb setzt Senity `SENITY_STRIP_MOUSE_REPORTING=auto`: Bei Warp werden Mouse-Reporting-Enable-Sequenzen entfernt, damit `CTRL`+Klick auf Datei-/Ordner-/Weblinks funktioniert. Zusaetzlich setzt Senity `SENITY_VISIBLE_HOST_PATHS=auto`: Bei Warp werden Ordnerpfade wie `/workspace/...` als sichtbare Hostpfade wie `D:\...\workspace\...` ausgegeben; Dateien werden als sichtbare `file:///...`-Links ausgegeben, weil Warp dieses URL-Protokoll nativ oeffnet.

Steuerung:

```bash
# Link-Test ohne Claude Code starten
.\claude-senity.bat --test-links
./claude-senity.sh --test-links

# Mausereignisse explizit an Claude Code durchreichen
.\claude-senity.bat --mouse-reporting
./claude-senity.sh --mouse-reporting

# Mausereignisse explizit fuer Terminal-Links reservieren
.\claude-senity.bat --no-mouse-reporting
./claude-senity.sh --no-mouse-reporting
```

Editor-Linkformat fuer Zeilen-/Spaltenlinks:

```bash
# Default: file:///...
SENITY_FILE_LINK_FORMAT=file

# Optional: Editor-URI, z.B. foo.ts:42:3 -> vscode://file/.../foo.ts:42:3
SENITY_FILE_LINK_FORMAT=vscode
```

Unterstuetzte Werte: `file` (Default), `vscode`, `vscode-insiders`, `vscodium`, `cursor`, `windsurf`.

Fallback fuer sichtbare Host-Pfade:

```bash
# Default: auto (bei Warp aktiv)
SENITY_VISIBLE_HOST_PATHS=auto

# Containerpfade sichtbar lassen und nur OSC-8 nutzen
SENITY_VISIBLE_HOST_PATHS=0

# Hostpfade immer sichtbar machen
SENITY_VISIBLE_HOST_PATHS=1
```

Aenderungen an `senity-theme.conf` benoetigen einen Image-Rebuild:

```bash
.\claude-senity.bat --rebuild
./claude-senity.sh --rebuild
```

## Image-Rebuild

```bash
.\claude-senity.bat --rebuild
./claude-senity.sh --rebuild
```

Loescht `senity-claude:latest` und baut das Image neu. Noetig nach Aenderungen an `Dockerfile`, `senity-theme.conf`, `patch-claude-header.js`, `senity-mascot-filter.py` oder `docker-entrypoint.sh`.

## Troubleshooting

**Docker Desktop nicht gefunden**
- Manuell installieren: https://docs.docker.com/desktop/install/windows-install/
- Oder: `winget install Docker.DockerDesktop` (Windows) / `brew install --cask docker` (macOS)
- Der Launcher startet Docker Desktop automatisch, wenn es bereits installiert, aber noch nicht laufend ist.

**SENITY_CHAT_PROXY_KEY nicht gesetzt**
- Launcher fragt beim Start interaktiv nach URL und Key und validiert beides gegen den Proxy
- Bei Erfolg wird `.env` automatisch geschrieben
- Bei wiederholt fehlschlagender Validierung (3x): URL pruefen und Key beim Senity-Admin neu anfordern

**Key-Validierung schlaegt fehl trotz gueltigem Key**
- Netzwerk / Firewall pruefen (Launcher macht einen `POST /v1/messages` gegen die Proxy-URL)
- URL ohne abschliessenden Slash eingeben, z.B. `https://sdr.senity.ai/api/claude-proxy`

**Container startet nicht**
- `docker images`, Image `senity-claude:latest` muss existieren
- `docker ps -a`, alte Container loeschen: `docker rm senity-workspace-*`
