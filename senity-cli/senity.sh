#!/usr/bin/env bash
# senity — globaler CLI-Wrapper fuer den Senity-Workspace-Container.
# Startet einen Ad-hoc-Container mit dem aktuellen cwd als /workspace/cwd.
#
# Defaults:
#   - Image:           git.senity.ai/senity-admin/senity-claude-code:latest
#                      Fallback (kein Pull moeglich): senity-claude:latest
#   - Auto-Update:     bei jedem Start (Image + Cache + MCPs). --skip-update ueberspringt.
#   - Yolo-Mode:       an (Container ist isoliert). --no-yolo deaktiviert.
#
# Usage:
#   senity                          Container starten, Claude Code an
#   senity --skip-update            Ohne docker pull / git pull
#   senity --no-yolo                Permission-Prompts aktivieren
#   senity --mount H:C[:ro]         Zusatz-Mount (mehrfach erlaubt)
#   senity --image <ref>            Image-Tag ueberschreiben
#   senity login                    Senity-Proxy-Key einrichten
#   senity comfyui                  ComfyUI Server starten
#   senity --help                   Hilfe

set -euo pipefail

# ---- Konstanten -------------------------------------------------------------
SENITY_HOME="${SENITY_HOME:-${HOME}/.senity}"
SENITY_ENV_FILE="${SENITY_HOME}/.env"
SENITY_MCP_CONFIG="${SENITY_HOME}/mcp-config.json"
SENITY_CACHE_DIR="${SENITY_HOME}/cache"
SENITY_WORKSPACE_DIR="${SENITY_HOME}/workspace"

# ---- Lib-Loader (Dev-Mode + Installed-Layout) -------------------------------
SENITY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SENITY_LIB_DIR=""
for _cand in \
    "${SENITY_SCRIPT_DIR}/lib" \
    "${SENITY_SCRIPT_DIR}/../share/senity/lib" \
    "${HOME}/.local/share/senity/lib" \
    "/usr/local/share/senity/lib"; do
    if [[ -f "${_cand}/gitea-device-flow.sh" ]]; then
        SENITY_LIB_DIR="$_cand"
        break
    fi
done
unset _cand
if [[ -n "$SENITY_LIB_DIR" ]]; then
    # shellcheck disable=SC1091
    source "${SENITY_LIB_DIR}/gitea-device-flow.sh"
    SENITY_GITEA_AVAILABLE=1
else
    SENITY_GITEA_AVAILABLE=0
fi

DEFAULT_IMAGE="git.senity.ai/senity-admin/senity-claude-code:latest"
FALLBACK_IMAGE="senity-claude:latest"
DEFAULT_PROXY_URL="https://sdr.senity.ai/api/claude-proxy"

SKILLS_REPO_URL="git@github.com:murc134/Claude-Skills.git"
COMMANDS_REPO_URL="git@github.com:murc134/Claude-Commands.git"
AGENTS_REPO_URL="git@github.com:murc134/Claude-Agents.git"
MCPS_REPO_URL="ssh://git@git.senity.ai:2200/senity/senity-mcps.git"

# ---- Logging ----------------------------------------------------------------
log()  { printf '\033[38;5;141m[senity]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[38;5;214m[senity]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[38;5;199m[senity]\033[0m %s\n' "$*" >&2; }

# ---- Args -------------------------------------------------------------------
SKIP_UPDATE=0
YOLO=1
EXTRA_MOUNTS=()
IMAGE_OVERRIDE=""
SUBCOMMAND=""
COMFYUI_PORT=8188
COMFYUI_GPU=0
CLAUDE_ARGS=()
GITEA_FLAG_HEADLESS=0
GITEA_FLAG_ENSURE_FRESH=0
GITEA_FLAG_WRITE_DOCKER=0
GITEA_FLAG_PRINT=0

