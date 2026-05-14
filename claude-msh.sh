#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# claude-msh — Senity Workspace (Docker Container)
#
# Startet Claude Code in einem Docker Container.
# Modus: MSH Gateway / Eigenes Anthropic / Ollama lokal.
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-msh}"
MODEL=""
EXTRA=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)  MODEL="$2"; shift 2 ;;
        -e|--endpoint) GATEWAY_URL="$2"; shift 2 ;;
        -a|--anthropic) MODE="anthropic"; shift ;;
        -o|--ollama) MODE="ollama"; shift ;;
        -h|--help)
            echo "Usage: claude-msh [--model MODELL] [--anthropic|--ollama]"
            echo ""
            echo "  Modes: msh (default, qwen3.6), anthropic, ollama"
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
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            key="$(echo "$key" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
            val="$(echo "$val" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
            ENV_VARS["$key"]="$val"
        fi
    done < "$ENV_FILE"
fi

# ── Werte pro Modus ──
TOKEN=""
BASE_URL=""

case "$MODE" in
    msh)
        TOKEN="${ENV_VARS[MSH_API_KEY]:-${ENV_VARS[MSH_VLLM_API_KEY]:-${LITELLM_MASTER_KEY:-}}}"
        if [[ -z "$TOKEN" ]]; then
            echo "FEHLER: Kein Auth-Token gefunden." >&2
            echo "Setz MSH_API_KEY in .env oder LITELLM_MASTER_KEY." >&2
            exit 1
        fi
        BASE_URL="${ENV_VARS[MSH_API_URL]:-https://gateway.missionstarkeshandwerk.de}"
        ;;
    anthropic)
        TOKEN="${ANTHROPIC_API_KEY:-}"
        if [[ -z "$TOKEN" ]]; then
            echo "FEHLER: ANTHROPIC_API_KEY nicht gesetzt." >&2
            exit 1
        fi
        BASE_URL=""
        ;;
    ollama)
        TOKEN="ollama"
        BASE_URL="${GATEWAY_URL:-http://host.docker.internal:11434}"
        ;;
    *)
        echo "FEHLER: Unbekannter Modus '$MODE'. Waehle: msh, anthropic, ollama" >&2
        exit 1
        ;;
esac

if [[ -z "$MODEL" ]]; then
    MODEL="${ENV_VARS[MSH_VLLM_MODEL]:-qwen3.6}"
fi

# ── Docker starten ──
CONTAINER_NAME="senity-workspace-$(whoami)-$$"
WORKSPACE_PATH="${SCRIPT_DIR}/workspace"

# Workspace erstellen
mkdir -p "$WORKSPACE_PATH"

DOCKER_ARGS=(
    -it --rm
    --name "$CONTAINER_NAME"
    -v "${WORKSPACE_PATH}:/workspace"
    -w /workspace
)

# Bindings aus Bindings.md
BINDINGS_FILE="${SCRIPT_DIR}/Bindings.md"
if [[ -f "$BINDINGS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(echo "$line" | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^([^\s=]+)=([^\s]+)$ ]]; then
            host_binding="${BASH_REMATCH[1]}"
            container_binding="${BASH_REMATCH[2]}"
            full_host="$(realpath "${SCRIPT_DIR}/${host_binding}" 2>/dev/null || echo "")"
            if [[ -n "$full_host" && -d "$full_host" ]]; then
                DOCKER_ARGS+=(-v "${full_host}:${container_binding}")
            fi
        fi
    done < "$BINDINGS_FILE"
fi

# SSH-Key
if [[ -d "$HOME/.ssh" ]]; then
    DOCKER_ARGS+=(-v "${HOME}/.ssh:/home/node/.ssh:ro")
fi

# Git-Config
if [[ -f "$HOME/.gitconfig" ]]; then
    DOCKER_ARGS+=(-v "${HOME}/.gitconfig:/home/node/.gitconfig:ro")
fi

# Env-Vars
DOCKER_ARGS+=(-e "ANTHROPIC_BASE_URL=${BASE_URL}")
DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=${TOKEN}")
DOCKER_ARGS+=(-e "HOME=/workspace")
DOCKER_ARGS+=(-e "TERM=xterm-256color")

if [[ "$MODE" == "ollama" ]]; then
    DOCKER_ARGS+=(--add-host host.docker.internal:host-gateway)
fi

DOCKER_ARGS+=(--model "$MODEL")

exec docker run "${DOCKER_ARGS[@]}" senity-claude:latest "${EXTRA[@]}"
