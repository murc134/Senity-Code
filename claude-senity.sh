#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# claude-senity.sh — Senity Workspace (Container Start, Linux/Mac)
#
# Usage:
#   ./claude-senity.sh                              # Senity Claude-Proxy (Default)
#   ./claude-senity.sh --msh                        # MSH Gateway (qwen3.6)
#   ./claude-senity.sh --anthropic --yolo           # Direkt Anthropic + Yolo
#   ./claude-senity.sh --ollama --model llama3.1    # Lokaler Ollama
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=""
MODEL=""
YOLO=false
EXTRA=()

# ── Argumente parsen ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)    MODEL="$2"; shift 2 ;;
        -e|--endpoint) GATEWAY_URL="$2"; shift 2 ;;
        --proxy)       MODE="proxy"; shift ;;
        --msh)         MODE="msh"; shift ;;
        --senity)      MODE="senity"; shift ;;
        --anthropic)   MODE="anthropic"; shift ;;
        --ollama)      MODE="ollama"; shift ;;
        --yolo)        YOLO=true; shift ;;
        --no-yolo)     YOLO=false; shift ;;
        -h|--help)
            echo "Usage: ./claude-senity.sh [OPTIONS]"
            echo ""
            echo "  --proxy         Senity Chat Proxy (default)"
            echo "  --msh           MSH Gateway (qwen3.6)"
            echo "  --senity        Senity Ollama Cloud (qwen3:8b)"
            echo "  --anthropic     Eigenes Anthropic API"
            echo "  --ollama        Lokaler Ollama"
            echo "  --model NAME    Modell ueberschreiben"
            echo "  --yolo          Yolo Mode (default: aus)"
            echo "  --no-yolo       Yolo Mode deaktiviert"
            echo "  --endpoint URL  Custom Endpoint (Ollama)"
            echo "  -h, --help      Diese Hilfe"
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

# ── Modus ermitteln ──
if [[ -z "$MODE" ]]; then
    MODE="proxy"
fi

# ── Werte pro Modus ──
token=""
base_url=""
default_model="claude-sonnet-4-6"

case "$MODE" in
    proxy)
        token="${ENV_VARS[SENITY_CHAT_PROXY_KEY]:-${SENITY_CHAT_PROXY_KEY:-}}"
        if [[ -z "$token" ]]; then
            echo "FEHLER: SENITY_CHAT_PROXY_KEY nicht gesetzt."
            exit 1
        fi
        base_url="${ENV_VARS[SENITY_CHAT_PROXY_URL]:-https://api.senity.ai/api/claude-proxy}"
        default_model="claude-sonnet-4-6"
        ;;
    senity)
        token="${ENV_VARS[SENITY_OLLAMA_API_KEY]:-${SENITY_OLLAMA_API_KEY:-}}"
        if [[ -z "$token" ]]; then
            echo "FEHLER: SENITY_OLLAMA_API_KEY nicht gesetzt."
            exit 1
        fi
        base_url="${ENV_VARS[SENITY_OLLAMA_URL]:-https://ollama.senity.ai}"
        default_model="${ENV_VARS[SENITY_OLLAMA_MODEL]:-qwen3:8b}"
        ;;
    msh)
        token="${ENV_VARS[MSH_API_KEY]:-${MSH_API_KEY:-}}"
        if [[ -z "$token" ]]; then
            echo "FEHLER: MSH_API_KEY nicht gesetzt."
            exit 1
        fi
        base_url="${ENV_VARS[MSH_API_URL]:-https://gateway.missionstarkeshandwerk.de}"
        default_model="${ENV_VARS[MSH_VLLM_MODEL]:-qwen3.6}"
        ;;
    anthropic)
        token="${ANTHROPIC_API_KEY:-${ENV_VARS[ANTHROPIC_API_KEY]:-}}"
        if [[ -z "$token" ]]; then
            echo "FEHLER: ANTHROPIC_API_KEY nicht gesetzt."
            exit 1
        fi
        base_url=""
        default_model="claude-sonnet-4-6"
        ;;
    ollama)
        token="ollama"
        base_url="${GATEWAY_URL:-http://host.docker.internal:11434}"
        ;;
    *)
        echo "FEHLER: Unbekannter Modus '$MODE'. Waehle: proxy, senity, msh, anthropic, ollama"
        exit 1
        ;;
esac

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

if [[ "$MODE" == "ollama" ]]; then
    DOCKER_ARGS+=(--add-host host.docker.internal:host-gateway)
fi

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
