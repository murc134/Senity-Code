# Senity Workspace — Claude Code Docker-Wrapper

Startet Claude Code in einem isolierten Docker-Container (`senity-claude:latest`)
gegen den **Senity Chat Proxy**. Cross-Platform: Windows, Linux, macOS.
Anwender-Doku steht in `README.md` — diese Datei ist die Entwickler-Referenz für
das Repo-Setup, das vor jedem Container-Start läuft.

## Launcher

| Datei | Rolle |
|---|---|
| `claude-senity.sh` / `.ps1` / `.bat` | Host-Launcher (Linux·macOS / Windows / Windows-Bootstrap) |
| `.env.shared` | Committet: base64-kodierte **Deploy-Keys** (Klartext) fürs Repo-Setup |
| `.env` | Gitignored: Proxy-Credentials (`SENITY_CHAT_PROXY_URL`, `SENITY_CHAT_PROXY_KEY`) |
| `INITIAL_PROMPT.md` | Wird bei jedem Start gelesen und Claude Code via `--append-system-prompt` mitgegeben |
| `.bindings` | Committet als initialer Zustand. Launcher setzt einmalig `git update-index --skip-worktree`, danach erscheinen lokale Edits (interaktiver Workspace-Pfad, eigene Mounts) nicht mehr im `git status` |

Die `.sh`/`.ps1`/`.bat` müssen funktional **gleichwertig** bleiben. Die `.bat`
ist ein reiner pwsh-Bootstrap — sie ruft `claude-senity.ps1 %*` auf und enthält
selbst keine Launcher-Logik; jede `.ps1`-Änderung wirkt automatisch auch über
die `.bat`.

## Verwaltete Repos & Deploy-Keys

Vor dem Container-Start klont/pullt der Launcher fünf fest hinterlegte Repos
(`MANAGED_REPO_*` / `$ManagedRepos`).

| Repo | Klon-Ziel (Host) | Modus |
|---|---|---|
| `senity/senity-workspace` (git.senity.ai:2200) | `workspace/projects/senity-workspace` | `pull` |
| `murc134/Claude-Skills` | `workspace/.claude/skills/intern` | `fresh` |
| `murc134/Claude-Commands` | `workspace/.claude/commands/intern` | `fresh` |
| `murc134/Claude-Agents` | `workspace/.claude/agents/intern` | `fresh` |
| `senity/senity-mcps` (git.senity.ai:2200) | `workspace/.mcp/senity-mcps` | `pull` |

- **`fresh`:** Verzeichnis wird bei *jedem* Start gelöscht und neu geklont — nur
  für Repos, in die der Nutzer nicht schreibt (`:ro`).
- **`pull`:** klonen falls fehlt, sonst `git pull --ff-only`. `senity-workspace`
  ist das Arbeits-Repo — `fresh` würde nicht-gepushte Arbeit vernichten.
- Branch ist immer `main`.

**Deploy-Keys.** Pro Repo ein read-only Deploy-Key, base64-kodiert (Klartext,
**keine** Verschlüsselung) in der committeten `.env.shared`. Der Launcher
dekodiert sie beim Start nach `.deploy-keys/` (gitignored, `chmod 600` /
ACL-gesperrt) und nutzt sie per `GIT_SSH_COMMAND`. Schlägt das fehl (Key nicht
registriert), fällt der Launcher auf den normalen `~/.ssh`-Zugang zurück. Die
`claude-*`-Keys sind dieselben wie im Projekt `msh-ai-code-assistant`.

## `.claude`-Zweiteilung

Pro Bereich (`skills`/`commands`/`agents`) zwei nebeneinanderliegende Quellen —
verschachtelte Mounts, da der eingebaute `/workspace/.claude`-Mount sie sonst
verdecken würde:

- `intern/` — geteiltes murc134-Repo, **read-only**, wird bei jedem Start
  frisch geklont (`fresh`-Modus).
- `private/` — projektlokal (`workspace/.claude/<bereich>/private`), rw.

