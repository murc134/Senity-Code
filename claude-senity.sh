#!/bin/bash
# ══════════════════════════════════════════════════════════════
# claude-senity.sh — Senity Workspace (Container Start, Linux/Mac)
#
# Usage:
#   ./claude-senity.sh                              # Senity Chat Proxy
#   ./claude-senity.sh --yolo                       # Mit Yolo-Mode
#   ./claude-senity.sh --model claude-opus-4-7      # Modell ueberschreiben
# ══════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Ausgabe-Hilfsfunktionen (ANSI-Farben) ──
c_green="\033[0;32m"
c_red="\033[0;31m"
c_magenta="\033[0;35m"
c_gray="\033[1;30m"
c_white="\033[1;37m"
c_reset="\033[0m"

write_ok()   { printf "  ${c_green}[OK]  ${c_reset} %s\n" "$1"; }
write_fail() { printf "  ${c_red}[FAIL]${c_reset} %s\n" "$1"; }
write_warn() { printf "  ${c_magenta}[WARN]${c_reset} %s\n" "$1"; }
write_info() { printf "  ${c_magenta}[INFO]${c_reset} %s\n" "$1"; }
write_dbg()  { printf "  ${c_gray}[DBG] ${c_reset} %s\n" "$1"; }
write_sep()  { printf "  ${c_gray}────────────────────────────────────────${c_reset}\n"; }

exit_error() {
    local msg="$1"
    local code="${2:-1}"
    echo ""
    printf "  ${c_red}╔══════════════════════════════════════════╗${c_reset}\n"
    printf "  ${c_red}║  FEHLER                                  ║${c_reset}\n"
    printf "  ${c_red}╚══════════════════════════════════════════╝${c_reset}\n"
    echo "$msg" | while IFS= read -r line; do
        printf "  ${c_red}%s${c_reset}\n" "$line"
    done
    echo ""
    exit "$code"
}

# ── resolve_path: realpath-Ersatz fuer macOS (kein GNU coreutils noetig) ──
resolve_path() {
    local target="$1"
    if [[ "$target" == /* ]]; then
        echo "$target"
    else
        echo "${SCRIPT_DIR}/${target}"
    fi
}

# ── .env-Datei lesen (Bash 3.2 kompatibel) ──
read_env_file() {
    local path="$1"
    _env_SENITY_CHAT_PROXY_KEY=""
    _env_SENITY_CHAT_PROXY_URL=""
    if [[ ! -f "$path" ]]; then return; fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
        if [[ -z "$line" || "$line" == \#* ]]; then continue; fi
        if [[ "$line" == *=* ]]; then
            key="${line%%=*}"
            val="${line#*=}"
            key="$(echo "$key" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
            val="$(echo "$val" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//' | sed "s/^'//" | sed "s/'$//")"
            case "$key" in
                SENITY_CHAT_PROXY_KEY) _env_SENITY_CHAT_PROXY_KEY="$val" ;;
                SENITY_CHAT_PROXY_URL) _env_SENITY_CHAT_PROXY_URL="$val" ;;
            esac
        fi
    done < "$path"
}

# ── .env-Schluessel setzen oder anhaengen ──
set_env_var() {
    local path="$1"
    local key="$2"
    local value="$3"
    local tmp found=false

    if [[ -f "$path" ]]; then
        tmp="$(mktemp)"
        while IFS= read -r line || [[ -n "$line" ]]; do
            local trimmed
            trimmed="$(echo "$line" | sed 's/^[[:space:]]*//')"
            if echo "$trimmed" | grep -q "^${key}[[:space:]]*="; then
                printf '%s=%s\n' "$key" "$value" >> "$tmp"
                found=true
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$path"
        if [[ "$found" == false ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
        fi
        mv "$tmp" "$path"
    else
        printf '%s=%s\n' "$key" "$value" > "$path"
    fi
    chmod 600 "$path" 2>/dev/null || true
}

# ── Senity-Key gegen Proxy validieren ──
# Return-Codes: 0=valide, 1=invalide (401/403/404), 2=Netzwerkfehler
validate_senity_key() {
    local url="$1"
    local key="$2"
    local endpoint="${url%/}/v1/messages"
    local body='{"model":"claude-3-5-haiku-latest","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
    local http_code

    if ! command -v curl &>/dev/null; then
        write_warn "curl nicht verfuegbar, Key-Validierung uebersprungen."
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
        400|422|429|500|502|503|504) return 0 ;;
        401|403) return 1 ;;
        404)     return 1 ;;
        000)     return 2 ;;
        *)       return 1 ;;
    esac
}

