#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# setup.sh — Senity Workspace Setup (Linux/Mac)
#
# 1. Docker pruefen + auto-install
# 2. Docker Image bauen
# 3. Bindings.md pruefen/erstellen
# 4. Provider + Modell + Yolo waehlen
# 5. Container starten (mit config mount)
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=""
MODEL=""
YOLO=false
YOLO_FLAG_SET=false
BINDINGS_FILE=""
NO_INTERACTIVE=false

# ── Argumente parsen ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode|-m) MODE="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --yolo) YOLO=true; YOLO_FLAG_SET=true; shift ;;
        --no-yolo) YOLO=false; YOLO_FLAG_SET=true; shift ;;
        --bindings) BINDINGS_FILE="$2"; shift 2 ;;
        --no-interactive) NO_INTERACTIVE=true; shift ;;
        -h|--help)
            echo "Usage: ./setup.sh [--mode msh|anthropic|ollama] [--model NAME] [--yolo|--no-yolo]"
            echo ""
            echo "  --mode       msh (default), anthropic, ollama"
            echo "  --model      Modell ueberschreiben"
            echo "  --yolo       Yolo Mode an (default: aus)"
            echo "  --no-yolo    Yolo Mode aus"
            echo "  --bindings   Bindings.md Pfad"
            exit 0 ;;
        *) echo "Unbekannte Option: $1"; exit 1 ;;
    esac
done

# ── Hilfsfunktionen ──
step() {
    echo ""
    echo "  [$1/5] $2..."
}

read_choice() {
    local prompt="$1"
    local default="${2:-}"
    if $NO_INTERACTIVE; then
        echo "$default"
    else
        read -r -p "$prompt [${default:-N}]: " choice
        if [[ -z "$choice" ]]; then
            echo "$default"
        else
            echo "$choice"
        fi
    fi
}

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

# ══════════════════════════════════════════════════════════════
# [1/5] Docker pruefen + installieren
# ══════════════════════════════════════════════════════════════
step 1 "Docker pruefen"

if ! command -v docker &>/dev/null; then
    echo ""
    echo "  Docker nicht gefunden."
    if $NO_INTERACTIVE; then
        echo "  Non-interactive: Docker muss installiert sein."
        exit 1
    fi

    choice=$(read_choice "  Docker jetzt installieren?")
    if [[ "$choice" == "j" ]]; then
        echo ""
        # Platform-spezifischer Install
        if command -v brew &>/dev/null; then
            echo "  [brew] Installiere Docker Desktop..."
            brew install --cask docker
        elif command -v apt-get &>/dev/null; then
            echo "  [apt] Installiere Docker..."
            curl -fsSL https://get.docker.com | sh
        elif command -v yum &>/dev/null; then
            echo "  [yum] Installiere Docker..."
            yum install -y docker-ce docker-ce-cli containerd.io
            systemctl start docker
        else
            echo "  Bitte manuell installieren:"
            echo "  https://docs.docker.com/get-docker/"
            read -r -p "  Installation abgeschlossen? (j/N) " continue_choice
            if [[ "$continue_choice" != "j" ]]; then
                exit 1
            fi
        fi

        if ! command -v docker &>/dev/null; then
            echo "  Docker immer noch nicht gefunden."
            exit 1
        fi
    else
        exit 1
    fi
fi

docker --version
echo "  Docker: $(docker --version)"

# ── WSL-Dependencies pruefen ──
if grep -qi Microsoft /proc/version 2>/dev/null; then
    echo "  WSL erkannt — pruefe Docker-Docker-Dependencies..."

    missing=()
    for pkg in libgl1 libglib2.0-0 p11-kit kmod iptables bridge-utils; do
        if ! dpkg -s "$pkg" &>/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "  Installiere fehlende WSL-Dependencies: ${missing[*]}"
        sudo apt-get update && sudo apt-get install -y "${missing[@]}"
    else
        echo "  WSL-Docker-Dependencies OK."
    fi
fi

# ══════════════════════════════════════════════════════════════
# [2/5] Docker Image bauen
# ══════════════════════════════════════════════════════════════
step 2 "Docker Image bauen"

docker build -t senity-claude:latest "$SCRIPT_DIR"
echo "  Image gebaut: senity-claude:latest"

# ══════════════════════════════════════════════════════════════
# [3/5] Bindings.md pruefen/erstellen
# ══════════════════════════════════════════════════════════════
step 3 "Mount-Pfade"

BINDINGS_FILE="${BINDINGS_FILE:-${SCRIPT_DIR}/Bindings.md}"

has_mounts=false
if [[ -f "$BINDINGS_FILE" ]]; then
    active_lines=$(grep -v '^\s*#' "$BINDINGS_FILE" | grep -v '^\s*$' || true)
    if [[ -n "$active_lines" ]]; then
        has_mounts=true
        count=$(echo "$active_lines" | wc -l)
        echo "  Bindings.md gefunden mit ${count} Pfad/en"
        echo "$active_lines" | sed 's/^/    /'
    fi
fi

