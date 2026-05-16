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
YOLO=true    # Default: Skip-Permissions an (Container ist isoliert)
REBUILD=false
EXTRA=()

# ── Argumente parsen ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)    MODEL="$2"; shift 2 ;;
        --yolo)        YOLO=true; shift ;;
        --no-yolo)     YOLO=false; shift ;;
        --rebuild)     REBUILD=true; shift ;;
        -h|--help)
            echo "Usage: ./claude-senity.sh [OPTIONS]"
            echo ""
            echo "  --model NAME    Modell ueberschreiben (Default: Senity Proxy)"
            echo "  --yolo          Yolo Mode (Default: an, Container ist isoliert)"
            echo "  --no-yolo       Yolo Mode deaktivieren (Permission-Prompts aktivieren)"
            echo "  --rebuild       Docker-Image neu bauen (force)"
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

# ── Helper: .env-Schluessel setzen oder anhaengen ──
set_env_var() {
    local path="$1"
    local key="$2"
    local value="$3"
    local tmp
    local found=false

    if [[ -f "$path" ]]; then
        tmp="$(mktemp)"
        while IFS= read -r line || [[ -n "$line" ]]; do
            local trimmed
            trimmed="$(echo "$line" | sed 's/^[[:space:]]*//')"
            if [[ "$trimmed" =~ ^${key}[[:space:]]*= ]]; then
                printf '%s=%s\n' "$key" "$value" >> "$tmp"
                found=true
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$path"
        if ! $found; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
        fi
        mv "$tmp" "$path"
    else
        printf '%s=%s\n' "$key" "$value" > "$path"
    fi
    chmod 600 "$path" 2>/dev/null || true
}

# ── Helper: Senity-Key gegen Proxy validieren ──
# Return-Codes:
#   0 = valide (HTTP 200 oder Server-Fehler nach Auth)
#   1 = invalide (401/403/404)
#   2 = Netzwerkfehler
validate_senity_key() {
    local url="$1"
    local key="$2"
    local endpoint="${url%/}/v1/messages"
    local body='{"model":"claude-3-5-haiku-latest","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
    local http_code

    if ! command -v curl &>/dev/null; then
        echo "  [WARN] curl nicht verfuegbar, Key-Validierung uebersprungen." >&2
        return 0
    fi

    http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 15 \
        -X POST "$endpoint" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $key" \
        -H "anthropic-version: 2023-06-01" \
        -d "$body" 2>/dev/null || echo "000")"

    case "$http_code" in
        200|201) return 0 ;;
        400|422|429|500|502|503|504) return 0 ;;  # Auth ok, Server-/Request-Issue
        401|403|404) return 1 ;;
        000) return 2 ;;
        *) return 1 ;;
    esac
}

# ── TTY-Check (vor Credentials, da Read-Prompt ein TTY braucht) ──
if [[ ! -t 0 ]]; then
    echo "FEHLER: Kein TTY verfuegbar. Bitte direkt aus einem Terminal starten." >&2
    echo "  macOS:  open -a Terminal '$0' oder iTerm2 verwenden" >&2
    echo "  Linux:  In einem echten Terminal-Emulator ausfuehren" >&2
    exit 1
fi

# ── Credentials (Senity Chat Proxy) + Validierung + Persistenz ──
default_url="https://sdr.senity.ai/api/claude-proxy"
token="${ENV_VARS[SENITY_CHAT_PROXY_KEY]:-${SENITY_CHAT_PROXY_KEY:-}}"
base_url="${ENV_VARS[SENITY_CHAT_PROXY_URL]:-${SENITY_CHAT_PROXY_URL:-$default_url}}"

attempts=0
max_attempts=3
key_ok=false
should_persist=false