# ── Argumente parsen ──
MODEL=""
YOLO=true
REBUILD=false
SHOW_HELP=false
EXTRA=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)    MODEL="$2"; shift 2 ;;
        --yolo)        YOLO=true; shift ;;
        --no-yolo)     YOLO=false; shift ;;
        --rebuild)     REBUILD=true; shift ;;
        -h|--help)     SHOW_HELP=true; shift ;;
        *)             EXTRA+=("$1"); shift ;;
    esac
done

# ── Banner ──
echo ""
printf "  ${c_magenta}╔══════════════════════════════════════════╗${c_reset}\n"
printf "  ${c_magenta}║   Senity Workspace  —  Claude Code CLI   ║${c_reset}\n"
printf "  ${c_magenta}╚══════════════════════════════════════════╝${c_reset}\n"
echo ""
write_dbg "ScriptDir  : $SCRIPT_DIR"
write_dbg "Shell      : $BASH_VERSION"
write_dbg "User       : $(whoami)  PID: $$"
write_dbg "Args       : Yolo=$YOLO Model=$MODEL"
echo ""

# ── Help ──
if [[ "$SHOW_HELP" == true ]]; then
    printf "  ${c_white}Usage: ./claude-senity.sh [OPTIONS]${c_reset}\n"
    echo ""
    printf "  ${c_white}Provider: Senity Chat Proxy (fest, kein anderer Provider verfuegbar)${c_reset}\n"
    echo ""
    printf "  ${c_white}Optionen:${c_reset}\n"
    printf "  ${c_white}  --model NAME    Modell ueberschreiben (Default: Senity Proxy)${c_reset}\n"
    printf "  ${c_white}  --yolo          Yolo Mode (Default: an, Container ist isoliert)${c_reset}\n"
    printf "  ${c_white}  --no-yolo       Yolo Mode deaktivieren (Permission-Prompts)${c_reset}\n"
    printf "  ${c_white}  --rebuild       Docker-Image neu bauen (force)${c_reset}\n"
    printf "  ${c_white}  -h, --help      Diese Hilfe${c_reset}\n"
    echo ""
    exit 0
fi

# ══════════════════════════════════════════════════════════════
# [1/5] TTY pruefen
# ══════════════════════════════════════════════════════════════
write_info "[1/5] TTY pruefen..."

if [[ ! -t 0 ]]; then
    exit_error "Kein TTY verfuegbar. Bitte direkt aus einem Terminal starten.
  macOS:  open -a Terminal '$(basename "$0")' oder iTerm2 verwenden
  Linux:  In einem echten Terminal-Emulator ausfuehren"
else
    write_ok "TTY verfuegbar"
fi

# ══════════════════════════════════════════════════════════════
# [2/5] .env laden + Credentials sicherstellen
# ══════════════════════════════════════════════════════════════
write_sep
write_info "[2/5] Credentials (Senity Chat Proxy)..."

ENV_FILE="${SCRIPT_DIR}/.env"
read_env_file "$ENV_FILE"

default_url="https://sdr.senity.ai/api/claude-proxy"

if [[ -f "$ENV_FILE" ]]; then
    write_ok ".env gefunden: $ENV_FILE"
else
    write_info ".env existiert noch nicht — wird beim ersten gueltigen Key angelegt"