if ! $has_mounts; then
    echo ""
    echo "  Hinweis: Bindings.md existiert nicht oder hat keine Mount-Pfade."
    echo "  Default: ./workspace wird eingebunden."
    if ! $NO_INTERACTIVE; then
        choice=$(read_choice "  Pfade bearbeiten?")
        if [[ "$choice" == "j" ]]; then
            cat > "$BINDINGS_FILE" <<'BINDINGS'
# Senity Workspace — Mount-Pfade
# Format: <host-path>=<container-path>
# Kommentare beginnen mit #, leere Zeilen werden ignoriert

./workspace=/workspace
BINDINGS
            echo "  Bindings.md erstellt mit Default-Inhalt."
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════
# [4/5] Provider, Modell, Yolo waehlen
# ══════════════════════════════════════════════════════════════
step 4 "Provider, Modell, Yolo"

if [[ -z "$MODE" ]]; then
    if $NO_INTERACTIVE; then
        MODE="msh"
    else
        echo ""
        echo "  Provider waehlen:"
        echo "    1) MSH Gateway  — qwen3.6 (vLLM, am schnellsten)"
        echo "    2) Anthropic    — claude-sonnet-4-6 (Echte API)"
        echo "    3) Ollama       — freiwaehlbbar (lokal)"
        echo ""
        choice=$(read_choice "  Wahl (1/2/3)" "1")
        case "$choice" in
            1) MODE="msh" ;;
            2) MODE="anthropic" ;;
            3) MODE="ollama" ;;
            *) MODE="msh"; echo "  Default: MSH Gateway" ;;
        esac
    fi
fi

token=""
base_url=""
default_model="qwen3.6"

case "$MODE" in
    msh)
        token="${ENV_VARS[MSH_API_KEY]:-${ENV_VARS[MSH_VLLM_API_KEY]:-${LITELLM_MASTER_KEY:-}}}"
        if [[ -z "$token" ]]; then
            if $NO_INTERACTIVE; then
                echo "  FEHLER: Kein Auth-Token gefunden."
                exit 1
            fi
            read -r -p "  MSH API-Key: " token
            if [[ -z "$token" ]]; then exit 1; fi
        fi
        base_url="${ENV_VARS[MSH_API_URL]:-https://gateway.missionstarkeshandwerk.de}"
        default_model="${ENV_VARS[MSH_VLLM_MODEL]:-qwen3.6}"
        echo "  Provider: MSH Gateway ($base_url)"
        ;;
    anthropic)
        token="${ANTHROPIC_API_KEY:-${ENV_VARS[ANTHROPIC_API_KEY]:-}}"
        if [[ -z "$token" ]]; then
            if $NO_INTERACTIVE; then
                echo "  FEHLER: ANTHROPIC_API_KEY nicht gesetzt."
                exit 1
            fi
            read -r -p "  Anthropic API-Key (sk-ant-...): " token
            if [[ -z "$token" ]]; then exit 1; fi
        fi
        base_url=""
        default_model="claude-sonnet-4-6"
        echo "  Provider: Anthropic API"
        ;;
    ollama)
        token="ollama"
        base_url="${CUSTOM_OLLAMA_URL:-http://host.docker.internal:11434}"
        echo "  Provider: Ollama lokal"
        ;;
    *)
        echo "  FEHLER: Unbekannter Modus '$MODE'."
        exit 1
        ;;
esac

if [[ -z "$MODEL" ]]; then
    MODEL=$(read_choice "  Modell" "$default_model")
    if [[ -z "$MODEL" ]]; then MODEL="$default_model"; fi
fi
echo "  Modell: $MODEL"

# Yolo — default: AUS (Sicherheit)
# Wenn --yolo oder --no-yolo uebergeben, bleibt der Wert. Ansonsten interaktiv fragen.
if [[ "$YOLO_FLAG_SET" == false ]]; then
    if $NO_INTERACTIVE; then
        YOLO=false
    else
        yolo_input=$(read_choice "  Yolo Mode (ungefragte Execution)? [y/N]" "n")
        if [[ "$yolo_input" == "y" || "$yolo_input" == "Y" ]]; then
            YOLO=true
        fi
    fi
fi
echo "  Yolo: $YOLO"

# ══════════════════════════════════════════════════════════════
# [5/5] Container starten
# ══════════════════════════════════════════════════════════════
step 5 "Container starten"

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

# Bindings
if $has_mounts && [[ -f "$BINDINGS_FILE" ]]; then
    while IFS= read -r line; do
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
    done < "$BINDINGS_FILE"
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

# Ollama
if [[ "$MODE" == "ollama" ]]; then
    DOCKER_ARGS+=(--add-host host.docker.internal:host-gateway)
fi

echo ""
echo "  Provider:  $MODE"
echo "  Modell:    $MODEL"
echo "  Yolo:      $YOLO"
echo "  Container: $container_name"
echo ""

# Claude-Argumente NACH dem Image-Namen (nicht als Docker-Flags)
CLAUDE_ARGS=("--model" "$MODEL")
if $YOLO; then
    CLAUDE_ARGS+=("--dangerously-skip-permissions")
fi

docker run "${DOCKER_ARGS[@]}" senity-claude:latest "${CLAUDE_ARGS[@]}"
