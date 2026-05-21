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
Rest via `--append-system-prompt` an Claude Code übergeben. Dynamisch —
Änderungen wirken sofort, **kein Rebuild** nötig.

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
  automatisch (winget / Homebrew·Xcode CLT / apt·dnf·pacman·zypper). `npm`/`npx`
  braucht nur der Container (im Image), nicht der Host.