fi

# URL: aus .env, sonst Env-Var, sonst Default
base_url="${_env_SENITY_CHAT_PROXY_URL:-${SENITY_CHAT_PROXY_URL:-$default_url}}"

# Key: aus .env, sonst Env-Var
token="${_env_SENITY_CHAT_PROXY_KEY:-${SENITY_CHAT_PROXY_KEY:-}}"

key_ok=false
attempts=0
max_attempts=3
should_persist=false

while [[ "$key_ok" == false ]]; do
    if [[ -z "$token" ]]; then
        echo ""
        write_info "SENITY_CHAT_PROXY_KEY ist nicht gesetzt."
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
            exit_error "Kein Key eingegeben. Abbruch."
        fi
    fi

    write_info "Validiere Key gegen $base_url ..."
    set +e
    validate_senity_key "$base_url" "$token"
    rc=$?
    set -e

    case "$rc" in
        0)
            write_ok "Key valide (Auth OK)"
            if [[ "$base_url" == http://* && "$base_url" != http://localhost* && "$base_url" != http://127.* ]]; then
                write_warn "Proxy-URL nutzt HTTP (unverschluesselt). API-Key wird im Klartext uebertragen!"
                write_info "Empfehlung: HTTPS-Endpunkt verwenden."
            fi
            key_ok=true
            if [[ "$should_persist" == true ]]; then
                set_env_var "$ENV_FILE" "SENITY_CHAT_PROXY_URL" "$base_url"
                set_env_var "$ENV_FILE" "SENITY_CHAT_PROXY_KEY" "$token"
                write_ok ".env aktualisiert: $ENV_FILE"
            fi
            ;;
        1)
            attempts=$((attempts + 1))
            write_fail "Key-Validierung fehlgeschlagen: Unauthorized / Endpoint nicht gefunden"
            if [[ $attempts -ge $max_attempts ]]; then
                exit_error "Nach $max_attempts Versuchen kein gueltiger Key. Abbruch."
            fi
            write_info "Versuch $attempts/$max_attempts fehlgeschlagen. Bitte neuen Key eingeben."
            token=""
            should_persist=true
            ;;
        2)
            attempts=$((attempts + 1))
            write_fail "Netzwerkfehler beim Erreichen von $base_url"
            if [[ $attempts -ge $max_attempts ]]; then
                exit_error "Nach $max_attempts Versuchen kein gueltiger Key. Abbruch."
            fi
            write_info "Versuch $attempts/$max_attempts fehlgeschlagen. URL und Internetverbindung pruefen."
            token=""
            should_persist=true
            ;;
    esac
done

# Modell
default_model="qwen3.6:35b"
default_model_label="Senity Proxy"
if [[ -z "$MODEL" ]]; then MODEL="$default_model"; fi
if [[ "$MODEL" == "$default_model" ]]; then
    model_label="${default_model_label} (${default_model})"
else
    model_label="$MODEL"
fi
write_ok "Modell: $model_label"

# Yolo
write_ok "Yolo-Mode: $YOLO$(if [[ "$YOLO" == true ]]; then echo '  (Skip-Permissions aktiv, Container isoliert)'; fi)"

safe_user="$(whoami | tr -cd 'a-zA-Z0-9_.-' | tr '[:upper:]' '[:lower:]')"

# ══════════════════════════════════════════════════════════════
# [3/5] Docker pruefen
# ══════════════════════════════════════════════════════════════
write_sep
write_info "[3/5] Docker pruefen..."

if ! command -v docker &>/dev/null; then
    exit_error "Docker-CLI nicht im PATH gefunden.
  macOS:  brew install --cask docker
  Linux:  https://docs.docker.com/engine/install/"
fi
write_ok "Docker-CLI: $(command -v docker)"
write_ok "Docker-Version: $(docker --version 2>&1)"

