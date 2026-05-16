# Senity Workspace — Docker-basierter Claude Code

Startet Claude Code in einem Docker Container, universell auf Windows, Linux und macOS.
Einziger Provider: **Senity Chat Proxy**.

## Voraussetzungen

- **Docker Desktop** muss installiert und laufend sein.
  - Windows: `winget install Docker.DockerDesktop`
  - macOS: `brew install --cask docker`
  - Linux: https://docs.docker.com/engine/install/
- **Windows zusaetzlich:** PowerShell 7 (`pwsh`). Der `.bat`-Launcher installiert es bei Bedarf automatisch via winget.

## Schnellstart

```powershell
# Windows
.\claude-senity.bat
.\claude-senity.bat --yolo
.\claude-senity.bat --create-shortcut   # Desktop-Verknuepfung einmalig anlegen

# Linux / macOS
./claude-senity.sh
./claude-senity.sh --yolo
```

## Was beim ersten Start passiert

1. Docker-CLI + Daemon werden geprueft (Docker Desktop wird ggf. gestartet)
2. Image `senity-claude:latest` wird gebaut, falls noch nicht vorhanden
3. `Bindings.md` wird mit Default-Inhalt angelegt, falls fehlend
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

`Bindings.md` steuert, welche Ordner in den Container gemountet werden:

```
# Format: <host-pfad>=<container-pfad>
./workspace=/workspace
./projects/my-repo=/projects/my-repo
```

Standard: `./workspace=/workspace`. Wenn `Bindings.md` fehlt oder leer ist, wird nur `./workspace` eingebunden.

## Config Mount

`.claude/` vom Host wird nach `/workspace/.claude` im Container gemountet (HOME=/workspace im Container). So sind Claude Code-Einstellungen immer synchron.

```
.claude/
├── settings.local.json   # Persoenliche Einstellungen
```

## .env

Credentials in `.env` im Script-Verzeichnis ablegen (nicht committet):

```
SENITY_CHAT_PROXY_URL=https://sdr.senity.ai/api/claude-proxy
SENITY_CHAT_PROXY_KEY=<uuid-oder-64-hex-key>
```

Beide Werte koennen alternativ als Prozess-Environment gesetzt sein, das `.env`-File hat aber Vorrang.

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

Standard deaktiviert (Sicherheit). Aktivieren / Deaktivieren:

```bash
.\claude-senity.bat --yolo
./claude-senity.sh --yolo

.\claude-senity.bat --no-yolo
./claude-senity.sh --no-yolo
```

Im Yolo-Mode fuehrt Claude Code Commands ohne Bestaetigung aus.

## Troubleshooting

**Docker Desktop nicht gefunden**
- Manuell installieren: https://docs.docker.com/desktop/install/windows-install/
- Oder: `winget install Docker.DockerDesktop` (Windows) / `brew install --cask docker` (macOS)
- Der Launcher startet Docker Desktop automatisch, wenn es bereits installiert, aber noch nicht laufend ist.

**SENITY_CHAT_PROXY_KEY nicht gesetzt**
- `.env` im Script-Verzeichnis pruefen
- Variable muss gesetzt sein (UUID oder 64-Hex-Key)

**Container startet nicht**
- `docker images`, Image `senity-claude:latest` muss existieren
- `docker ps -a`, alte Container loeschen: `docker rm senity-workspace-*`