print_help() {
    cat <<'EOF'
senity — Senity-Workspace-Container auf Knopfdruck

USAGE
  senity [options] [-- claude-args...]
  senity login
  senity comfyui [-- comfyui-args...]
  senity --help

OPTIONS
  --skip-update         Ueberspringt docker pull + git pull beim Start
  --no-yolo             Permission-Prompts aktivieren (Default: Yolo an)
  --yolo                Yolo explizit an (Default)
  --mount H:C[:ro]      Zusatz-Mount, mehrfach erlaubt
  --image <ref>         Image-Tag ueberschreiben
  --comfyui-port <port> Host-Port fuer ComfyUI (Default: 8188)
  --comfyui-gpu         Docker mit --gpus all starten
  --help, -h            Diese Hilfe

SUBCOMMANDS
  login                       Senity-Proxy-Key in ~/.senity/.env hinterlegen
  comfyui                     ComfyUI statt Claude Code starten
  gitea-login [--headless]    OAuth2 Device-Flow gegen git.senity.ai
  gitea-token [flags]         Frischen Access-Token bereitstellen
                                --ensure-fresh        Refresh wenn abgelaufen
                                --write-docker-config ~/.docker/config.json patchen
                                --print               Token auf stdout (NUR fuer CI)
  gitea-status                Login-Status anzeigen (Tokens werden NICHT geloggt)
  gitea-logout                Refresh-Token revoken + auth.json loeschen

EXIT-CODES (gitea-*)
  0  ok        2  auth fehlt   3  refresh invalid_grant
  4  expired   5  access_denied 6  Netzwerk / Setup-Fehler

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-update) SKIP_UPDATE=1; shift ;;
        --no-yolo)     YOLO=0; shift ;;
        --yolo)        YOLO=1; shift ;;
        --mount)       EXTRA_MOUNTS+=("$2"); shift 2 ;;
        --image)       IMAGE_OVERRIDE="$2"; shift 2 ;;
        --comfyui-port) COMFYUI_PORT="$2"; shift 2 ;;
        --comfyui-gpu) COMFYUI_GPU=1; shift ;;
        --help|-h)     print_help; exit 0 ;;
        login)         SUBCOMMAND="login"; shift ;;
        comfyui)       SUBCOMMAND="comfyui"; shift ;;
        gitea-login)   SUBCOMMAND="gitea-login"; shift ;;
        gitea-token)   SUBCOMMAND="gitea-token"; shift ;;
        gitea-status)  SUBCOMMAND="gitea-status"; shift ;;
        gitea-logout)  SUBCOMMAND="gitea-logout"; shift ;;
        --headless)            GITEA_FLAG_HEADLESS=1; shift ;;
        --ensure-fresh)        GITEA_FLAG_ENSURE_FRESH=1; shift ;;
        --write-docker-config) GITEA_FLAG_WRITE_DOCKER=1; shift ;;
        --print)               GITEA_FLAG_PRINT=1; shift ;;
        --)            shift; CLAUDE_ARGS=("$@"); break ;;
        *)             CLAUDE_ARGS+=("$1"); shift ;;
    esac
done

IMAGE="${IMAGE_OVERRIDE:-$DEFAULT_IMAGE}"

if ! [[ "$COMFYUI_PORT" =~ ^[0-9]+$ ]] || (( COMFYUI_PORT < 1 || COMFYUI_PORT > 65535 )); then
    err "--comfyui-port muss zwischen 1 und 65535 liegen."
    exit 1
fi

# ---- Prerequisites ----------------------------------------------------------
require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        err "Docker ist nicht installiert. Siehe https://docs.docker.com/engine/install/"
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        err "Docker-Daemon laeuft nicht. Bitte Docker Desktop / dockerd starten."
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "$SENITY_HOME" "$SENITY_CACHE_DIR" "$SENITY_WORKSPACE_DIR"
    chmod 700 "$SENITY_HOME"
}