Host-globale `~/.claude/<bereich>/`-Mounts gibt es nicht mehr: sie waren mit
`intern/` redundant (gleiche Inhalte, doppelt gemountet) und sind aus den
Launchern entfernt. Wer im `intern/`-Repo etwas ergänzen will, pusht direkt
in `murc134/Claude-{Skills,Commands,Agents}`.

**Regel für neue Skills/Commands/Agents:** Wird ein Skill, Command oder Agent
für den Nutzer erstellt, **immer zuerst fragen**, ob er ins geteilte
`intern/`-Repo (Push nach `murc134/Claude-…`) oder nach `private/`
(projektlokal, kein Push) gehört. Sagt der Nutzer nichts, ist die Vorgabe
**privat**. Diese Regel steht auch in `INITIAL_PROMPT.md`, damit der
Claude-Code im Container sie befolgt.

## Mounts in `.bindings`

`.bindings` ist eine reine Mount-Config (keine Markdown-Datei). Parser-Regeln:

- Leerzeilen und `#`-Kommentare werden ignoriert.
- Zeilen `<host>=<container>[:ro|:rw]` definieren Mounts. Container-Pfad muss
  unter `/workspace/` liegen (außer den reservierten `/workspace` und
  `/workspace/.claude`).
- Zeilen `!<glob>` definieren globale Excludes (siehe unten).
- Alles andere wirft eine Warnung. Keine Codefence-/Listen-/Tabellen-Logik mehr.

Der Launcher (`update_managed_bindings` / `Update-ManagedBindings`) schreibt die
`.claude`-Mounts plus den Repo-Skill-Ordner (`skills/`) bei jedem Start in
einen Block zwischen `# >>> SENITY-VERWALTET … >>>` und
`# <<< SENITY-VERWALTET <<<`. Der Block wird jedes Mal neu erzeugt, **nichts
darin von Hand editieren**. Eigene Einträge außerhalb der Marker bleiben
unangetastet.

### Projekt-Mounts via `workspace/projects/`

`senity-workspace` und alle weiteren Projekt-Repos liegen unter
`workspace/projects/<name>` direkt im Repo. Da `workspace/` ohnehin nach
`/workspace` im Container gemountet wird, sind sie automatisch unter
`/workspace/projects/<name>` sichtbar, ohne dass Mounts in `.bindings`
oder eine separate Konfig-Datei nötig wären.

- `senity-workspace` wird vom Launcher als `pull`-Repo verwaltet
  (`workspace/projects/senity-workspace`).
- Weitere Repos klont der Nutzer im Container über den Skill
  `/include-git-repository <url>`. Der Skill legt das Repo unter
  `/workspace/projects/<name>` an und nutzt damit ebenfalls den
  vorhandenen `/workspace`-Mount, kein Container-Neustart nötig.

### Excludes (`!`-Pattern)

Zeilen in `.bindings`, die mit `!` beginnen, sind Glob-Pattern im
`.gitignore`-Stil. Sie gelten **global** für alle Mounts. Der Launcher scannt
jeden Mount-Source nach Treffern und mountet pro Treffer einen leeren
Read-Only-Ordner (`.mount-stage/empty/`) über den exkludierten Pfad. Dadurch
verschwinden z.B. `node_modules` oder `.git`-Ordner im Container, ohne dass der
Host-Mount verändert wird, ohne Symlinks und ohne Admin-Rechte. Re-Scan bei
jedem Launcher-Start, sodass neu entstandene `node_modules` automatisch
erfasst werden.

## INITIAL_PROMPT.md

Wird bei jedem Start gelesen, HTML-Kommentarblöcke (`<!-- … -->`) entfernt, der
gereinigte Rest in `workspace/.senity-initial-prompt` geschrieben (gitignored,
oneshot) und via Env-Var `SENITY_INITIAL_PROMPT_FILE` ans Container-Entrypoint
durchgereicht. Der Entrypoint hängt den Inhalt als letztes Positional-Argument
an `claude` an, sodass er als **sichtbare erste User-Nachricht** im Chat
landet. Gibt der Nutzer beim Launcher-Aufruf einen eigenen Positional-Prompt
mit (z.B. `claude-senity.ps1 "do X"`), wird die Datei nicht geschrieben und
der User-Prompt hat Vorrang. Dynamisch, **kein Rebuild** nötig.

