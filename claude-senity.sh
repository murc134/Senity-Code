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

# Originalargumente sichern, bevor sie weiter unten zerlegt werden — fuer
# einen moeglichen Re-Exec nach Launcher-Self-Update.
ORIGINAL_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Kanonische Klon-URL des Launcher-Repos (Self-Update + Bootstrap).
# Port :2200 wird direkt angesprochen — kein ~/.ssh/config-Alias noetig.
CLAUDE_LOCAL_REPO_URL='ssh://git@git.senity.ai:2200/senity-admin/senity-claude-code.git'

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
        --max-time 45 \
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

# ── Sicherstellen, dass git auf dem Host vorhanden ist ──
# Das Repo-Setup + Launcher-Self-Update laufen auf dem HOST (vor dem
# Container-Start) und brauchen git. Im Container ist git ohnehin im Image.
ensure_git() {
    command -v git &>/dev/null && return 0
    write_warn "git nicht gefunden — Installationsversuch..."
    if [[ "$(uname)" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
            brew install git || true
        else
            write_info "Starte Xcode Command Line Tools (enthalten git)..."
            xcode-select --install 2>/dev/null || true
            write_warn "GUI-Installation abschliessen, dann Launcher neu starten."
        fi
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update -qq || true; sudo apt-get install -y git || true
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y git || true
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm git || true
    elif command -v zypper &>/dev/null; then
        sudo zypper install -y git || true
    else
        write_warn "Kein bekannter Paketmanager — git bitte manuell installieren."
    fi
    if command -v git &>/dev/null; then
        write_ok "git installiert: $(command -v git)"
        return 0
    fi
    write_warn "git weiterhin nicht verfuegbar — Repo-Setup wird uebersprungen."
    return 1
}

# ── Einen Deploy-Key on-demand aus .env.shared dekodieren ──
# Echoes Pfad zur dekodierten Datei oder leer bei Fehlschlag.
get_deploy_key_file() {
    local key_name="$1"
    local shared="${SCRIPT_DIR}/.env.shared"
    local key_dir="${SCRIPT_DIR}/.deploy-keys"
    local kf="${key_dir}/${key_name}"
    [[ -f "$shared" ]] || return 1
    if [[ -s "$kf" ]]; then echo "$kf"; return 0; fi
    local b64_decode=""
    if command -v openssl &>/dev/null; then b64_decode="openssl base64 -d -A"
    elif command -v base64 &>/dev/null; then b64_decode="base64 --decode"
    else return 1; fi
    mkdir -p "$key_dir"; chmod 700 "$key_dir" 2>/dev/null || true
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^${key_name}_B64=(.+)$ ]]; then
            if printf '%s' "${BASH_REMATCH[1]}" | $b64_decode > "$kf" 2>/dev/null && [[ -s "$kf" ]]; then
                chmod 600 "$kf" 2>/dev/null || true
                echo "$kf"; return 0
            fi
            rm -f "$kf"
            return 1
        fi
    done < "$shared"
    return 1
}

