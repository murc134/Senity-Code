#!/usr/bin/env bash
# senity — globaler CLI-Wrapper fuer den Senity-Workspace-Container.
# Startet einen Ad-hoc-Container mit dem aktuellen cwd als /workspace/cwd.
#
# Defaults:
#   - Image:           git.senity.ai/senity-admin/senity-code:latest
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
#   senity --help                   Hilfe

set -euo pipefail

# ---- Konstanten -------------------------------------------------------------
SENITY_HOME="${SENITY_HOME:-${HOME}/.senity}"
SENITY_ENV_FILE="${SENITY_HOME}/.env"
SENITY_MCP_CONFIG="${SENITY_HOME}/mcp-config.json"
SENITY_CACHE_DIR="${SENITY_HOME}/cache"
SENITY_WORKSPACE_DIR="${SENITY_HOME}/workspace"

DEFAULT_IMAGE="git.senity.ai/senity-admin/senity-code:latest"
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
CLAUDE_ARGS=()

print_help() {
    cat <<'EOF'
senity — Senity-Workspace-Container auf Knopfdruck

USAGE
  senity [options] [-- claude-args...]
  senity login
  senity --help

OPTIONS
  --skip-update         Ueberspringt docker pull + git pull beim Start
  --no-yolo             Permission-Prompts aktivieren (Default: Yolo an)
  --yolo                Yolo explizit an (Default)
  --mount H:C[:ro]      Zusatz-Mount, mehrfach erlaubt
  --image <ref>         Image-Tag ueberschreiben
  --help, -h            Diese Hilfe

SUBCOMMANDS
  login                 Senity-Proxy-Key in ~/.senity/.env hinterlegen

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-update) SKIP_UPDATE=1; shift ;;
        --no-yolo)     YOLO=0; shift ;;
        --yolo)        YOLO=1; shift ;;
        --mount)       EXTRA_MOUNTS+=("$2"); shift 2 ;;
        --image)       IMAGE_OVERRIDE="$2"; shift 2 ;;
        --help|-h)     print_help; exit 0 ;;
        login)         SUBCOMMAND="login"; shift ;;
        --)            shift; CLAUDE_ARGS=("$@"); break ;;
        *)             CLAUDE_ARGS+=("$1"); shift ;;
    esac
done

IMAGE="${IMAGE_OVERRIDE:-$DEFAULT_IMAGE}"

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

    if [[ "$YOLO" -eq 1 ]]; then
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
        login) cmd_login; exit 0 ;;
    esac

    require_docker
    ensure_dirs
    load_env

    if [[ "$SKIP_UPDATE" -eq 0 ]]; then
        do_update
    else
        log "Auto-Update uebersprungen (--skip-update)"
        ensure_image
    fi

    run_container
}

main "$@"
