# Senity Workspace — Mount-Pfade
# Format: <host-pfad>=<container-pfad>
# Kommentare beginnen mit #, leere Zeilen werden ignoriert
#
# Host-Pfad:      beliebiges Verzeichnis — absolut (/Users/..., C:\Users\...),
#                 per ~ (~/projekte/foo) oder relativ zum Projektverzeichnis
#                 (../mein-projekt).
# Container-Pfad: muss unterhalb von /workspace/ liegen (z.B. /workspace/mein-repo).
#                 /workspace selbst und /workspace/.claude sind reserviert.

# Hier eigene Projekt-Verzeichnisse eintragen (workspace ist bereits eingebunden):
# ~/projekte/mein-repo=/workspace/mein-repo
# /Users/ich/code/api=/workspace/api
# ../nachbar-projekt=/workspace/nachbar