# ── Self-Update / Bootstrap des Launcher-Repos ──
# Vor allem anderen: claude-local pullen. ScriptDir ist kein Git-Repo?
# -> initial klonen via Deploy-Key (claude-local → senity-workspace → ~/.ssh).
# Bei HEAD-Aenderung Re-Exec mit der neuen Version.
launcher_self_update() {
    if [[ "${SENITY_SELF_UPDATE_DONE:-}" == "1" ]]; then
        write_dbg "Self-Update bereits gelaufen, ueberspringe"
        return 0
    fi

    if ! ensure_git; then
        write_warn "git fehlt — Launcher-Self-Update uebersprungen."
        return 0
    fi

    local -a ssh_cmds=()
    local k kf
    for k in claude-local senity-workspace; do
        kf="$(get_deploy_key_file "$k" 2>/dev/null || true)"
        if [[ -n "$kf" && -f "$kf" ]]; then
            ssh_cmds+=("ssh -i \"${kf}\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new")
        fi
    done
    ssh_cmds+=("ssh -o StrictHostKeyChecking=accept-new")

    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
        write_info "Pruefe auf neue Launcher-Version (git pull)..."
        local old_head new_head pulled=false cmd
        old_head="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"
        for cmd in "${ssh_cmds[@]}"; do
            if GIT_SSH_COMMAND="$cmd" git -C "$SCRIPT_DIR" pull --ff-only --quiet 2>/dev/null; then
                pulled=true; break
            fi
        done
        if [[ "$pulled" != true ]]; then
            write_warn "Launcher-Self-Update fehlgeschlagen — bestehende Version wird genutzt."
            return 0
        fi
        new_head="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"
        if [[ -n "$new_head" && -n "$old_head" && "$new_head" != "$old_head" ]]; then
            write_ok "Launcher aktualisiert (${old_head:0:7} -> ${new_head:0:7}). Re-Start mit neuer Version..."
            export SENITY_SELF_UPDATE_DONE=1
            exec "$0" "${ORIGINAL_ARGS[@]}"
        fi
        write_ok "Launcher ist aktuell"
        return 0
    fi

    # Bootstrap: ScriptDir ist kein Git-Repo.
    write_info "Launcher-Verzeichnis ist kein Git-Repo — initialer Bootstrap"
    write_dbg "Klon-URL: $CLAUDE_LOCAL_REPO_URL"
    local fetched=false cmd
    ( cd "$SCRIPT_DIR" && git init --quiet ) 2>/dev/null || true
    ( cd "$SCRIPT_DIR" && git remote remove origin 2>/dev/null || true )
    ( cd "$SCRIPT_DIR" && git remote add origin "$CLAUDE_LOCAL_REPO_URL" ) 2>/dev/null || true
    for cmd in "${ssh_cmds[@]}"; do
        if ( cd "$SCRIPT_DIR" && GIT_SSH_COMMAND="$cmd" git fetch --quiet origin main ) 2>/dev/null; then
            fetched=true; break
        fi
    done
    if [[ "$fetched" != true ]]; then
        write_warn "Bootstrap-Fetch fehlgeschlagen — Launcher laeuft mit aktuellem Stand weiter."
        rm -rf "${SCRIPT_DIR}/.git" 2>/dev/null || true
        return 0
    fi
    ( cd "$SCRIPT_DIR" && git checkout -fB main origin/main ) 2>/dev/null || true
    ( cd "$SCRIPT_DIR" && git reset --hard origin/main ) 2>/dev/null || true
    local head
    head="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    write_ok "Launcher-Repo initialisiert (HEAD=${head}). Re-Start mit verifizierter Version..."
    export SENITY_SELF_UPDATE_DONE=1
    exec "$0" "${ORIGINAL_ARGS[@]}"
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
printf "   \033[38;2;135;95;175m███████╗███████╗███╗   ██╗██╗████████╗██╗   ██╗${c_reset}\n"
printf "   \033[38;2;157;111;200m██╔════╝██╔════╝████╗  ██║██║╚══██╔══╝╚██╗ ██╔╝${c_reset}\n"
printf "   \033[38;2;175;135;255m███████╗█████╗  ██╔██╗ ██║██║   ██║    ╚████╔╝ ${c_reset}\n"
printf "   \033[38;2;201;95;210m╚════██║██╔══╝  ██║╚██╗██║██║   ██║     ╚██╔╝  ${c_reset}\n"
printf "   \033[38;2;230;46;190m███████║███████╗██║ ╚████║██║   ██║      ██║   \033[38;2;255;0;175m●${c_reset}\n"
printf "   \033[38;2;255;0;175m╚══════╝╚══════╝╚═╝  ╚═══╝╚═╝   ╚═╝      ╚═╝   ${c_reset}\n"
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
# [1/6] TTY pruefen
# ══════════════════════════════════════════════════════════════
write_info "[1/6] TTY pruefen..."

if [[ ! -t 0 ]]; then
    exit_error "Kein TTY verfuegbar. Bitte direkt aus einem Terminal starten.
  macOS:  open -a Terminal '$(basename "$0")' oder iTerm2 verwenden
  Linux:  In einem echten Terminal-Emulator ausfuehren"
else
    write_ok "TTY verfuegbar"
fi

# ══════════════════════════════════════════════════════════════
# Launcher-Self-Update / Bootstrap (vor allem anderen Setup)
# Holt die neueste Version des claude-local-Repos. Wenn das ScriptDir
# noch kein Git-Repo ist (Files manuell kopiert), wird es initial geklont.
# Bei HEAD-Aenderung Re-Exec mit der neuen Version.
# ══════════════════════════════════════════════════════════════
write_sep
write_info "Launcher-Update pruefen..."
launcher_self_update

# ══════════════════════════════════════════════════════════════
# [2/6] .env laden + Credentials sicherstellen
# ══════════════════════════════════════════════════════════════
write_sep
write_info "[2/6] Credentials (Senity Chat Proxy)..."

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
            write_info "Versuch $attempts/$max_attempts fehlgeschlagen. Bitte Key erneut eingeben."
            token=""
            should_persist=true
            ;;
        2)
            attempts=$((attempts + 1))
            write_fail "Netzwerkfehler beim Erreichen von $base_url"
            write_warn "Proxy nicht erreichbar oder antwortet zu langsam. Der Key wurde NICHT als ungueltig erkannt."
            read -r -p "  Trotzdem starten und Key-Check ueberspringen? [Y/n]: " skip_resp
            skip_resp="$(echo "${skip_resp:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [[ -z "$skip_resp" || "$skip_resp" == "y" || "$skip_resp" == "j" || "$skip_resp" == "yes" || "$skip_resp" == "ja" ]]; then
                write_warn "Key-Validierung uebersprungen. Wenn der Key falsch ist, schlaegt die erste Claude-Anfrage fehl."
                key_ok=true
                if [[ "$should_persist" == true ]]; then
                    set_env_var "$ENV_FILE" "SENITY_CHAT_PROXY_URL" "$base_url"
                    set_env_var "$ENV_FILE" "SENITY_CHAT_PROXY_KEY" "$token"
                    write_ok ".env aktualisiert: $ENV_FILE"
                fi
                continue
            fi
            if [[ $attempts -ge $max_attempts ]]; then
                exit_error "Nach $max_attempts Versuchen kein gueltiger Key. Abbruch."
            fi
            write_info "Versuch $attempts/$max_attempts fehlgeschlagen. URL und Internetverbindung pruefen, dann Key erneut eingeben."
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
# [3/6] Docker pruefen
# ══════════════════════════════════════════════════════════════
write_sep
write_info "[3/6] Docker pruefen..."

ensure_docker() {
    command -v docker &>/dev/null && return 0
    write_warn "Docker-CLI nicht gefunden. Installationsversuch..."
    if [[ "$(uname)" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
            brew install --cask docker || true
            write_info "Docker Desktop installiert. Bitte einmalig manuell starten (Datenschutzdialog), dann Launcher erneut aufrufen."
        else
            write_warn "Homebrew nicht verfuegbar. Docker Desktop manuell installieren: https://docs.docker.com/desktop/install/mac-install/"
        fi
    else
        write_warn "Auto-Install auf Linux nicht aktiv (Docker-Engine-Setup ist distrospezifisch und root-pflichtig)."
        write_warn "Bitte manuell installieren: https://docs.docker.com/engine/install/"
    fi
    command -v docker &>/dev/null
}

if ! command -v docker &>/dev/null; then
    ensure_docker || true
fi
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
# Verwaltete Repos — werden vor dem Container-Start geklont/gepullt.
# Fest hinterlegt (Teil des Setups, nicht ueber .bindings steuerbar).
# MODE: fresh = bei jedem Start loeschen + neu klonen; pull = klonen-
# oder-pullen.
# Hinweis: senity-workspace ist KEIN Managed Repo — der Pfad wird
# interaktiv beim Erst-Start abgefragt (ensure_senity_workspace),
# damit Nutzer einen bereits vorhandenen lokalen Workspace mounten
# koennen statt ihn neben den eigenen zu klonen.
# ══════════════════════════════════════════════════════════════
MANAGED_REPO_KEYS=( "claude-skills" "claude-commands" "claude-agents" "senity-mcps" )
MANAGED_REPO_URLS=(
    "git@github.com:murc134/Claude-Skills.git"
    "git@github.com:murc134/Claude-Commands.git"
    "git@github.com:murc134/Claude-Agents.git"
    "ssh://git@git.senity.ai:2200/senity/senity-mcps.git"
)
MANAGED_REPO_DIRS=(
    "workspace/.claude/skills/intern"
    "workspace/.claude/commands/intern"
    "workspace/.claude/agents/intern"
    "workspace/.mcp/senity-mcps"
)
MANAGED_REPO_MODES=( "fresh" "fresh" "fresh" "pull" )

# Marker fuer den auto-verwalteten Block in .bindings
MANAGED_BIND_BEGIN="# >>> SENITY-VERWALTET (auto-generiert vom Repo-Setup) >>>"
MANAGED_BIND_END="# <<< SENITY-VERWALTET <<<"

# Marker fuer den interaktiv konfigurierten senity-workspace-Block in .bindings.
# Wird von ensure_senity_workspace() geschrieben (einmalig beim Erst-Start oder
# bei verlorenem Host-Pfad). Eigene Eintraege ausserhalb der Marker bleiben.
WORKSPACE_BIND_BEGIN="# >>> SENITY-WORKSPACE (interaktiv konfiguriert) >>>"
WORKSPACE_BIND_END="# <<< SENITY-WORKSPACE <<<"
WORKSPACE_CONTAINER_PATH="/workspace/projects/senity-workspace"
WORKSPACE_REPO_URL="ssh://git@git.senity.ai:2200/senity/senity-workspace.git"

# ── Ein Repo klonen (Deploy-Key bevorzugt, Fallback normaler ~/.ssh) ──
clone_managed_repo() {
    local url="$1" dir="$2" kf="$3"
    local ssh_cmd="ssh -o StrictHostKeyChecking=accept-new"
    [[ -f "$kf" ]] && ssh_cmd="ssh -i \"${kf}\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    mkdir -p "$(dirname "$dir")"
    GIT_SSH_COMMAND="$ssh_cmd" git clone --quiet --branch main "$url" "$dir" 2>/dev/null && return 0
    git clone --quiet --branch main "$url" "$dir" 2>/dev/null
}

# ensure_git ist oben im Skript definiert (wird vom Self-Update gebraucht).

# ── Repo-Setup: Deploy-Keys dekodieren, Repos klonen/pullen ──
setup_repos() {
    if ! command -v git &>/dev/null; then
        write_warn "git nicht gefunden — Repo-Setup uebersprungen."
        return 0
    fi
    local shared_env="${SCRIPT_DIR}/.env.shared"
    local key_dir="${SCRIPT_DIR}/.deploy-keys"

    # 1) Deploy-Keys aus .env.shared nach .deploy-keys/ dekodieren (chmod 600).
    # base64-Decoder: bevorzugt openssl, sonst das base64-Tool.
    local b64_decode=""
    if command -v openssl &>/dev/null; then b64_decode="openssl base64 -d -A"
    elif command -v base64 &>/dev/null; then b64_decode="base64 --decode"; fi
    if [[ -f "$shared_env" && -n "$b64_decode" ]]; then
        chmod 600 "$shared_env" 2>/dev/null || true
        mkdir -p "$key_dir"; chmod 700 "$key_dir" 2>/dev/null || true
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ "$line" =~ ^([A-Za-z0-9_-]+)_B64=(.+)$ ]]; then
                local kn="${BASH_REMATCH[1]}"
                local kf="${key_dir}/${kn}"
                if printf '%s' "${BASH_REMATCH[2]}" | $b64_decode > "$kf" 2>/dev/null && [[ -s "$kf" ]]; then
                    chmod 600 "$kf" 2>/dev/null || true
                else
                    write_warn "Deploy-Key '$kn' nicht dekodierbar — uebersprungen."
                    rm -f "$kf"
                fi
            fi
        done < "$shared_env"
    elif [[ -f "$shared_env" ]]; then
        write_warn "Weder openssl noch base64 gefunden — Deploy-Keys uebersprungen, ~/.ssh-Fallback aktiv."
    fi

    # 2) Repos klonen / pullen (je nach MODE).
    local i=0
    local n=${#MANAGED_REPO_KEYS[@]}
    while [[ $i -lt $n ]]; do
        local kn="${MANAGED_REPO_KEYS[$i]}"
        local url="${MANAGED_REPO_URLS[$i]}"
        local rel="${MANAGED_REPO_DIRS[$i]}"
        local mode="${MANAGED_REPO_MODES[$i]}"
        local dir="${SCRIPT_DIR}/${rel}"
        local kf="${key_dir}/${kn}"

        if [[ "$mode" == "pull" && -d "${dir}/.git" ]]; then
            write_info "Repo aktualisieren (pull): ${rel}"
            local ssh_cmd="ssh -o StrictHostKeyChecking=accept-new"
            [[ -f "$kf" ]] && ssh_cmd="ssh -i \"${kf}\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
            if ! GIT_SSH_COMMAND="$ssh_cmd" git -C "$dir" pull --ff-only --quiet 2>/dev/null \
               && ! git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
                write_warn "Pull fehlgeschlagen (${rel}) — vorhandener Stand wird genutzt."
            fi
        elif [[ "$mode" == "fresh" ]]; then
            # Frisch klonen: erst in ein Temp-Verzeichnis, dann atomar tauschen —
            # so bleibt der vorherige Stand bei fehlgeschlagenem Clone erhalten.
            write_info "Repo frisch klonen: ${rel}"
            local tmp="${dir}.tmp.$$"
            rm -rf "$tmp"
            if clone_managed_repo "$url" "$tmp" "$kf"; then
                rm -rf "$dir" && mv "$tmp" "$dir"
            else
                rm -rf "$tmp"
                write_warn "Klonen fehlgeschlagen (${url}) — vorhandener Stand bleibt erhalten."
            fi
        else
            write_info "Repo klonen: ${rel}"
            if ! clone_managed_repo "$url" "$dir" "$kf"; then
                write_warn "Klonen fehlgeschlagen (${url}) — Deploy-Key evtl. nicht registriert, kein ~/.ssh-Zugang."
            fi
        fi
        i=$((i + 1))
    done

    # 3) private/-Verzeichnisse anlegen — Mount-Quelle fuer selbst angelegte
    #    Skills/Commands/Agents (die Mounts kommen aus .bindings).
    local sub
    for sub in skills commands agents; do
        mkdir -p "${SCRIPT_DIR}/workspace/.claude/${sub}/private"
    done
}

# ── .bindings: auto-verwalteten Block der Repo-Mounts neu schreiben ──
# Eigene Eintraege ausserhalb der Marker bleiben unangetastet.
update_managed_bindings() {
    local bf="$1"
    [[ -f "$bf" ]] || return 0
    local kept
    # CR-tolerant: Marker auch erkennen, wenn .bindings CRLF-Zeilenenden hat.
    kept="$(awk -v b="$MANAGED_BIND_BEGIN" -v e="$MANAGED_BIND_END" '
        { l=$0; sub(/\r$/,"",l) }
        l==b {skip=1} !skip {print l} l==e {skip=0}' "$bf")"
    {
        printf '%s\n\n' "$kept"
        echo "$MANAGED_BIND_BEGIN"
        echo "# Auto-generiert vom Repo-Setup, Aenderungen hier werden bei jedem"
        echo "# Start ueberschrieben. Enthaelt die Mounts fuer die intern/private"
        echo "# .claude-Quellen. Der senity-workspace-Mount steht in einem eigenen"
        echo "# Block (# >>> SENITY-WORKSPACE >>>), interaktiv konfiguriert."
        local sub
        for sub in skills commands agents; do
            [[ -d "${SCRIPT_DIR}/workspace/.claude/${sub}/intern" ]] && \
                echo "workspace/.claude/${sub}/intern=/workspace/.claude/${sub}/intern:ro"
            echo "workspace/.claude/${sub}/private=/workspace/.claude/${sub}/private:rw"
        done
        # Repo-eigener Skill-Ordner (read-only) des claude-local-Launchers.
        [[ -d "${SCRIPT_DIR}/skills" ]] && \
            echo "skills=/workspace/.claude/skills/senity-workspace:ro"
        # Hinweis: INITIAL_PROMPT.md wird NICHT als File-Bind-Mount gemountet —
        # Docker Desktop macOS (virtiofs) lehnt geschachtelte File-Mounts in den
        # /workspace-Mount ab ("mountpoint is outside of rootfs"). Stattdessen
        # spiegelt sync_autostart_initial_prompt die Datei bidirektional zwischen
        # Repo-Root und workspace/projects/autostart/, das ueber den vorhandenen
        # /workspace-Mount sichtbar ist.
        echo "$MANAGED_BIND_END"
    } > "$bf"
}

# INITIAL_PROMPT.md bidirektional zwischen Repo-Root und der gitignorierten
# Workspace-Kopie spiegeln. Loest das Mac/virtiofs-Problem: statt eines
# geschachtelten File-Bind-Mounts liegt die Datei innerhalb des bestehenden
# /workspace-Mounts und ist damit auf allen Plattformen erreichbar.
# Newer-wins beim Start; Container-Edits propagieren beim naechsten Launcher-Start.
sync_autostart_initial_prompt() {
    local root="${SCRIPT_DIR}/INITIAL_PROMPT.md"
    [[ -f "$root" ]] || return 0
    local auto_dir="${SCRIPT_DIR}/workspace/projects/autostart"
    mkdir -p "$auto_dir"
    local copy="${auto_dir}/INITIAL_PROMPT.md"
    if [[ ! -f "$copy" ]]; then
        cp -f "$root" "$copy"
        return 0
    fi
    # mtime-Vergleich, GNU/BSD-portabel: zwei stat-Varianten probieren.
    local root_mt copy_mt
    root_mt=$(stat -c %Y "$root" 2>/dev/null || stat -f %m "$root" 2>/dev/null || echo 0)
    copy_mt=$(stat -c %Y "$copy" 2>/dev/null || stat -f %m "$copy" 2>/dev/null || echo 0)
    if (( copy_mt > root_mt )); then
        cp -f "$copy" "$root"
        write_ok "INITIAL_PROMPT.md: Container-Edit -> Repo-Root uebernommen"
    elif (( root_mt > copy_mt )); then
        cp -f "$root" "$copy"
    fi
}

# ══════════════════════════════════════════════════════════════
# senity-workspace: interaktiver Mount-Setup
# Liest den Host-Pfad aus dem WORKSPACE-Block in .bindings. Fehlt der
# Block oder zeigt er auf einen nicht (mehr) existierenden Pfad, wird
# der Nutzer gefragt: bereits installiert (Pfad eingeben) oder klonen.
# Beim Pfad-Modus wird NICHT gepullt (User-Verantwortung).
# ══════════════════════════════════════════════════════════════
read_workspace_host_from_bindings() {
    local bf="$1"
    [[ -f "$bf" ]] || return 0
    awk -v b="$WORKSPACE_BIND_BEGIN" -v e="$WORKSPACE_BIND_END" \
        -v cpath="$WORKSPACE_CONTAINER_PATH" '
        { l=$0; sub(/\r$/,"",l) }
        l==b { inblk=1; next }
        l==e { inblk=0; next }
        inblk==1 {
            t=l
            sub(/^[[:space:]]+/,"",t); sub(/[[:space:]]+$/,"",t)
            if (t=="" || substr(t,1,1)=="#") next
            n=split(t, a, "=")
            if (n<2) next
            host=a[1]
            cp=a[n]; for (i=n-1;i>=2;i--) cp=a[i] "=" cp
            sub(/:ro$/,"",cp); sub(/:rw$/,"",cp)
            if (cp==cpath) { print host; exit }
        }' "$bf"
}

resolve_workspace_host() {
    local p="$1"
    case "$p" in
        "~")   printf '%s' "$HOME" ;;
        "~/"*) printf '%s' "${HOME}/${p#\~/}" ;;
        /*|[A-Za-z]:[\\/]*) printf '%s' "$p" ;;
        *)     printf '%s' "${SCRIPT_DIR}/${p}" ;;
    esac
}

remove_workspace_block() {
    local bf="$1"
    [[ -f "$bf" ]] || return 0
    local tmp
    tmp="$(awk -v b="$WORKSPACE_BIND_BEGIN" -v e="$WORKSPACE_BIND_END" '
        { l=$0; sub(/\r$/,"",l) }
        l==b {skip=1} !skip {print l} l==e {skip=0}' "$bf")"
    printf '%s\n' "$tmp" > "$bf"
}

write_workspace_block() {
    local bf="$1" host_path="$2"
    remove_workspace_block "$bf"
    {
        echo ""
        echo "$WORKSPACE_BIND_BEGIN"
        echo "# Vom Launcher interaktiv beim Erst-Start gesetzt. Pfad existiert"
        echo "# nicht mehr -> Block wird verworfen und Dialog erneut gestartet."
        echo "${host_path}=${WORKSPACE_CONTAINER_PATH}:rw"
        echo "$WORKSPACE_BIND_END"
    } >> "$bf"
}

ensure_senity_workspace() {
    local bf="$1"
    local host_path resolved
    host_path="$(read_workspace_host_from_bindings "$bf")"
    if [[ -n "$host_path" ]]; then
        resolved="$(resolve_workspace_host "$host_path")"
        if [[ -d "$resolved" ]]; then
            write_ok "senity-workspace: $host_path"
            return 0
        fi
        write_warn "senity-workspace-Pfad fehlt: $resolved — Konfiguration wird neu abgefragt."
        remove_workspace_block "$bf"
    fi

    if [[ ! -t 0 ]]; then
        write_warn "senity-workspace nicht konfiguriert und kein TTY — bitte Launcher interaktiv starten."
        return 0
    fi

    echo
    write_info "senity-workspace ist noch nicht konfiguriert."
    local answer
    read -r -p "Hast du den senity-workspace bereits lokal installiert? [j/N] " answer
    if [[ "$answer" =~ ^[jJyY]([aA]?|[eE][sS])?$ ]]; then
        local input check
        while true; do
            read -r -p "Pfad zum bestehenden senity-workspace: " input
            input="${input%/}"
            input="${input%\\}"
            if [[ -z "$input" ]]; then
                write_warn "Leerer Pfad — Konfiguration abgebrochen."
                return 0
            fi
            check="$(resolve_workspace_host "$input")"
            if [[ -d "$check" ]]; then
                write_workspace_block "$bf" "$input"
                write_ok "senity-workspace eingetragen: $input"
                return 0
            fi
            write_warn "Pfad nicht gefunden: $check"
        done
    fi

    read -r -p "Soll ich den senity-workspace nach workspace/projects/senity-workspace klonen? [j/N] " answer
    if [[ "$answer" =~ ^[jJyY]([aA]?|[eE][sS])?$ ]]; then
        local rel="workspace/projects/senity-workspace"
        local dir="${SCRIPT_DIR}/${rel}"
        local kf="${SCRIPT_DIR}/.deploy-keys/senity-workspace"
        write_info "Klone senity-workspace nach ${rel}..."
        mkdir -p "$(dirname "$dir")"
        if [[ -d "$dir" ]]; then
            write_warn "Zielverzeichnis existiert bereits — Block wird ohne Klonen eingetragen."
            write_workspace_block "$bf" "$rel"
            write_ok "senity-workspace eingetragen: $rel"
            return 0
        fi
        if clone_managed_repo "$WORKSPACE_REPO_URL" "$dir" "$kf"; then
            write_workspace_block "$bf" "$rel"
            write_ok "senity-workspace geklont und eingetragen: $rel"
        else
            write_warn "Klonen fehlgeschlagen (Deploy-Key evtl. nicht registriert, kein ~/.ssh-Zugang)."
        fi
    else
        write_warn "senity-workspace bleibt unkonfiguriert — Container startet ohne Workspace-Mount."
    fi
}

# ══════════════════════════════════════════════════════════════
# [4/6] Verwaltete Repos klonen/pullen (vor dem Container-Start)
# ══════════════════════════════════════════════════════════════
write_sep
write_info "[4/6] Repo-Setup (verwaltete Repos)..."
ensure_git || true
setup_repos

# ══════════════════════════════════════════════════════════════
# [5/6] Mounts vorbereiten (.bindings, Workspace, .claude)
# ══════════════════════════════════════════════════════════════
write_sep
write_info "[5/6] Mounts vorbereiten..."

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

# .bindings ist im Repo enthalten (initial state nach Klon), aber lokale
# Aenderungen sollen git nicht stoeren -> einmalig --skip-worktree setzen.
# Idempotent: prueft den aktuellen Zustand und macht nur bei Bedarf etwas.
bindings_file="${SCRIPT_DIR}/.bindings"
if [[ ! -f "$bindings_file" ]]; then
    # Fallback falls die Datei manuell geloescht wurde (sollte nicht passieren,
    # da sie im Repo liegt). Minimaler Inhalt; Launcher fuellt dann den
    # SENITY-VERWALTET-Block.
    cat > "$bindings_file" <<'BINDINGS'
# Format: <host>=<container>[:ro|:rw]   Excludes: !<glob>
BINDINGS
    write_ok ".bindings angelegt (war nicht vorhanden)"
fi
# skip-worktree fuer .bindings setzen, damit lokale Edits nicht im git-status
# auftauchen. 'git ls-files -v' markiert skip-worktree mit 'S'; nur setzen,
# wenn noch nicht aktiv. Best-effort: still scheitern falls kein git-Repo.
if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ "$(git -C "$SCRIPT_DIR" ls-files -v -- .bindings 2>/dev/null | cut -c1)" != "S" ]]; then
        git -C "$SCRIPT_DIR" update-index --skip-worktree .bindings 2>/dev/null && \
            write_ok ".bindings: skip-worktree gesetzt (lokale Edits werden nicht getrackt)"
    fi
fi

# Repo-Mounts als auto-verwalteten Block in .bindings schreiben/aktualisieren
update_managed_bindings "$bindings_file"

# INITIAL_PROMPT.md zwischen Repo-Root und workspace/projects/autostart/ syncen
sync_autostart_initial_prompt

# senity-workspace-Mount interaktiv setzen (oder ueberspringen falls schon ok)
ensure_senity_workspace "$bindings_file"

# Pre-Scan: '!<glob>'-Excludes einsammeln (gelten global fuer alle Mounts).
exclude_patterns=()
while IFS= read -r pre_line || [[ -n "$pre_line" ]]; do
    pre_line="${pre_line%$'\r'}"
    pre_line="$(echo "$pre_line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    [[ -z "$pre_line" ]] && continue
    case "$pre_line" in
        '#'*) continue ;;
        '!'*)
            pat="${pre_line#!}"
            pat="$(echo "$pat" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -n "$pat" ]] && exclude_patterns+=("$pat")
            ;;
    esac
done < "$bindings_file"

# Empty-Stage (leerer Ordner + leere Datei) als Overlay-Quelle fuer Excludes.
mount_stage_dir="${SCRIPT_DIR}/.mount-stage"
empty_dir="${mount_stage_dir}/empty"
empty_file="${mount_stage_dir}/empty.file"
if [[ ${#exclude_patterns[@]} -gt 0 ]]; then
    mkdir -p "$empty_dir"
    [[ -f "$empty_file" ]] || : > "$empty_file"
    write_info "Excludes aktiv: ${exclude_patterns[*]}"
fi

overlay_count=0
# Haengt fuer einen Mount (Source + Container-Base) Overlay-Mounts an DOCKER_ARGS
# fuer alle Glob-Treffer. Unterstuetzt '**/<name>' (rekursiv) und '<name>'
# (top-level). Pattern mit '/' im Restmuster werden uebersprungen.
append_exclude_overlays() {
    local src="$1"
    local cbase="$2"
    [[ ${#exclude_patterns[@]} -eq 0 ]] && return
    [[ ! -d "$src" ]] && return
    local pat name recursive maxdepth_arg seen_file
    seen_file="$(mktemp 2>/dev/null || echo "${mount_stage_dir}/.seen.$$")"
    : > "$seen_file"
    for pat in "${exclude_patterns[@]}"; do
        name="$pat"
        recursive=0
        if [[ "$pat" == '**/'* ]]; then
            name="${pat#**/}"
            recursive=1
        fi
        case "$name" in
            */*|*\\*)
                write_warn "Exclude '$pat' uebersprungen (nur Basename-Pattern unterstuetzt)"
                continue
                ;;
        esac
        if [[ "$recursive" -eq 1 ]]; then
            maxdepth_arg=()
        else
            maxdepth_arg=(-maxdepth 1)
        fi
        while IFS= read -r -d '' hit; do
            rel="${hit#$src}"
            rel="${rel#/}"
            [[ -z "$rel" ]] && continue
            grep -Fxq "$rel" "$seen_file" && continue
            printf '%s\n' "$rel" >> "$seen_file"
            if [[ -d "$hit" ]]; then
                DOCKER_ARGS+=(-v "${empty_dir}:${cbase}/${rel}:ro")
            else
                DOCKER_ARGS+=(-v "${empty_file}:${cbase}/${rel}:ro")
            fi
            overlay_count=$((overlay_count + 1))
        done < <(find "$src" "${maxdepth_arg[@]}" -name "$name" -print0 2>/dev/null)
    done
    local cnt
    cnt=$(wc -l < "$seen_file" | tr -d ' ')
    rm -f "$seen_file"
    if [[ "${cnt:-0}" -gt 0 ]]; then
        write_info "  ${cnt} Exclude-Overlay(s) angehaengt"
    fi
}

write_info ".bindings wird ausgewertet..."
bind_count=0
# Reservierte Container-Mountziele: kollidieren mit den eingebauten Mounts
reserved_cpaths="/workspace /workspace/.claude"

while IFS= read -r line || [[ -n "$line" ]]; do
    # Carriage-Return strippen (Windows-Editoren) und trimmen
    line="${line%$'\r'}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

    # Leerzeilen, '#'-Kommentare und '!'-Excludes (im Pre-Scan erledigt) skippen.
    [[ -z "$line" ]] && continue
    case "$line" in
        '#'*|'!'*) continue ;;
    esac

    # Host-Teil greedy bis zum letzten '=', Container-Teil ohne Space/'='.
    # Container-Pfad muss mit '/' beginnen (sonst ist es keine Mount-Zeile,
    # sondern z.B. Markdown-Prosa mit '=' im Fliesstext).
    if [[ "$line" =~ ^(.+)=(/[^[:space:]=]+)$ ]]; then
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
            append_exclude_overlays "$full_host" "$container_part"
        elif [[ -f "$full_host" ]]; then
            # File-Bind-Mount (z.B. .bindings selbst): Parent normalisieren,
            # dann Basename anhaengen. Keine Excludes auf Dateien.
            file_parent="$(cd "$(dirname "$full_host")" && pwd)"
            full_host="${file_parent}/$(basename "$full_host")"
            DOCKER_ARGS+=(-v "${full_host}:${container_part}:${mount_mode}")
            write_ok "Mount: $full_host => $container_part ($mount_mode, file)"
            bind_count=$((bind_count + 1))
        else
            write_warn "Binding-Pfad nicht gefunden (uebersprungen): $full_host"
        fi
    else
        write_warn "Ungueltige Binding-Zeile (Format: hostpfad=/workspace/<sub>): '$line'"
    fi
done < "$bindings_file"
if [[ "$overlay_count" -gt 0 ]]; then
    write_ok "$bind_count Bindings aktiv, $overlay_count Exclude-Overlay(s)"
else
    write_ok "$bind_count Bindings aktiv"
fi

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

# INITIAL_PROMPT.md dynamisch einlesen (bei jedem Start neu, kein Rebuild noetig).
# HTML-Kommentarbloecke <!-- ... --> werden entfernt. Der gereinigte Inhalt
# wird in eine Datei innerhalb /workspace geschrieben; der Container-
# Entrypoint reicht ihn als erste (sichtbare) User-Nachricht an Claude Code
# weiter. Wenn der Nutzer eigene positionale Argumente uebergeben hat (EXTRA
# enthaelt mind. ein Argument ohne "-"-Praefix), wird die Datei nicht
# geschrieben und Claude startet ohne automatische Nachricht.
has_user_prompt=false
if [[ ${#EXTRA[@]} -gt 0 ]]; then
    for e in "${EXTRA[@]}"; do
        if [[ -n "$e" && "${e:0:1}" != "-" ]]; then
            has_user_prompt=true
            break
        fi
    done
fi

initial_prompt_host_file="${workspace_path}/.senity-initial-prompt"
rm -f "$initial_prompt_host_file" 2>/dev/null || true

if [[ "$has_user_prompt" == false ]]; then
    sys_prompt_file="${SCRIPT_DIR}/INITIAL_PROMPT.md"
    if [[ -f "$sys_prompt_file" ]]; then
        if command -v perl &>/dev/null; then
            sys_prompt_content="$(perl -0777 -pe 's/<!--.*?-->//gs' "$sys_prompt_file")"
        else
            sys_prompt_content="$(sed '/<!--/,/-->/d' "$sys_prompt_file")"
        fi
        # Trim Whitespace vorne und hinten
        sys_prompt_content="$(printf '%s' "$sys_prompt_content" | awk '{ lines=lines $0 ORS } END { sub(/^[[:space:]]+/, "", lines); sub(/[[:space:]]+$/, "", lines); printf "%s", lines }')"
        if [[ -n "$(printf '%s' "$sys_prompt_content" | tr -d '[:space:]')" ]]; then
            printf '%s' "$sys_prompt_content" > "$initial_prompt_host_file"
            DOCKER_ARGS+=(-e "SENITY_INITIAL_PROMPT_FILE=/workspace/.senity-initial-prompt")
            write_ok "INITIAL_PROMPT.md wird als erste User-Nachricht gesendet"
        fi
    fi
fi

# Hinweis: Der Codex-/Gemini-Login passiert NICHT mehr hier im Launcher.
# Wer Codex/Gemini im Container nutzen will, fuehrt einmalig das separate
# Script aus:  ./codex-gemini-login.sh   (Windows: codex-gemini-login.bat)

# ══════════════════════════════════════════════════════════════
# [6/6] Container starten
# ══════════════════════════════════════════════════════════════
write_sep
write_info "[6/6] Container starten..."

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