# ---- Login ------------------------------------------------------------------
cmd_login() {
    ensure_dirs
    local url key
    if [[ -f "$SENITY_ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SENITY_ENV_FILE"
        url="${SENITY_CHAT_PROXY_URL:-$DEFAULT_PROXY_URL}"
        key="${SENITY_CHAT_PROXY_KEY:-}"
        log "Existierende Konfiguration: $SENITY_ENV_FILE"
    else
        url="$DEFAULT_PROXY_URL"
        key=""
    fi

    read -r -p "Senity Proxy URL [$url]: " input_url
    [[ -n "$input_url" ]] && url="$input_url"
    read -r -s -p "Senity Proxy Key: " input_key
    echo
    [[ -n "$input_key" ]] && key="$input_key"

    if [[ -z "$key" ]]; then
        err "Kein Key angegeben. Abbruch."
        exit 1
    fi

    umask 077
    cat > "$SENITY_ENV_FILE" <<EOF
SENITY_CHAT_PROXY_URL=$url
SENITY_CHAT_PROXY_KEY=$key
EOF
    log "Konfiguration geschrieben nach $SENITY_ENV_FILE (chmod 600)"
}

# ---- Gitea Device-Flow (#1059) ----------------------------------------------
require_gitea_lib() {
    if [[ "$SENITY_GITEA_AVAILABLE" -ne 1 ]]; then
        err "lib/gitea-device-flow.sh nicht gefunden. Re-Install via install.sh notwendig."
        exit 6
    fi
    gitea_require_deps || exit 6
}

cmd_gitea_login() {
    require_gitea_lib
    ensure_dirs

    # Headless-Path: Refresh-Token aus Env, kein Device-Flow noetig
    if [[ "$GITEA_FLAG_HEADLESS" -eq 1 ]]; then
        local rt="${SENITY_GITEA_RT:-}"
        if [[ -z "$rt" ]]; then
            err "SENITY_GITEA_RT muss im Headless-Mode gesetzt sein"
            exit 6
        fi
        local refreshed
        if ! refreshed=$(gitea_refresh "$rt"); then
            local rc=$?
            err "Headless-Login fehlgeschlagen (Exit ${rc})"
            exit "$rc"
        fi
        gitea_persist_auth "$refreshed" || exit 6
        gitea_log "Headless-Login ok"
        exit 0
    fi

    local init_json
    if ! init_json=$(gitea_device_init); then
        exit 6
    fi

    local user_code device_code uri uri_complete interval
    user_code=$(printf '%s' "$init_json"   | gitea_json_get user_code)
    device_code=$(printf '%s' "$init_json" | gitea_json_get device_code)
    uri=$(printf '%s' "$init_json"         | gitea_json_get verification_uri)
    uri_complete=$(printf '%s' "$init_json" | gitea_json_get verification_uri_complete)
    interval=$(printf '%s' "$init_json"    | gitea_json_get interval)
    [[ -z "$interval" || ! "$interval" =~ ^[0-9]+$ ]] && interval=5

    if [[ -z "$device_code" || -z "$user_code" || -z "$uri" ]]; then
        err "Device-Init lieferte unvollstaendige Response"
        exit 6
    fi

    gitea_show_user_code "$user_code" "$uri" "$uri_complete"
    gitea_log "Warte auf Bestaetigung (max ${GITEA_POLL_HARD_CAP}s) ..."

    local token_json rc
    if ! token_json=$(gitea_poll_token "$device_code" "$interval"); then
        rc=$?
        exit "$rc"
    fi
    gitea_persist_auth "$token_json" || exit 6
    gitea_log "Login erfolgreich, Tokens in ${GITEA_AUTH_FILE} gespeichert (0600)"
    exit 0
}

# Echo "<access_token>" auf stdout, oder exit 2/3/6
_gitea_get_fresh_access_token() {
    local auth_json freshness
    freshness=$(gitea_token_freshness)
    case "$freshness" in
        missing) return 2 ;;
        fresh)
            auth_json=$(gitea_read_auth) || return 2
            printf '%s' "$auth_json" | gitea_json_get access_token
            return 0
            ;;
        stale)
            auth_json=$(gitea_read_auth) || return 2
            local rt
            rt=$(printf '%s' "$auth_json" | gitea_json_get refresh_token)
            if [[ -z "$rt" ]]; then return 2; fi
            local refreshed
            if ! refreshed=$(gitea_refresh "$rt"); then
                return $?
            fi
            gitea_persist_auth "$refreshed" || return 6
            printf '%s' "$refreshed" | gitea_json_get access_token
            return 0
            ;;
    esac
    return 6
}

