# Senity CLI

Globaler `senity`-Befehl, der den Senity-Workspace-Container ad-hoc startet
und das aktuelle Verzeichnis als `/workspace/cwd` mountet.

Analog zu `claude`, `codex`, `gemini`: irgendwo `cd`, `senity` tippen, drin sein.

## Installation

### Linux / macOS

```bash
curl -fsSL https://git.senity.ai/senity-admin/senity-claude-code/raw/branch/main/senity-cli/install.sh | bash
```

Oder lokal aus dem Repo:

```bash
./senity-cli/install.sh
```

Installiert nach `~/.local/bin/senity`. Falls dieser Pfad nicht im `$PATH`
liegt, gibt der Installer die Zeile fuer `~/.bashrc` / `~/.zshrc` aus.

### Windows (pwsh)

```powershell
irm https://git.senity.ai/senity-admin/senity-claude-code/raw/branch/main/senity-cli/install.ps1 | iex
```

Oder lokal:

```powershell
.\senity-cli\install.ps1
```

Installiert nach `%USERPROFILE%\.senity\bin\senity.ps1` plus `senity.bat`-Shim
und erweitert den User-`PATH`. Neue Shell oeffnen.

## Erst-Login

```bash
senity login
```

Fragt nach Senity-Proxy-URL (Default `https://sdr.senity.ai/api/claude-proxy`)
und Proxy-Key. Schreibt nach `~/.senity/.env` (Mode 600 auf Unix).

## Benutzung

```bash
cd ~/projekte/foo
senity
```

Startet den Container, mountet `~/projekte/foo` als `/workspace/cwd`.
Beim Exit ist der Container weg, der Ordner unveraendert.

### Optionen

| Flag | Wirkung |
|---|---|
| `--skip-update` (pwsh: `-SkipUpdate`) | Ueberspringt Docker- und Skill-Updates beim Start |
| `--no-yolo` (pwsh: `-NoYolo`) | Permission-Prompts aktivieren (Default: Yolo an) |
| `--mount H:C[:ro]` (pwsh: `-Mount`) | Zusatz-Mount, mehrfach erlaubt |
| `--image <ref>` (pwsh: `-Image`) | Image-Tag ueberschreiben |
| `--help` / `-h` | Hilfe |

### Beispiele

```bash
# Schnellstart, alles auf Default
senity

# Offline (kein Pull, kein Skill-Refresh)
senity --skip-update

# Extra-Mount, z.B. shared SSH-Config
senity --mount ~/.gitconfig:/workspace/.gitconfig:ro

# Spezifisches Image-Tag (Production-Pinning)
senity --image git.senity.ai/senity-admin/senity-claude-code:1.4.2

# Permission-Prompts aktivieren statt Yolo
senity --no-yolo
```

## Default-Verhalten

| Schritt | Default | Skip |
|---|---|---|
| `docker pull` des Images | bei jedem Start | `--skip-update` |
| `git pull` der Skills/Commands/Agents | bei jedem Start | `--skip-update` |
| `git pull` der MCP-Server | bei jedem Start | `--skip-update` |
| Yolo-Mode (kein Permission-Prompt) | an | `--no-yolo` |
| Workspace-HOME | `~/.senity/workspace` -> `/workspace` | n/a |
| cwd-Mount | `$(pwd)` -> `/workspace/cwd` | n/a |
| MCP-User-Config | `~/.senity/mcp-config.json` (falls vorhanden) | n/a |

Bei Netzwerk-Fehler waehrend Auto-Update: Warning, Start trotzdem mit lokalem
Image und letztem Cache-Stand. Faellt das Image-Pull fehl und kein lokales
Image existiert, faellt der Wrapper auf `senity-claude:latest` zurueck.

## Dateilayout

```
~/.senity/
├── .env                 # SENITY_CHAT_PROXY_URL + KEY (chmod 600)
├── mcp-config.json      # optional, User-globale MCP-Server (siehe mcp-config.example.json)
├── workspace/           # persistentes /workspace im Container (Codex-Tokens, Claude-Settings, ...)
└── cache/
    ├── skills/          # Klon von murc134/Claude-Skills
    ├── commands/        # Klon von murc134/Claude-Commands
    ├── agents/          # Klon von murc134/Claude-Agents
    └── senity-mcps/     # Klon von senity/senity-mcps
```

## Parallele Sessions

Jeder Aufruf bekommt einen eigenen Container-Namen `senity-<pid>-<epoch>`.
Zwei Terminals, zweimal `senity`, kein Konflikt. Beim Exit verschwinden
beide Container (`--rm`).

## Update der CLI selbst

```bash
# Linux / macOS
curl -fsSL https://git.senity.ai/senity-admin/senity-claude-code/raw/branch/main/senity-cli/install.sh | bash

# Windows
irm https://git.senity.ai/senity-admin/senity-claude-code/raw/branch/main/senity-cli/install.ps1 | iex
```

Ueberschreibt das Wrapper-Script. Cache und `.env` bleiben unangetastet.

## Troubleshooting

**`Image fehlt und --skip-update verhindert Pull`**
Aufruf ohne `--skip-update` wiederholen. Erstaufruf braucht einen Pull.

**`docker pull fehlgeschlagen ... 401 Unauthorized`**
Vorher einmalig `docker login git.senity.ai`. Token kommt aus Gitea
(User Settings -> Applications -> Access Tokens, Scope `read:package`).

**`SENITY_CHAT_PROXY_KEY fehlt`**
`senity login` ausfuehren.

**Skills/Commands fehlen im Container**
Auto-Update braucht SSH-Zugriff auf die Repos. SSH-Agent oder
`~/.ssh/config` pruefen. `--skip-update` verwendet den letzten lokalen Stand.

## Abgrenzung

Der klassische Pfad mit Repo-Klon und `claude-senity.sh` / `.bat` bleibt
fuer den Developer-Workspace mit fester `.bindings`-Datei, mehreren
Projekt-Mounts und dem `INITIAL_PROMPT.md`-Workflow. `senity` ist die
zero-config Ad-hoc-Variante fuer "schnell mal in einem fremden Ordner".

Persistente Multi-Projekt-Workspaces -> `claude-senity` (Repo-Setup).
Ad-hoc-Session im aktuellen Ordner -> `senity`.