# Docker Daemon
write_info "Pruefe Docker Daemon (docker info)..."
if ! docker info &>/dev/null; then
    write_warn "Docker Daemon nicht erreichbar."
    if [[ "$(uname)" == "Darwin" ]]; then
        write_info "Starte Docker Desktop..."
        open -a Docker
    else
        write_info "Starte Docker Daemon..."
        sudo systemctl start docker 2>/dev/null || true
    fi
    timeout_sec=120
    elapsed=0
    ready=false
    while [[ $elapsed -lt $timeout_sec ]]; do
        sleep 3
        elapsed=$((elapsed + 3))
        if docker info &>/dev/null; then ready=true; break; fi
        printf "  ${c_gray}[WAIT]${c_reset} Warte auf Docker... ($elapsed/$timeout_sec s)\n"
    done
    if [[ "$ready" != true ]]; then
        exit_error "Docker nach $timeout_sec Sekunden nicht bereit.
Bitte manuell starten und erneut versuchen."
    fi
    write_ok "Docker bereit"
else
    write_ok "Docker Daemon: bereit"
fi

# Image pruefen + ggf. bauen
write_info "Pruefe Docker Image 'senity-claude:latest'..."
needs_build=false

if [[ "$REBUILD" == true ]]; then
    write_info "Force-Rebuild angefordert. Loesche bestehendes Image (falls vorhanden)..."
    docker image rm senity-claude:latest &>/dev/null || true
    needs_build=true
else
    if ! docker image inspect senity-claude:latest &>/dev/null; then
        write_warn "Image 'senity-claude:latest' nicht gefunden."
        needs_build=true
    else
        image_created="$(docker image inspect senity-claude:latest --format '{{.Created}}' 2>&1)"
        write_ok "Image vorhanden (erstellt: $image_created)"
    fi
fi

if [[ "$needs_build" == true ]]; then
    dockerfile_path="${SCRIPT_DIR}/Dockerfile"
    if [[ ! -f "$dockerfile_path" ]]; then
        exit_error "Dockerfile nicht gefunden: $dockerfile_path"
    fi
    write_info "Starte Image-Build (kann 2-5 Minuten dauern)..."
    if ! docker build -t senity-claude:latest "$SCRIPT_DIR"; then
        exit_error "Image-Build fehlgeschlagen.
  Manueller Versuch: docker build -t senity-claude:latest '$SCRIPT_DIR'"
    fi
    write_ok "Image gebaut: senity-claude:latest"
fi

# Zombie-Container aufraemen
write_info "Pruefe auf veraltete Senity-Container..."
zombies="$(docker ps -a --filter "name=senity-workspace-${safe_user}" --filter "status=exited" --format '{{.Names}}' 2>&1 || true)"
zombie_count=0
if [[ -n "$zombies" ]]; then
    while IFS= read -r z; do
        z="$(echo "$z" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
        [[ -z "$z" ]] && continue
        if echo "$z" | grep -qE "^senity-workspace-${safe_user}-[0-9]+$"; then
            write_warn "Entferne veralteten Container: $z"
            docker rm -f "$z" &>/dev/null || true
            zombie_count=$((zombie_count + 1))
        fi
    done <<< "$zombies"
fi
if [[ $zombie_count -eq 0 ]]; then
    write_ok "Keine veralteten Container gefunden"
fi

# ══════════════════════════════════════════════════════════════
# [4/5] Mounts vorbereiten (Bindings.md, Workspace, .claude)
# ══════════════════════════════════════════════════════════════
write_sep
write_info "[4/5] Mounts vorbereiten..."

container_name="senity-workspace-${safe_user}-$$"
workspace_path="${SCRIPT_DIR}/workspace"
claude_dir="${SCRIPT_DIR}/.claude"

for dir in "$workspace_path" "$claude_dir"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        write_ok "Erstellt: $dir"
    else
        write_ok "Verzeichnis OK: $dir"
    fi
done