Zusätzlich spiegelt der Launcher `INITIAL_PROMPT.md` beim Start bidirektional
zwischen Repo-Root und `workspace/projects/autostart/INITIAL_PROMPT.md`
(`sync_autostart_initial_prompt` / `Sync-AutostartInitialPrompt`). Die
Workspace-Kopie liegt im gitignorierten `workspace/`-Baum und ist im Container
über den vorhandenen `/workspace`-Mount unter
`/workspace/projects/autostart/INITIAL_PROMPT.md` erreichbar, ohne separaten
File-Bind-Mount. Newer-wins-Regel: wer das jüngere `mtime` hat (Repo-Root vs.
Workspace-Kopie), gewinnt und überschreibt die andere Seite. Edits aus dem
Container propagieren beim nächsten Launcher-Start auf die committete
Repo-Root-Datei.

Hintergrund: Der ursprünglich verwendete File-Bind-Mount (`INITIAL_PROMPT.md`
nach `/workspace/projects/autostart/INITIAL_PROMPT.md`) scheitert auf
Docker Desktop macOS (virtiofs) mit `mountpoint is outside of rootfs`, weil
Docker einen geschachtelten File-Mount in einen bereits gemounteten Pfad nicht
über virtiofs zustellen kann. Die Sync-Lösung umgeht das ohne nested mount und
funktioniert plattformübergreifend.

## Codex- und Gemini-CLI im Container

Das Image installiert zusätzlich zur Claude Code CLI auch `@openai/codex` und
`@google/gemini-cli` (jeweils soft-fail, falls npm-Registry temporär nicht
erreichbar ist). Beide melden sich per **OAuth** an (kein API-Key, keine
Kosten), Tokens landen unter `$HOME/.codex/` bzw. `$HOME/.gemini/` und
persistieren automatisch über den `/workspace`-Mount.

**Login: lazy beim ersten Skill-Aufruf, nicht separat.** Es gibt keinen
eigenständigen Login-Launcher mehr. Die Skills `codex-delegator` und
`gemini-delegator` (Repo `murc134/Claude-Skills`) prüfen vor dem ersten
Aufruf, ob `/workspace/.codex/auth.json` bzw. `/workspace/.gemini/oauth_creds.json`
existiert. Fehlt das Token, instruiert der Skill den User: in einem zweiten
Terminal `docker exec -it <container> codex login` (bzw. `gemini`) ausführen
(Container-Name kommt vom Skill aus `$HOSTNAME` mit), OAuth-Flow durchklicken,
danach Skill erneut anstoßen. Tokens bleiben über den
`/workspace`-Mount persistent — einmal anmelden, alle künftigen Container-Starts
sind authentifiziert.

Re-Login: `workspace/.codex/` bzw. `workspace/.gemini/` löschen, beim nächsten
Skill-Trigger triggert der Auth-Check den Login-Hinweis erneut.

## MCP-Server-Sync

Vorkonfigurierte MCP-Server (Asana, Trello, ticketing, …) liegen im Repo
`senity/senity-mcps` (s.o.), das beim Start nach
`workspace/.mcp/senity-mcps/` geklont/gepullt wird. Customer-spezifische
Secrets (API-Tokens) **niemals** in dieses Repo committen.

**Zwei Quellen, eine Merge-Regel** (im `docker-entrypoint.sh`):

1. **Repo-Defaults** — `workspace/.mcp/senity-mcps/mcpServers.json`
   (read-only, vom Senity-Team gepflegt). Enthält `command`, `args`, neutrale
   `env`-Keys wie `TICKETING_MICROSERVICE_URL`. Keine Credentials.
