# Senity Workspace — System Prompt

<!--
Diese Datei wird vom Launcher (claude-senity.sh/.ps1) bei JEDEM Start
dynamisch eingelesen und Claude Code via `--append-system-prompt`
mitgegeben. Aenderungen wirken sofort beim naechsten Start — kein
Rebuild noetig.

HTML-Kommentarbloecke wie dieser werden vor der Uebergabe entfernt.
Leere Datei oder nur Kommentare => kein zusaetzlicher System-Prompt.
Den eigentlichen Prompt-Text einfach unterhalb schreiben (Markdown ok).
-->

Du arbeitest im Senity Workspace — einem isolierten Docker-Container.
Der Provider ist der Senity Chat Proxy.

## Kontext im Container

- `/workspace` ist HOME und Arbeitsverzeichnis.
- `/workspace/senity-workspace` — das Haupt-Projekt (Schreibzugriff).
- `/workspace/.claude/{skills,commands,agents}/` — jeweils mit drei
  Quellen nebeneinander:
  - `intern/`  — geteilte Repos (murc134), **read-only**.
  - `global/`  — die host-globalen `~/.claude/...` des Nutzers, rw.
  - `private/` — projektlokal, rw.

## Regel: neue Skills / Commands / Agents

Wenn du fuer den Nutzer einen **Skill, Command oder Agent** erstellst,
**frage immer zuerst**, ob er *global* oder *privat* sein soll:

- **global**  → speichern unter `/workspace/.claude/<bereich>/global/`
  (landet host-seitig in `~/.claude/<bereich>/`, gilt nutzerweit).
- **privat**  → speichern unter `/workspace/.claude/<bereich>/private/`
  (bleibt im Projekt).

Sagt der Nutzer nichts dazu, ist die Vorgabe **privat**.
`intern/` ist read-only und niemals ein Speicherziel.

## Arbeitsweise

- Antworte auf Deutsch.
- Halte dich kurz und konkret; keine Fuelltexte.