cmd_gitea_token() {
    require_gitea_lib

    # Default-Verhalten = --ensure-fresh
    if [[ "$GITEA_FLAG_ENSURE_FRESH" -eq 0 && "$GITEA_FLAG_PRINT" -eq 0 && "$GITEA_FLAG_WRITE_DOCKER" -eq 0 ]]; then
        GITEA_FLAG_ENSURE_FRESH=1
    fi

    local at
    if ! at=$(_gitea_get_fresh_access_token); then
        exit $?
    fi

    if [[ "$GITEA_FLAG_WRITE_DOCKER" -eq 1 ]]; then
        gitea_write_docker_config "$at" || exit 6
        gitea_log "Docker-Config aktualisiert: ${DOCKER_CONFIG_FILE}"
    fi

    if [[ "$GITEA_FLAG_PRINT" -eq 1 ]]; then
        printf '%s\n' "$at"
    fi

    if [[ "$GITEA_FLAG_ENSURE_FRESH" -eq 1 && "$GITEA_FLAG_WRITE_DOCKER" -eq 0 && "$GITEA_FLAG_PRINT" -eq 0 ]]; then
        gitea_log "Access-Token frisch"
    fi
    exit 0
}

cmd_gitea_status() {
    require_gitea_lib
    local auth_json
    if ! auth_json=$(gitea_read_auth); then
        printf 'Status: nicht eingeloggt\n'
        printf 'Aktion: senity gitea-login\n'
        exit 0
    fi
    local user user_id exp scopes connected freshness
    user=$(printf '%s'      "$auth_json" | gitea_json_get gitea_user)
    user_id=$(printf '%s'   "$auth_json" | gitea_json_get gitea_user_id)
    exp=$(printf '%s'       "$auth_json" | gitea_json_get access_token_expires_at)
    scopes=$(printf '%s'    "$auth_json" | gitea_json_get scopes)
    connected=$(printf '%s' "$auth_json" | gitea_json_get connected_at)
    freshness=$(gitea_token_freshness)

    printf 'Status:        eingeloggt (%s)\n' "$freshness"
    printf 'Gitea-User:    %s (ID %s)\n' "${user:-?}" "${user_id:-?}"
    printf 'Host:          %s\n' "$GITEA_HOST"
    printf 'Scopes:        %s\n' "$scopes"
    printf 'Verbunden:     %s\n' "$(date -d "@${connected:-0}" 2>/dev/null || echo "${connected}")"
    printf 'AT-Expires:    %s\n' "$(date -d "@${exp:-0}" 2>/dev/null || echo "${exp}")"
    printf 'Auth-File:     %s\n' "$GITEA_AUTH_FILE"
    printf 'Docker-Config: %s\n' "$DOCKER_CONFIG_FILE"
    exit 0
}

cmd_gitea_logout() {
    require_gitea_lib
    if [[ -f "$GITEA_AUTH_FILE" ]]; then
        local rt
        rt=$(gitea_read_auth | gitea_json_get refresh_token || true)
        [[ -n "$rt" ]] && gitea_revoke "$rt"
        rm -f "$GITEA_AUTH_FILE"
        gitea_log "auth.json geloescht, Refresh-Token revoked"
    else
        gitea_log "Kein Login vorhanden"
    fi

    # Docker-Auth fuer Gitea-Host entfernen (best-effort)
    if [[ -f "$DOCKER_CONFIG_FILE" ]]; then
        local host="${GITEA_HOST#https://}"
        local existing; existing=$(cat "$DOCKER_CONFIG_FILE")
        SENITY_EXISTING="$existing" SENITY_HOST_NAME="$host" python3 <<'PY' | gitea_atomic_write "$DOCKER_CONFIG_FILE" 0600 || true
import os, json
try:
    cfg = json.loads(os.environ['SENITY_EXISTING'])
    if not isinstance(cfg, dict): cfg = {}
except Exception:
    cfg = {}
auths = cfg.get('auths', {})
auths.pop(os.environ['SENITY_HOST_NAME'], None)
cfg['auths'] = auths
print(json.dumps(cfg, indent=2))
PY
        gitea_log "Docker-Auth fuer ${host} entfernt"
    fi
    exit 0
}

