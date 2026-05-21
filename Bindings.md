# Senity Workspace — Mount-Pfade
# Format: <host-pfad>=<container-pfad>[:ro|:rw]
# Kommentare beginnen mit #, leere Zeilen werden ignoriert
#
# Host-Pfad:      beliebiges Verzeichnis — absolut (/Users/..., C:\Users\...),
#                 per ~ (~/projekte/foo) oder relativ zum Projektverzeichnis
#                 (../mein-projekt). Leerzeichen erlaubt; umschliessende
#                 '/" werden abgestreift.
# Container-Pfad: muss unterhalb von /workspace/ liegen (z.B. /workspace/mein-repo).
#                 /workspace selbst und /workspace/.claude sind reserviert.
# Modus:          optionales :ro (nur lesen) oder :rw (lesen+schreiben) am
#                 Container-Pfad. Ohne Angabe: rw.

# Hier eigene Projekt-Verzeichnisse eintragen (workspace ist bereits eingebunden):
# ~/projekte/mein-repo=/workspace/mein-repo
# /Users/ich/code/api=/workspace/api
# ../nachbar-projekt=/workspace/nachbar
/Users/user/Development/Claude Workspace=/workspace/msh
/Users/user/Development/SWorkspace=/workspace/senity:rw
/Users/user/Development/KI Anwälte=/workspace/anwalt:ro
'/Users/user/Development/Webseite Fricke'=/workspace/fricke

# >>> SENITY-VERWALTET (auto-generiert vom Repo-Setup) >>>
# Auto-generiert vom Repo-Setup — Aenderungen hier werden bei jedem
# Start ueberschrieben. senity-workspace liegt direkt in workspace/
# und ist dadurch bereits unter /workspace/... sichtbar.
workspace/.claude/skills/intern=/workspace/.claude/skills/intern:ro
workspace/.claude/skills/private=/workspace/.claude/skills/private:rw
~/.claude/skills=/workspace/.claude/skills/global:rw
workspace/.claude/commands/intern=/workspace/.claude/commands/intern:ro
workspace/.claude/commands/private=/workspace/.claude/commands/private:rw
~/.claude/commands=/workspace/.claude/commands/global:rw
workspace/.claude/agents/intern=/workspace/.claude/agents/intern:ro
workspace/.claude/agents/private=/workspace/.claude/agents/private:rw
~/.claude/agents=/workspace/.claude/agents/global:rw
# <<< SENITY-VERWALTET <<<
