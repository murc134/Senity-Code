#!/usr/bin/env bash
# senity-start.sh - Host-Wrapper fuer Customer-Deployment (Linux / macOS).
#
# Verkettung:
#   1. Pre-Check senity-CLI vorhanden.
#   2. senity gitea-token --ensure-fresh --write-docker-config (Auto-Recovery
#      via senity gitea-login bei Exit 2 / 3).
#   3. docker compose pull + up -d.
#   4. Interaktive Session via docker compose exec.
#
# Exit-Code-Verarbeitung (siehe ~/.claude/.../reference_gitea_device_flow_params):
#   0 = ok                          -> weiter
#   2 = auth.json fehlt             -> einmalig 'senity gitea-login', retry
#   3 = refresh_token invalid_grant -> einmalig 'senity gitea-login', retry
#   4 = expired_token / 5 = access_denied / 6 = Netzwerk
#                                   -> abbrechen mit klarer Fehlermeldung

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
COMPOSE_DIR="${SENITY_COMPOSE_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
SERVICE="${SENITY_COMPOSE_SERVICE:-senity-code}"
COMMAND_IN_CONTAINER=("${SENITY_CONTAINER_CMD:-senity-mascot-filter}" "claude")

log()  { printf '\033[38;5;141m[senity-start]\033[0m %s\n' "$*"; }
warn() { printf '\033[38;5;214m[senity-start]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[38;5;199m[senity-start]\033[0m %s\n' "$*" >&2; }

# ---- Vorbedingungen ---------------------------------------------------------
if ! command -v senity >/dev/null 2>&1; then
    err "senity-CLI nicht gefunden. Installation: install.sh aus senity-cli/."
    exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
    err "docker nicht gefunden. Bitte Docker installieren."
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    err "Docker-Daemon laeuft nicht."
    exit 1
fi
if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "docker-compose.yml nicht gefunden unter $COMPOSE_FILE"
    err "Setze SENITY_COMPOSE_DIR falls dein Layout abweicht."
    exit 1
fi

# ---- Schritt 1: Frischer Access-Token + Docker-Login-Patch ------------------
ensure_token() {
    local attempt="$1"  # 1 = erster Versuch, 2 = nach gitea-login
    set +e
    senity gitea-token --ensure-fresh --write-docker-config
    local rc=$?
    set -e
    case "$rc" in
        0)
            return 0
            ;;
        2|3)
            if [[ "$attempt" = "2" ]]; then
                err "Auth-Recovery fehlgeschlagen (Exit $rc nach Re-Login)."
                exit "$rc"
            fi
            log "Kein gueltiger Token (Exit $rc). Starte Device-Login..."
            set +e
            senity gitea-login
            local lc=$?
            set -e
            if [[ "$lc" -ne 0 ]]; then
                err "senity gitea-login fehlgeschlagen (Exit $lc)."
                exit "$lc"
            fi
            ensure_token 2
            return $?
            ;;
        4)
            err "Device-Code abgelaufen, bitte Aufruf wiederholen."
            exit 4
            ;;
        5)
            err "Login wurde abgelehnt."
            exit 5
            ;;
        6)
            err "Netzwerkfehler beim Token-Refresh."
            exit 6
            ;;
        *)
            err "Unerwarteter Exit-Code $rc von 'senity gitea-token'."
            exit "$rc"
            ;;
    esac
}

log "Pruefe Gitea-Auth + erneuere Token bei Bedarf"
ensure_token 1

# ---- Schritt 2: Image pullen, Container hochfahren --------------------------
log "Pulle aktuelles Image"
( cd "$COMPOSE_DIR" && docker compose pull "$SERVICE" )

log "Stelle sicher dass Container laeuft"
( cd "$COMPOSE_DIR" && docker compose up -d "$SERVICE" )

# ---- Schritt 3: Interaktive Session -----------------------------------------
log "Oeffne Session in $SERVICE"
exec docker compose -f "$COMPOSE_FILE" exec -it "$SERVICE" "${COMMAND_IN_CONTAINER[@]}" "$@"
