# Senity Workspace — Docker-basierter Claude Code

Startet Claude Code in einem Docker Container, universell auf Windows, Linux und macOS.
Einziger Provider: **Senity Chat Proxy**.

## Schnellstart

```powershell
# 1. Setup ausfuehren (baut Image, prueft Docker, fragt Modell + Yolo)
.\setup.bat

# 2. Direkt starten
.\claude-senity.bat
.\claude-senity.bat --yolo
./claude-senity.sh
./claude-senity.sh --yolo
```

## Was das macht

1. Prueft Docker Desktop (installiert automatisch falls nicht vorhanden)
2. Baut das Docker Image `senity-claude:latest`
3. Erstellt Desktop-Verknuepfung (Windows)
4. Prueft/erstellt Bindings.md
5. Liest Senity Chat Proxy Credentials aus `.env`, fragt Modell + Yolo
6. Startet Claude Code im Container mit allen Mounts

## Provider

Es gibt nur einen Provider: **Senity Chat Proxy**.

| Provider | Default-Modell | Endpunkt | Token |
|---|---|---|---|
| Senity Chat Proxy | `claude-sonnet-4-6` | `SENITY_CHAT_PROXY_URL` (Default: `https://sdr.senity.ai/api/claude-proxy`) | `SENITY_CHAT_PROXY_KEY` |

Modell ueberschreiben:

```bash
./claude-senity.sh --model claude-opus-4-7
.\claude-senity.bat --model claude-opus-4-7
```

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

Standard deaktiviert (Sicherheit). Aktivieren:

```bash
.\setup.bat --yolo
./setup.sh --yolo

.\claude-senity.bat --yolo
./claude-senity.sh --yolo
```

Claude Code fuehrt Commands ohne Bestaetigung aus. Deaktivieren:

```bash
.\setup.bat --no-yolo
./setup.sh --no-yolo

.\claude-senity.bat --no-yolo
./claude-senity.sh --no-yolo
```

## Troubleshooting

**Docker Desktop nicht gefunden**
- Wird automatisch installiert (winget / brew / apt / yum)
- Manuell: https://docs.docker.com/desktop/install/windows-install/
- Oder: `winget install Docker.DockerDesktop`

**SENITY_CHAT_PROXY_KEY nicht gesetzt**
- `.env` im Script-Verzeichnis pruefen
- Variable muss gesetzt sein (UUID oder 64-Hex-Key)

**Container startet nicht**
- `docker images`, Image `senity-claude:latest` muss existieren
- `docker ps -a`, alte Container loeschen: `docker rm senity-workspace-*`
