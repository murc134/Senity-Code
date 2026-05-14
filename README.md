# Senity Workspace — Docker-basierter Claude Code

Startet Claude Code in einem Docker Container — universell auf Windows, Linux und macOS.

## Schnellstart

```powershell
# 1. Setup ausfuehren
.\setup.bat

# 2. Modus waehlen
#    1) MSH Gateway (qwen3.6 vom Missionstarkeshandwerk — vLLM, am schnellsten)
#    2) Eigenes Anthropic (Pro/Team API-Key)
#    3) Ollama lokal

# 3. Loslegen
.\claude-msh.bat
```

## Was das macht

1. Prueft Docker Desktop
2. Baut das Docker Image `senity-claude:latest`
3. Prueft/erstellt Bindings.md
4. Waehlt die Modell-Quelle
5. Startet Claude Code im Container mit allen Mounts

## Verfigbare Modus

| Modus | Modell | Quelle | Token |
|---|---|---|---|
| `msh` (Default) | qwen3.6 | vLLM `vllm.missionstarkeshandwerk.de` | `.env` MSH_API_KEY |
| `anthropic` | claude-sonnet-4-6 | Echte Anthropic API | `ANTHROPIC_API_KEY` Env |
| `ollama` | freiwaehlbbar | Lokaler Ollama | `ollama` (kein Token) |

Manuellen Modus waehlen:

```bash
claude-msh --anthropic "frag mich was"
claude-msh --ollama "was geht"
```

## Mount-Pfade

Bindings.md steuert, welche Ordner in den Container gemountet werden:

```
# Format: <host-pfad>=<container-pfad>
./workspace=/workspace
./projects/my-repo=/projects/my-repo
```

Standard: `./workspace=/workspace`. Wenn Bindings.md fehlt oder leer ist, wird nur `./workspace` eingebunden — einfach Enter drcken.

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
CMD ["claude", "--model", "qwen3.6"]
```

Das Image wird einmalig gebaut: `docker build -t senity-claude:latest .`

## Troubleshooting

**Docker Desktop nicht gefunden**
→ Installiere: https://docs.docker.com/desktop/install/windows-install/
→ Oder: `winget install Docker.DockerDesktop`

**kein Auth-Token gefunden**
→ `.env` im Script-Verzeichnis pruefen
→ `MSH_API_KEY` oder `ANTHROPIC_API_KEY` muss gesetzt sein

**Ollama nicht erreichbar**
→ `ollama serve` starten
→ Port 11434 muss auf localhost lauschen

**Container startet nicht**
→ `docker images` — Image `senity-claude:latest` muss existieren
→ `docker ps -a` — Alte Container loesen: `docker rm senity-workspace-*`
