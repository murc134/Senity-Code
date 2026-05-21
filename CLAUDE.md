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
| `SYSTEM_PROMPT.md` | Wird bei jedem Start gelesen und Claude Code via `--append-system-prompt` mitgegeben |
| `Bindings.md` | Host→Container-Mounts; enthält den auto-verwalteten Repo-Mount-Block |

Die `.sh`/`.ps1`/`.bat` müssen funktional **gleichwertig** bleiben. Die `.bat`
ist ein reiner pwsh-Bootstrap — sie ruft `claude-senity.ps1 %*` auf und enthält
selbst keine Launcher-Logik; jede `.ps1`-Änderung wirkt automatisch auch über
die `.bat`.

## Verwaltete Repos & Deploy-Keys

Vor dem Container-Start klont/pullt der Launcher vier fest hinterlegte Repos
(`MANAGED_REPO_*` / `$ManagedRepos`).

| Repo | Klon-Ziel (Host) | Modus |
|---|---|---|
| `senity/senity-workspace` (git.senity.ai:2200) | `workspace/senity-workspace` | `pull` |
| `murc134/Claude-Skills` | `workspace/.claude/skills/intern` | `fresh` |
| `murc134/Claude-Commands` | `workspace/.claude/commands/intern` | `fresh` |
| `murc134/Claude-Agents` | `workspace/.claude/agents/intern` | `fresh` |

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

## `.claude`-Dreiteilung

Pro Bereich (`skills`/`commands`/`agents`) drei nebeneinanderliegende Quellen —
verschachtelte Mounts, da der eingebaute `/workspace/.claude`-Mount sie sonst
verdecken würde:

- `intern/` — geteiltes murc134-Repo, **read-only**.
- `global/` — host-globales `~/.claude/<bereich>/`, rw (nur wenn vorhanden).
- `private/` — projektlokal (`workspace/.claude/<bereich>/private`), rw.

**Regel für neue Skills/Commands/Agents:** Wird ein Skill, Command oder Agent
für den Nutzer erstellt, **immer zuerst fragen**, ob er *global* oder *privat*
sein soll — global → `…/global/`, privat → `…/private/`. Sagt der Nutzer nichts,
ist die Vorgabe **privat**. Diese Regel steht auch in `SYSTEM_PROMPT.md`, damit
der Claude-Code im Container sie befolgt.

## Mounts in `Bindings.md`

Der Launcher (`update_managed_bindings` / `Update-ManagedBindings`) schreibt die
neun `.claude`-Mounts bei jedem Start in einen Block zwischen
`# >>> SENITY-VERWALTET … >>>` und `# <<< SENITY-VERWALTET <<<`. Der Block wird
jedes Mal neu erzeugt — **nichts darin von Hand editieren**. Eigene Einträge
außerhalb der Marker bleiben unangetastet. `senity-workspace` braucht keinen
Eintrag (liegt in `workspace/`, via `/workspace`-Mount schon sichtbar).

## SYSTEM_PROMPT.md

Wird bei jedem Start gelesen, HTML-Kommentarblöcke (`<!-- … -->`) entfernt, der
gereinigte Rest in `workspace/.senity-initial-prompt` geschrieben (gitignored,
oneshot) und via Env-Var `SENITY_INITIAL_PROMPT_FILE` ans Container-Entrypoint
durchgereicht. Der Entrypoint hängt den Inhalt als letztes Positional-Argument
an `claude` an, sodass er als **sichtbare erste User-Nachricht** im Chat
landet. Gibt der Nutzer beim Launcher-Aufruf einen eigenen Positional-Prompt
mit (z.B. `claude-senity.ps1 "do X"`), wird die Datei nicht geschrieben und
der User-Prompt hat Vorrang. Dynamisch, **kein Rebuild** nötig.

## Codex- und Gemini-CLI im Container

Das Image installiert zusätzlich zur Claude Code CLI auch `@openai/codex` und
`@google/gemini-cli` (jeweils soft-fail, falls npm-Registry temporär nicht
erreichbar ist). Beide melden sich per **OAuth** an (kein API-Key, keine
Kosten), Tokens landen unter `$HOME/.codex/` bzw. `$HOME/.gemini/` und
persistieren automatisch über den `/workspace`-Mount.

Vor dem Start (Phase `[5b/6]`) prüfen die Launcher, ob die Token-Dateien
existieren. Wenn nicht, wird **einmalig** mit Default `n` gefragt, ob der
jeweilige Account angebunden werden soll. Bei `y` startet ein kurzlebiger
Container für den interaktiven `codex login` bzw. `gemini auth login`. Sobald
Tokens persistiert sind, wird der Prompt bei späteren Starts nicht mehr
gezeigt. Manuelles Re-Login: einfach `workspace/.codex/` bzw.
`workspace/.gemini/` löschen.

## Gotchas

- **`fresh`-Repos vernichten lokale Änderungen:** Die drei `intern/`-Repos werden
  bei jedem Start gelöscht und neu geklont. `senity-workspace` ist deshalb `pull`.
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
  vorhanden ist (sonst `wsl --install --no-distribution` mit UAC) und führt
  immer `wsl --update` aus, damit der WSL2-Kernel aktuell ist (Docker Desktop
  startet sonst stillschweigend nicht). Docker Desktop bzw. WSL-Install können
  beim ersten Start einen Reboot erzwingen. `npm`/`npx` braucht nur der
  Container (im Image), nicht der Host.