ssh_dir="$HOME/.ssh"
gitconfig="$HOME/.gitconfig"
if [[ -d "$ssh_dir" ]]; then
    write_ok "SSH-Dir: $ssh_dir (wird eingebunden)"
else
    write_warn "SSH-Dir nicht gefunden: $ssh_dir (kein Mount)"
fi
if [[ -f "$gitconfig" ]]; then
    write_ok ".gitconfig: gefunden (wird eingebunden)"
else
    write_warn ".gitconfig nicht gefunden: $gitconfig"
fi

DOCKER_ARGS=(
    -it --rm
    --name "$container_name"
    -v "${workspace_path}:/workspace"
    -v "${claude_dir}:/workspace/.claude"
    -w /workspace
)

# Bindings.md auto-create
bindings_file="${SCRIPT_DIR}/Bindings.md"
if [[ ! -f "$bindings_file" ]]; then
    cat > "$bindings_file" <<'BINDINGS'
# Senity Workspace — Mount-Pfade
# Format: <host-pfad>=<container-pfad>[:ro|:rw]
# Kommentare beginnen mit #, leere Zeilen werden ignoriert
#
# Host-Pfad:      beliebiges Verzeichnis — absolut (/Users/...), per ~ (~/projekte/foo)
#                 oder relativ zum Projektverzeichnis (../mein-projekt).
#                 Leerzeichen erlaubt; umschliessende '/" werden abgestreift.
# Container-Pfad: muss unterhalb von /workspace/ liegen (z.B. /workspace/mein-repo).
#                 /workspace selbst und /workspace/.claude sind reserviert.
# Modus:          optionales :ro (nur lesen) oder :rw (lesen+schreiben) am
#                 Container-Pfad. Ohne Angabe: rw.

# Beispiele:
# ~/projekte/mein-repo=/workspace/mein-repo
# /Users/ich/code/api=/workspace/api
# ../nachbar-projekt=/workspace/nachbar
# ~/docs/referenz=/workspace/referenz:ro
BINDINGS
    write_ok "Bindings.md angelegt (workspace/ ist bereits eingebunden — eigene Pfade ergaenzen)"
fi

write_info "Bindings.md wird ausgewertet..."
bind_count=0
# Reservierte Container-Mountziele: kollidieren mit den eingebauten Mounts
reserved_cpaths="/workspace /workspace/.claude"

while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(echo "$line" | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue

    # Host-Teil greedy bis zum letzten '=', Container-Teil ohne Space/'='.
    # Erlaubt Host-Pfade mit Leerzeichen (z.B. '/Users/x/Claude Workspace').
    if [[ "$line" =~ ^(.+)=([^[:space:]=]+)$ ]]; then
        host_part="${BASH_REMATCH[1]}"
        container_part="${BASH_REMATCH[2]}"

        # Whitespace um den Host-Pfad + umschliessende Quotes entfernen
        host_part="$(echo "$host_part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        host_part="${host_part#[\"\']}"
        host_part="${host_part%[\"\']}"

        # Optionales :ro/:rw-Suffix am Container-Pfad (Default: rw)
        mount_mode="rw"
        case "$container_part" in
            *:ro) mount_mode="ro"; container_part="${container_part%:ro}" ;;
            *:rw) mount_mode="rw"; container_part="${container_part%:rw}" ;;
        esac

        # Reservierte Container-Pfade pruefen
        is_reserved=false
        for bp in $reserved_cpaths; do
            if [[ "$container_part" == "$bp" ]]; then is_reserved=true; break; fi
        done
        if [[ "$is_reserved" == true ]]; then
            write_warn "Binding '$line' uebersprungen: '$container_part' reserviert (eingebauter Mount)"
            continue
        fi
        # Container-Pfad muss unterhalb von /workspace/ liegen
        case "$container_part" in
            /workspace/?*) ;;
            *)
                write_warn "Binding '$line' uebersprungen: '$container_part' nicht erlaubt (muss /workspace/<sub> sein)"
                continue
                ;;
        esac

        # ~ expandieren, dann Host-Pfad aufloesen (absolut oder relativ zum Projekt)
        case "$host_part" in
            "~")   host_part="$HOME" ;;
            "~/"*) host_part="${HOME}/${host_part#\~/}" ;;
        esac
        full_host="$(resolve_path "$host_part")"

        if [[ -d "$full_host" ]]; then
            # Pfad normalisieren (loest .. auf, portabel ohne GNU realpath)
            full_host="$(cd "$full_host" && pwd)"
            DOCKER_ARGS+=(-v "${full_host}:${container_part}:${mount_mode}")
            write_ok "Mount: $full_host => $container_part ($mount_mode)"
            bind_count=$((bind_count + 1))
        else
            write_warn "Binding-Pfad nicht gefunden (uebersprungen): $full_host"
        fi
    else
        write_warn "Ungueltige Binding-Zeile (Format: hostpfad=/workspace/<sub>): '$line'"
    fi
