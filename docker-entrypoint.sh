#!/bin/bash
set -euo pipefail

# ── Senity Workspace Container Entry Point ──

# Config-Directory existenz pruefen
if [[ ! -d /home/node/.claude ]]; then
    mkdir -p /home/node/.claude
fi

exec "$@"