# ---- Auth-Check -------------------------------------------------------------
load_env() {
    if [[ ! -f "$SENITY_ENV_FILE" ]]; then
        warn "Kein Proxy-Key konfiguriert. Starte 'senity login'..."
        cmd_login
    fi
    # shellcheck disable=SC1090
    source "$SENITY_ENV_FILE"
    : "${SENITY_CHAT_PROXY_URL:=$DEFAULT_PROXY_URL}"
    if [[ -z "${SENITY_CHAT_PROXY_KEY:-}" ]]; then
        err "SENITY_CHAT_PROXY_KEY fehlt in $SENITY_ENV_FILE."
        exit 1
    fi
}

# ---- Update -----------------------------------------------------------------
update_repo() {
    local url="$1" dest="$2"
    if [[ -d "$dest/.git" ]]; then
        if ! git -C "$dest" pull --ff-only --quiet 2>/dev/null; then
            warn "git pull fehlgeschlagen fuer $dest (offline?), nutze lokalen Stand"
        fi
    else
        rm -rf "$dest"
        if ! git clone --quiet --depth 1 "$url" "$dest" 2>/dev/null; then
            warn "git clone fehlgeschlagen fuer $url, ueberspringe"
        fi
    fi
}

do_update() {
    log "Update laeuft (--skip-update zum Ueberspringen)"
    if ! docker pull --quiet "$IMAGE" >/dev/null 2>&1; then
        warn "docker pull fehlgeschlagen fuer $IMAGE"
        if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            if docker image inspect "$FALLBACK_IMAGE" >/dev/null 2>&1; then
                warn "Fallback auf lokales Image $FALLBACK_IMAGE"
                IMAGE="$FALLBACK_IMAGE"
            else
                err "Kein verwendbares Image (weder $IMAGE noch $FALLBACK_IMAGE lokal)."
                err "Pruefe Login: docker login git.senity.ai"
                exit 1
            fi
        fi
    fi

    update_repo "$SKILLS_REPO_URL"   "$SENITY_CACHE_DIR/skills"
    update_repo "$COMMANDS_REPO_URL" "$SENITY_CACHE_DIR/commands"
    update_repo "$AGENTS_REPO_URL"   "$SENITY_CACHE_DIR/agents"
    update_repo "$MCPS_REPO_URL"     "$SENITY_CACHE_DIR/senity-mcps"
}

ensure_image() {
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        if docker image inspect "$FALLBACK_IMAGE" >/dev/null 2>&1; then
            warn "Image $IMAGE lokal nicht vorhanden, nutze Fallback $FALLBACK_IMAGE"
            IMAGE="$FALLBACK_IMAGE"
        else
            err "Image fehlt und --skip-update verhindert Pull. Aufruf ohne --skip-update wiederholen."
            exit 1
        fi
    fi
}

