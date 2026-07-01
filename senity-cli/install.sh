#!/usr/bin/env bash
# Senity CLI Installer (Linux / macOS).
# Installiert das `senity`-Wrapper-Script nach ~/.local/bin/senity.
#
# Quick-Install:
#   curl -fsSL https://git.senity.ai/senity-admin/senity-claude-code/raw/branch/main/senity-cli/install.sh | bash
#
# Lokal aus dem Repo:
#   ./senity-cli/install.sh

set -euo pipefail

INSTALL_DIR="${SENITY_INSTALL_DIR:-${HOME}/.local/bin}"
SHARE_DIR="${SENITY_SHARE_DIR:-${HOME}/.local/share/senity}"
LIB_DIR="${SHARE_DIR}/lib"
TARGET="${INSTALL_DIR}/senity"
RAW_URL="https://git.senity.ai/senity-admin/senity-claude-code/raw/branch/main/senity-cli/senity.sh"
LIB_RAW_URL="https://git.senity.ai/senity-admin/senity-claude-code/raw/branch/main/senity-cli/lib/gitea-device-flow.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

log()  { printf '\033[38;5;141m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[38;5;214m[install]\033[0m %s\n' "$*"; }
err()  { printf '\033[38;5;199m[install]\033[0m %s\n' "$*" >&2; }

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Benoetigt: $1 (nicht gefunden)"
        exit 1
    fi
}

require bash
mkdir -p "$INSTALL_DIR" "$LIB_DIR"

# Lokale Quelle bevorzugen (Repo-Install), sonst Download.
if [[ -f "${SCRIPT_DIR}/senity.sh" ]]; then
    log "Kopiere ${SCRIPT_DIR}/senity.sh -> $TARGET"
    cp "${SCRIPT_DIR}/senity.sh" "$TARGET"
else
    require curl
    log "Lade $RAW_URL -> $TARGET"
    curl -fsSL "$RAW_URL" -o "$TARGET"
fi

# Lib (gitea-device-flow) mit-installieren
if [[ -f "${SCRIPT_DIR}/lib/gitea-device-flow.sh" ]]; then
    log "Kopiere lib/gitea-device-flow.sh -> ${LIB_DIR}/gitea-device-flow.sh"
    cp "${SCRIPT_DIR}/lib/gitea-device-flow.sh" "${LIB_DIR}/gitea-device-flow.sh"
else
    require curl
    log "Lade $LIB_RAW_URL -> ${LIB_DIR}/gitea-device-flow.sh"
    curl -fsSL "$LIB_RAW_URL" -o "${LIB_DIR}/gitea-device-flow.sh"
fi
chmod 0644 "${LIB_DIR}/gitea-device-flow.sh"

chmod +x "$TARGET"
log "Installiert: $TARGET"
log "Lib-Dir:     $LIB_DIR"

# PATH-Check
case ":$PATH:" in
    *":${INSTALL_DIR}:"*)
        log "$INSTALL_DIR ist bereits im PATH."
        ;;
    *)
        warn "$INSTALL_DIR ist NICHT im PATH."
        warn "Fuege in deine Shell-Config (~/.bashrc, ~/.zshrc, ~/.profile) ein:"
        warn "    export PATH=\"$INSTALL_DIR:\$PATH\""
        ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    warn "Docker ist nicht installiert. Senity benoetigt Docker Desktop / docker-engine."
    warn "  macOS:   brew install --cask docker"
    warn "  Linux:   https://docs.docker.com/engine/install/"
fi

log "Fertig. Test mit: senity --help"
log "Erst-Login:   senity login"
