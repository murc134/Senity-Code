#!/bin/bash
set -euo pipefail

echo "Senity Workspace Container gestartet"
echo "  Home:   $(whoami)"
echo "  PWD:    $(pwd)"
echo "  MODEL:  ${ANTHROPIC_BASE_URL:-nicht gesetzt}"

# Git-Konfiguration aus Host-Share wenn vorhanden
if [[ -f /workspace/.gitconfig ]]; then
    cp /workspace/.gitconfig /home/node/.gitconfig
fi

exec "$@"