# ---- Container starten ------------------------------------------------------
run_container() {
    local cwd
    cwd="$(pwd)"
    local container_name="senity-$$-$(date +%s)"
    local is_comfyui=0
    [[ "$SUBCOMMAND" == "comfyui" ]] && is_comfyui=1

    local -a docker_args=(
        run --rm -it
        --name "$container_name"
        -e "SENITY_CHAT_PROXY_URL=$SENITY_CHAT_PROXY_URL"
        -e "SENITY_CHAT_PROXY_KEY=$SENITY_CHAT_PROXY_KEY"
        -e "ANTHROPIC_BASE_URL=$SENITY_CHAT_PROXY_URL"
        -e "ANTHROPIC_API_KEY=$SENITY_CHAT_PROXY_KEY"
        -e "TERM=${TERM:-xterm-256color}"
        -v "$SENITY_WORKSPACE_DIR:/workspace"
        -v "$cwd:/workspace/cwd"
    )

    if [[ "$is_comfyui" -eq 1 ]]; then
        docker_args+=(-p "127.0.0.1:${COMFYUI_PORT}:8188")
        docker_args+=(-e "SENITY_COMFYUI_PORT=8188")
        docker_args+=(-e "SENITY_COMFYUI_HOST_PORT=${COMFYUI_PORT}")
        docker_args+=(-e "SENITY_MODEL_SYNC=0")
        if [[ "$COMFYUI_GPU" -eq 1 ]]; then
            docker_args+=(--gpus all)
        fi
    fi

    [[ -d "$SENITY_CACHE_DIR/skills/skills" ]]      && docker_args+=(-v "$SENITY_CACHE_DIR/skills/skills:/workspace/.claude/skills/intern:ro")
    [[ -d "$SENITY_CACHE_DIR/commands/commands" ]]  && docker_args+=(-v "$SENITY_CACHE_DIR/commands/commands:/workspace/.claude/commands/intern:ro")
    [[ -d "$SENITY_CACHE_DIR/agents/agents" ]]      && docker_args+=(-v "$SENITY_CACHE_DIR/agents/agents:/workspace/.claude/agents/intern:ro")
    [[ -d "$SENITY_CACHE_DIR/senity-mcps" ]]        && docker_args+=(-v "$SENITY_CACHE_DIR/senity-mcps:/workspace/.mcp/senity-mcps")

    [[ -f "$SENITY_MCP_CONFIG" ]] && docker_args+=(-v "$SENITY_MCP_CONFIG:/workspace/.mcp-config.json:ro")

    [[ -d "$HOME/.ssh" ]] && docker_args+=(-v "$HOME/.ssh:/home/node/.ssh:ro")

    for m in "${EXTRA_MOUNTS[@]:-}"; do
        [[ -z "$m" ]] && continue
        docker_args+=(-v "$m")
    done

    docker_args+=(-w /workspace/cwd "$IMAGE")

    if [[ "$is_comfyui" -eq 1 ]]; then
        log "Starte ComfyUI: http://127.0.0.1:${COMFYUI_PORT}"
        docker_args+=(senity-comfyui)
    elif [[ "$YOLO" -eq 1 ]]; then
        docker_args+=(senity-mascot-filter claude --dangerously-skip-permissions)
    else
        docker_args+=(senity-mascot-filter claude)
    fi

    for arg in "${CLAUDE_ARGS[@]:-}"; do
        [[ -z "$arg" ]] && continue
        docker_args+=("$arg")
    done

    exec docker "${docker_args[@]}"
}

# ---- Main -------------------------------------------------------------------
main() {
    case "$SUBCOMMAND" in
        login)        cmd_login; exit 0 ;;
        gitea-login)  cmd_gitea_login ;;
        gitea-token)  cmd_gitea_token ;;
        gitea-status) cmd_gitea_status ;;
        gitea-logout) cmd_gitea_logout ;;
    esac

    require_docker
    ensure_dirs
    if [[ "$SUBCOMMAND" == "comfyui" ]]; then
        if [[ -f "$SENITY_ENV_FILE" ]]; then
            # shellcheck disable=SC1090
            source "$SENITY_ENV_FILE"
        fi
        SENITY_CHAT_PROXY_URL="${SENITY_CHAT_PROXY_URL:-$DEFAULT_PROXY_URL}"
        SENITY_CHAT_PROXY_KEY="${SENITY_CHAT_PROXY_KEY:-}"
    else
        load_env
    fi

    if [[ "$SKIP_UPDATE" -eq 0 ]]; then
        do_update
    else
        log "Auto-Update uebersprungen (--skip-update)"
        ensure_image
    fi

    run_container
}

main "$@"