while [[ "$key_ok" == false ]]; do
    if [[ -z "$token" ]]; then
        echo ""
        echo "  [INFO] SENITY_CHAT_PROXY_KEY ist nicht gesetzt."
        echo "         Bitte Proxy-URL und Key eingeben (werden in .env gespeichert)."
        echo ""
        read -r -p "  Proxy-URL [$default_url]: " url_input
        if [[ -n "$url_input" ]]; then
            base_url="$(echo "$url_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        else
            base_url="$default_url"
        fi
        read -r -s -p "  Senity Chat Proxy Key: " token_input
        echo ""
        token="$(echo "$token_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        should_persist=true
        if [[ -z "$token" ]]; then
            echo "  [FAIL] Leerer Key. Abbruch." >&2
            exit 1
        fi
    fi

    echo "  [INFO] Pruefe Key gegen $base_url ..."
    set +e
    validate_senity_key "$base_url" "$token"
    rc=$?
    set -e

    case "$rc" in
        0)
            echo "  [OK]   Key ist valide."
            key_ok=true
            if $should_persist; then
                set_env_var "$ENV_FILE" "SENITY_CHAT_PROXY_URL" "$base_url"
                set_env_var "$ENV_FILE" "SENITY_CHAT_PROXY_KEY" "$token"
                echo "  [OK]   .env aktualisiert: $ENV_FILE"
            fi
            ;;
        1)
            echo "  [FAIL] Key wurde vom Proxy abgelehnt (Authentifizierung fehlgeschlagen)." >&2
            token=""
            attempts=$((attempts + 1))
            if [[ $attempts -ge $max_attempts ]]; then
                echo "  [FAIL] Maximale Anzahl Versuche ($max_attempts) erreicht. Abbruch." >&2
                exit 1
            fi
            ;;
        2)
            echo "  [FAIL] Netzwerkfehler beim Erreichen von $base_url" >&2
            echo "         Bitte URL und Internetverbindung pruefen." >&2
            token=""
            attempts=$((attempts + 1))
            if [[ $attempts -ge $max_attempts ]]; then
                echo "  [FAIL] Maximale Anzahl Versuche ($max_attempts) erreicht. Abbruch." >&2
                exit 1
            fi
            ;;
    esac
done

default_model="qwen3.6:35b"
default_model_label="Senity Proxy"

if [[ -z "$MODEL" ]]; then
    MODEL="$default_model"
fi
if [[ "$MODEL" == "$default_model" ]]; then
    model_label="${default_model_label} (${default_model})"
else
    model_label="$MODEL"
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

    local needs_build=false
    if $REBUILD; then
        echo "Force-Rebuild angefordert. Loesche bestehendes Image (falls vorhanden)..."
        docker image rm senity-claude:latest &>/dev/null || true
        needs_build=true
    elif ! docker image inspect senity-claude:latest &>/dev/null; then
        needs_build=true
    fi

    if $needs_build; then
        echo "Baue Image 'senity-claude:latest' (kann 2-5 Minuten dauern)..."
        if ! docker build -t senity-claude:latest "$SCRIPT_DIR"; then
            echo "FEHLER: Image-Build fehlgeschlagen."
            echo "  Manueller Versuch: docker build -t senity-claude:latest '$SCRIPT_DIR'"
            exit 1
        fi
        echo "Image gebaut: senity-claude:latest"
    fi
}

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

# Bindings aus Bindings.md (Auto-Create bei Erst-Lauf)
bindings_file="${SCRIPT_DIR}/Bindings.md"
if [[ ! -f "$bindings_file" ]]; then
    cat > "$bindings_file" <<'BINDINGS'
# Senity Workspace - Mount-Pfade
# Format: <host-pfad>=<container-pfad>
# Kommentare beginnen mit #, leere Zeilen werden ignoriert
# Container-Pfad muss /workspace/<sub> sein (z.B. /workspace/mein-projekt)

./workspace=/workspace
BINDINGS
    echo "Bindings.md angelegt (Default: ./workspace=/workspace)"
fi
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
# senity-mascot-filter ist ein PTY-Wrapper, der das Anthropic-Maskottchen
# aus der Welcome-Box filtert (Block-Element-Chars in den ersten 2.5 s).
CLAUDE_ARGS=("senity-mascot-filter" "claude" "--model" "$MODEL")
if $YOLO; then
    CLAUDE_ARGS+=("--dangerously-skip-permissions")
fi

if [[ ${#EXTRA[@]} -gt 0 ]]; then
    docker run "${DOCKER_ARGS[@]}" senity-claude:latest "${CLAUDE_ARGS[@]}" "${EXTRA[@]}"
else
    docker run "${DOCKER_ARGS[@]}" senity-claude:latest "${CLAUDE_ARGS[@]}"
fi
