# Senity Workspace — Docker-basierter Claude Code

Startet Claude Code in einem Docker Container — universell auf Windows, Linux und macOS.

## Schnellstart

```powershell
# 1. Setup ausfuehren
.\setup.bat

# 2. Modus waehlen (MSH / Anthropic / Ollama)
# 3. Container startet interaktiv

# Oder direkt (Yolo optional):
.\claude-msh.bat --yolo
./claude-msh.sh --yolo
```

## Was das macht

1. Prueft Docker Desktop (installiert automatisch falls nicht vorhanden)
2. Baut das Docker Image `senity-claude:latest`
3. Erstellt Desktop-Verknuepfung (Windows)
4. Prueft/erstellt Bindings.md
5. Waehlt Provider, Modell und Yolo-Modus
6. Startet Claude Code im Container mit allen Mounts

## Verfigbare Modus

| Modus | Modell | Quelle | Token |
|---|---|---|---|
| `msh` (Default) | qwen3.6 | vLLM `vllm.missionstarkeshandwerk.de` | `.env` MSH_API_KEY / MSH_VLLM_API_KEY |
| `anthropic` | claude-sonnet-4-6 | Echte Anthropic API | `ANTHROPIC_API_KEY` Env |
| `ollama` | freiwaehlbbar | Lokaler Ollama | `ollama` (kein Token) |

Manuellen Modus waehlen:

```bash
./claude-msh.sh --msh
./claude-msh.sh --anthropic --yolo
./claude-msh.sh --ollama --model llama3.1
```

## Mount-Pfade

Bindings.md steuert, welche Ordner in den Container gemountet werden:

```
# Format: <host-pfad>=<container-pfad>
./workspace=/workspace
./projects/my-repo=/projects/my-repo
```

Standard: `./workspace=/workspace`. Wenn Bindings.md fehlt oder leer ist, wird nur `./workspace` eingebunden.

## Config Mount

`.claude/` vom Host wird nach `/home/node/.claude` im Container gemountet. So sind Claude Code-Einstellungen immer synchron.

```
claude/
├── settings.local.json   # Persoehnliche Einstellungen
```

## .env

Auth-Tokens in `.env` im Script-Verzeichnis ablegen (nicht committet):

```
MSH_VLLM_URL=https://vllm.missionstarkeshandwerk.de
MSH_VLLM_API_KEY=...
MSH_VLLM_MODEL=qwen3.6
MSH_API_URL=https://gateway.missionstarkeshandwerk.de
MSH_API_KEY=sk-msh-local-...
```

## Docker Image

```dockerfile
FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y git openssh-client curl jq python3
RUN npm install -g @anthropic-ai/claude-code
ENV ANTHROPIC_BASE_URL=https://gateway.missionstarkeshandwerk.de
ENV ANTHROPIC_API_KEY=ollama
ENV HOME=/workspace
WORKDIR /workspace
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["claude"]
```

Das Image wird einmalig gebaut: `docker build -t senity-claude:latest .`

## Yolo Mode

Standard deaktiviert (Sicherheit). Aktivieren:

```bash
# Setup
.\setup.bat --yolo
./setup.sh --yolo

# Direkt
.\claude-msh.bat --yolo
./claude-msh.sh --yolo
```

Claude Code fuehrt Commands ohne Bestaetigung aus. Deaktivieren:

```bash
# Setup
.\setup.bat --no-yolo
./setup.sh --no-yolo

# Direkt
.\claude-msh.bat --no-yolo
./claude-msh.sh --no-yolo
```

## Troubleshooting

**Docker Desktop nicht gefunden**
→ Wird automatisch installiert
→ Oder manuell: https://docs.docker.com/desktop/install/windows-install/
→ Oder: `winget install Docker.DockerDesktop`

**kein Auth-Token gefunden**
→ `.env` im Script-Verzeichnis pruefen
→ `MSH_API_KEY` oder `MSH_VLLM_API_KEY` muss gesetzt sein

**Ollama nicht erreichbar**
→ `ollama serve` starten
→ Port 11434 muss auf localhost lauschen

**Container startet nicht**
→ `docker images` — Image `senity-claude:latest` muss existieren
→ `docker ps -a` — Alte Container loesen: `docker rm senity-workspace-*`