2. **User-Config** — `workspace/.mcp-config.json` (gitignored, vom Customer
   gepflegt). Liefert pro Server `env`-Overrides (Auth-Tokens) und kann
   eigene zusätzliche Server definieren. Template: `mcp-config.example.json`
   im Repo-Root.

Der Entrypoint mergt beide via `jq -s '.[0] * .[1]'` (Deep-Merge, User-Werte
gewinnen) und schreibt das Resultat als top-level `mcpServers` in
`${HOME}/.claude.json`. Existiert nur eine der beiden Quellen, gewinnt diese.

**node_modules.** Im Repo enthaltene MCPs werden per `npx tsx` direkt aus
`src/` gestartet (kein Build-Step). Beim ersten Start nach Klon installiert
der Entrypoint `npm install` einmalig pro `<mcp>/`-Unterordner mit
`package.json`; danach bleibt `node_modules` dank `pull`-Modus persistent.
Deshalb ist senity-mcps absichtlich **kein `fresh`-Repo** — sonst wären die
Deps bei jedem Start weg.

**Identität.** MCPs wie ticketing-mcp identifizieren den User über ihren
Bearer-Token; jeder Customer trägt seinen eigenen `stsk_*`-Token in
`workspace/.mcp-config.json` ein. Das Backend matched den Token-Hash
server-seitig gegen den User-Account.

## Gotchas

- **`fresh`-Repos vernichten lokale Änderungen:** Die drei `intern/`-Repos werden
  bei jedem Start gelöscht und neu geklont. `senity-workspace` ist deshalb `pull`.
- **`senity-workspace` liegt unter `workspace/projects/`:** Der Launcher
  klont/pullt nach `workspace/projects/senity-workspace`. Weitere Repos
  legt der Skill `/include-git-repository` unter `workspace/projects/<name>`
  ab und nutzt damit den vorhandenen `/workspace`-Mount.
- **Klartext-Deploy-Keys in `.env.shared`:** base64 ist keine Verschlüsselung;
  Secret-Scanning kann anschlagen. Bewusst so entschieden.
- **`murc134/*`-Deploy-Keys** müssen von `murc134` eingetragen werden, der
  `senity-workspace`-Key in GitLab (`git.senity.ai`) — bis dahin greift der
  `~/.ssh`-Fallback.
- **Host-Abhängigkeiten:** Das Repo-Setup läuft auf dem Host und braucht dort
  `git` — der Launcher (`ensure_git` / `Ensure-Git`) installiert es bei Bedarf
  automatisch (winget / Homebrew·Xcode CLT / apt·dnf·pacman·zypper). Docker
  Desktop wird analog über `Ensure-DockerDesktop` / `ensure_docker` best effort
  installiert (winget auf Windows, Homebrew Cask auf macOS). Linux: kein
  Auto-Install (Engine-Setup ist distrospezifisch und root-pflichtig), Hinweis
  auf docs.docker.com. Auf Windows läuft vorab `Ensure-WSL`: prüft, ob `wsl`
  vorhanden und **modern** ist. Detection via `wsl --version` (Test-ModernWSL):
  - Fehlt `wsl.exe` → `winget install --id Microsoft.WSL -e` (UAC).
  - Inbox-WSL erkannt (Windows-10-19041-Variante in `C:\Windows\System32\wsl.exe`,
    kennt weder `--version` noch `--update`) → ebenfalls
    `winget install Microsoft.WSL`, danach `exit 0` mit Hinweis Terminal-Neustart.
  - Moderne WSL vorhanden → `wsl --update` läuft nur mit `-UpdateWsl`-Flag,
    sonst übersprungen (Auto-Update hat in der Praxis laufende Docker-Distros
    abgeschossen, ERROR_ALREADY_EXISTS beim Re-Import).
  Docker Desktop bzw. WSL-Install können beim ersten Start einen Reboot
  erzwingen. `npm`/`npx` braucht nur der Container (im Image), nicht der Host.