done < "$bindings_file"
write_ok "$bind_count Bindings aktiv"

# SSH + Git Mounts
if [[ -d "$ssh_dir" ]]; then
    DOCKER_ARGS+=(-v "${ssh_dir}:/workspace/.ssh:ro")
fi
if [[ -f "$gitconfig" ]]; then
    DOCKER_ARGS+=(-v "${gitconfig}:/workspace/.gitconfig:ro")
fi

# Environment
DOCKER_ARGS+=(-e "ANTHROPIC_BASE_URL=${base_url}")
DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=${token}")
DOCKER_ARGS+=(-e "HOME=/workspace")
DOCKER_ARGS+=(-e "TERM=xterm-256color")

# Claude-Argumente
CLAUDE_ARGS=("senity-mascot-filter" "claude" "--model" "$MODEL")
if [[ "$YOLO" == true ]]; then
    CLAUDE_ARGS+=("--dangerously-skip-permissions")
fi

# ══════════════════════════════════════════════════════════════
# [5/5] Container starten
# ══════════════════════════════════════════════════════════════
write_sep
write_info "[5/5] Container starten..."

echo ""
printf "  ${c_magenta}════════════════════════════════════════════${c_reset}\n"
printf "  ${c_white}Provider  : Senity Chat Proxy${c_reset}\n"
printf "  ${c_white}URL       : %s${c_reset}\n" "$base_url"
printf "  ${c_white}Modell    : %s${c_reset}\n" "$model_label"
printf "  ${c_white}Yolo      : %s${c_reset}\n" "$YOLO"
printf "  ${c_white}Container : %s${c_reset}\n" "$container_name"
printf "  ${c_magenta}════════════════════════════════════════════${c_reset}\n"
echo ""
printf "  ${c_green}Starte Claude Code... (Ctrl+C zum Beenden)${c_reset}\n"
echo ""

set +e
if [[ ${#EXTRA[@]} -gt 0 ]]; then
    docker run "${DOCKER_ARGS[@]}" senity-claude:latest "${CLAUDE_ARGS[@]}" "${EXTRA[@]}"
else
    docker run "${DOCKER_ARGS[@]}" senity-claude:latest "${CLAUDE_ARGS[@]}"
fi
container_exit=$?
set -e

echo ""
if [[ $container_exit -eq 0 || $container_exit -eq 130 ]]; then
    write_ok "Claude Code beendet (Exit: $container_exit)"
else
    write_fail "Container beendet mit Exit-Code: $container_exit"
    case $container_exit in
        125) write_info "Exit 125: Docker konnte Container nicht starten (Image-Problem?)" ;;
        126) write_info "Exit 126: Entrypoint nicht ausfuehrbar" ;;
        127) write_info "Exit 127: 'claude' nicht gefunden im Container" ;;
        1)   write_info "Exit 1: Allgemeiner Fehler" ;;
        *)   write_info "Unbekannter Exit-Code. Logs: docker logs $container_name" ;;
    esac
fi
echo ""
exit $container_exit
