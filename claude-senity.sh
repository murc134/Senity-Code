#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# claude-senity.sh — Senity Workspace (Container Start, Linux/Mac)
#
# Usage:
#   ./claude-senity.sh                              # Senity Chat Proxy
#   ./claude-senity.sh --yolo                       # Mit Yolo-Mode
#   ./claude-senity.sh --model claude-opus-4-7      # Modell ueberschreiben
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL=""
YOLO=false
EXTRA=()

# ── Argumente parsen ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)    MODEL="$2"; shift 2 ;;
        --yolo)        YOLO=true; shift ;;
        --no-yolo)     YOLO=false; shift ;;
        -h|--help)
            echo "Usage: ./claude-senity.sh [OPTIONS]"
            echo ""
            echo "  --model NAME    Modell ueberschreiben (Default: claude-sonnet-4-6)"
            echo "  --yolo          Yolo Mode (default: aus)"
            echo "  --no-yolo       Yolo Mode deaktiviert"
            echo "  -h, --help      Diese Hilfe"
            echo ""
            echo "Provider: Senity Chat Proxy (SENITY_CHAT_PROXY_URL / _KEY aus .env)"
            exit 0 ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done

# ── .env lesen ──
ENV_FILE="${SCRIPT_DIR}/.env"
declare -A ENV_VARS=()
if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(echo "$line" | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            key="$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
            val="$(echo "${BASH_REMATCH[2]}" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//' | sed "s/^'//" | sed "s/'$//")"
            ENV_VARS["$key"]="$val"
        fi
    done < "$ENV_FILE"
fi

# ── Credentials (Senity Chat Proxy) ──
token="${ENV_VARS[SENITY_CHAT_PROXY_KEY]:-${SENITY_CHAT_PROXY_KEY:-}}"
if [[ -z "$token" ]]; then
    echo "FEHLER: SENITY_CHAT_PROXY_KEY nicht gesetzt (weder in .env noch in Environment)."
    exit 1
fi
base_url="${ENV_VARS[SENITY_CHAT_PROXY_URL]:-${SENITY_CHAT_PROXY_URL:-https://sdr.senity.ai/api/claude-proxy}}"
default_model="claude-sonnet-4-6"

if [[ -z "$MODEL" ]]; then
    MODEL="$default_model"
fi

# ── Docker sicherstellen ──
ensure_docker() {
    if ! command -v docker &>/dev/null; then
        echo "FEHLER: Docker nicht installiert."
        echo "  macOS:  brew install --cask docker"
        echo "  Linux:  https://docs.docker.com/engine/install/"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo "Docker nicht bereit. Versuche Docker Desktop zu starten..."
        if [[ "$(uname)" == "Darwin" ]]; then
            open -a Docker
        else
            sudo systemctl start docker 2>/dev/null || true
        fi
        timeout=60
        elapsed=0
        while ! docker info &>/dev/null; do
            sleep 3
            elapsed=$((elapsed + 3))
            echo "  Warte auf Docker... ($elapsed/${timeout}s)"
            if [[ $elapsed -ge $timeout ]]; then
                echo "FEHLER: Docker nicht bereit nach ${timeout}s."
                exit 1
            fi
        done
        echo "Docker bereit."
    fi

    if ! docker image inspect senity-claude:latest &>/dev/null; then
        echo "Image 'senity-claude:latest' fehlt. Baue Image..."
        setup_script="${SCRIPT_DIR}/setup.sh"
        if [[ -f "$setup_script" ]]; then
            bash "$setup_script"
        else
            echo "FEHLER: setup.sh nicht gefunden. Bitte manuell ausfuehren."
            exit 1
        fi
    fi
}

# ── TTY-Check: docker run -it benoetigt echtes Terminal ──
if [[ ! -t 0 ]]; then
    echo "FEHLER: Kein TTY verfuegbar. Bitte direkt aus einem Terminal starten." >&2
    echo "  macOS:  open -a Terminal '$0' oder iTerm2 verwenden" >&2
    echo "  Linux:  In einem echten Terminal-Emulator ausfuehren" >&2
    exit 1
fi

ensure_docker

# ── Container starten ──
container_name="senity-workspace-$(whoami)-$$"
workspace_path="${SCRIPT_DIR}/workspace"
claude_dir="${SCRIPT_DIR}/.claude"

mkdir -p "$workspace_path" "$claude_dir"

DOCKER_ARGS=(
    -it --rm
    --name "$container_name"
    -v "${workspace_path}:/workspace"
    -v "${claude_dir}:/workspace/.claude"
    -w /workspace
)

# Bindings aus Bindings.md
bindings_file="${SCRIPT_DIR}/Bindings.md"
if [[ -f "$bindings_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(echo "$line" | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^([^[:space:]=]+)=([^[:space:]]+)$ ]]; then
            host_binding="${BASH_REMATCH[1]}"
            container_binding="${BASH_REMATCH[2]}"
            full_host="$(cd "${SCRIPT_DIR}" && realpath -m "$host_binding" 2>/dev/null || echo "")"
            if [[ -n "$full_host" && -d "$full_host" ]]; then
                DOCKER_ARGS+=(-v "${full_host}:${container_binding}")
            fi
        fi
    done < "$bindings_file"
fi

# SSH + Git
if [[ -d "$HOME/.ssh" ]]; then
    DOCKER_ARGS+=(-v "${HOME}/.ssh:/home/node/.ssh:ro")
fi
if [[ -f "$HOME/.gitconfig" ]]; then
    DOCKER_ARGS+=(-v "${HOME}/.gitconfig:/home/node/.gitconfig:ro")
fi

# Environment
DOCKER_ARGS+=(-e "ANTHROPIC_BASE_URL=${base_url}")
DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=${token}")
DOCKER_ARGS+=(-e "HOME=/workspace")
DOCKER_ARGS+=(-e "TERM=xterm-256color")

# Claude-Argumente NACH dem Image-Namen (nicht als Docker-Flags)
CLAUDE_ARGS=("--model" "$MODEL")
if $YOLO; then
    CLAUDE_ARGS+=("--dangerously-skip-permissions")
fi

if [[ ${#EXTRA[@]} -gt 0 ]]; then
    docker run "${DOCKER_ARGS[@]}" senity-claude:latest "${CLAUDE_ARGS[@]}" "${EXTRA[@]}"
else
    docker run "${DOCKER_ARGS[@]}" senity-claude:latest "${CLAUDE_ARGS[@]}"
fi
