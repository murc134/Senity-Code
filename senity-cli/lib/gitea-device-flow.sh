#!/usr/bin/env bash
# lib/gitea-device-flow.sh
#
# OAuth2 Device Authorization Grant (RFC 8628) gegen Gitea (git.senity.ai).
# Wird via `source` in senity.sh geladen. Stellt Funktionen bereit:
#   gitea_device_init         -> JSON auf stdout, Exit 6 bei Netzwerk
#   gitea_poll_token          -> JSON auf stdout, Exit 0/4/5/6
#   gitea_refresh             -> JSON auf stdout, Exit 0/3/6
#   gitea_persist_auth        -> schreibt ~/.senity/auth.json (0600)
#   gitea_read_auth           -> JSON auf stdout, Exit 2 wenn fehlt
#   gitea_write_docker_config -> patcht ~/.docker/config.json atomar
#   gitea_revoke              -> best-effort Revoke
#   gitea_show_user_code      -> Plain + QR + Direktlink
#
# Tokens werden NIE geloggt. Nur Status-Meldungen.

# ---- Konstanten -------------------------------------------------------------
GITEA_HOST="${SENITY_GITEA_HOST:-https://git.senity.ai}"
GITEA_CLIENT_ID="${SENITY_GITEA_CLIENT_ID:-}"
GITEA_SCOPES="${SENITY_GITEA_SCOPES:-read:package read:repository}"
GITEA_POLL_HARD_CAP="${SENITY_GITEA_POLL_HARD_CAP:-900}"
GITEA_POLL_CAP_INTERVAL="${SENITY_GITEA_POLL_CAP_INTERVAL:-30}"
GITEA_AUTH_FILE="${SENITY_HOME:-$HOME/.senity}/auth.json"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG:-$HOME/.docker}"
DOCKER_CONFIG_FILE="${DOCKER_CONFIG_DIR}/config.json"

# ---- Logging (Tokens NIE ausgeben) ------------------------------------------
gitea_log()  { printf '\033[38;5;141m[gitea]\033[0m %s\n' "$*" >&2; }
gitea_warn() { printf '\033[38;5;214m[gitea]\033[0m %s\n' "$*" >&2; }
gitea_err()  { printf '\033[38;5;199m[gitea]\033[0m %s\n' "$*" >&2; }

# ---- Dependency-Check -------------------------------------------------------
gitea_require_deps() {
    local missing=()
    command -v curl    >/dev/null 2>&1 || missing+=("curl")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    if [ ${#missing[@]} -gt 0 ]; then
        gitea_err "Pflicht-Tools fehlen: ${missing[*]}"
        return 6
    fi
    return 0
}

# ---- JSON-Helper (python3 fuer Robustheit) ----------------------------------
gitea_json_get() {
    local key="$1"
    SENITY_JSON_KEY="$key" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
    v = d.get(os.environ["SENITY_JSON_KEY"])
    print("" if v is None else v)
except Exception:
    print("")
'
}

# ---- Atomic write (tmp + rename) --------------------------------------------
gitea_atomic_write() {
    local target="$1" mode="${2:-0644}"
    local dir; dir="$(dirname "$target")"
    mkdir -p "$dir"
    local tmp; tmp="${target}.tmp.$$"
    cat > "$tmp"
    chmod "$mode" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target"
}

# ---- Endpoints --------------------------------------------------------------
gitea_device_init() {
    if [[ -z "$GITEA_CLIENT_ID" ]]; then
        gitea_err "SENITY_GITEA_CLIENT_ID nicht gesetzt"
        return 6
    fi
    local resp
    resp=$(curl -sS \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "client_id=${GITEA_CLIENT_ID}" \
        --data-urlencode "scope=${GITEA_SCOPES}" \
        "${GITEA_HOST}/login/oauth/device" 2>/dev/null) || {
        gitea_err "Device-Init Netzwerkfehler"
        return 6
    }
    if [[ -z "$resp" ]]; then
        gitea_err "Device-Init lieferte leere Response"
        return 6
    fi
    printf '%s' "$resp"
}

gitea_poll_token() {
    local device_code="$1" interval="${2:-5}"
    local start_ts; start_ts=$(date +%s)
    while true; do
        local now elapsed
        now=$(date +%s)
        elapsed=$((now - start_ts))
        if [ "$elapsed" -ge "$GITEA_POLL_HARD_CAP" ]; then
            gitea_err "Polling-Hard-Cap (${GITEA_POLL_HARD_CAP}s) erreicht"
            return 4
        fi
        sleep "$interval"
        local resp
        resp=$(curl -sS \
            -H 'Accept: application/json' \
            -H 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
            --data-urlencode "device_code=${device_code}" \
            --data-urlencode "client_id=${GITEA_CLIENT_ID}" \
            "${GITEA_HOST}/login/oauth/access_token" 2>/dev/null) || {
            gitea_warn "Polling-Netzwerkfehler, retry"
            continue
        }
        local err_code; err_code=$(printf '%s' "$resp" | gitea_json_get error)
        case "$err_code" in
            "")
                printf '%s' "$resp"
                return 0
                ;;
            authorization_pending) continue ;;
            slow_down)
                interval=$((interval + 5))
                [ "$interval" -gt "$GITEA_POLL_CAP_INTERVAL" ] && interval="$GITEA_POLL_CAP_INTERVAL"
                ;;
            expired_token) gitea_err "device_code abgelaufen"; return 4 ;;
            access_denied) gitea_err "Login abgelehnt"; return 5 ;;
            *) gitea_err "Unbekannter OAuth-Fehler: ${err_code}"; return 6 ;;
        esac
    done
}

gitea_refresh() {
    local rt="$1"
    if [[ -z "$GITEA_CLIENT_ID" ]]; then
        gitea_err "SENITY_GITEA_CLIENT_ID nicht gesetzt"
        return 6
    fi
    local resp
    resp=$(curl -sS \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "grant_type=refresh_token" \
        --data-urlencode "refresh_token=${rt}" \
        --data-urlencode "client_id=${GITEA_CLIENT_ID}" \
        "${GITEA_HOST}/login/oauth/access_token" 2>/dev/null) || {
        gitea_err "Refresh-Netzwerkfehler"
        return 6
    }
    local err_code; err_code=$(printf '%s' "$resp" | gitea_json_get error)
    if [[ -z "$err_code" ]]; then
        printf '%s' "$resp"
        return 0
    fi
    if [[ "$err_code" = "invalid_grant" ]]; then
        return 3
    fi
    gitea_err "Refresh-Fehler: ${err_code}"
    return 6
}

# ---- User-Code-Anzeige ------------------------------------------------------
gitea_show_user_code() {
    local user_code="$1" uri="$2" uri_complete="$3"
    printf '\n' >&2
    printf '  \033[1mOeffne im Browser:\033[0m  %s\n' "$uri" >&2
    printf '  \033[1mUser-Code:\033[0m          \033[1;36m%s\033[0m\n' "$user_code" >&2
    printf '  \033[1mDirektlink:\033[0m         %s\n' "$uri_complete" >&2
    printf '\n' >&2
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 -m 1 "$uri_complete" >&2
        printf '\n' >&2
    fi
}

# ---- Auth-File IO -----------------------------------------------------------
gitea_read_auth() {
    if [[ ! -f "$GITEA_AUTH_FILE" ]]; then
        return 2
    fi
    cat "$GITEA_AUTH_FILE"
}

gitea_persist_auth() {
    local token_json="$1"
    local at rt expires_in
    at=$(printf '%s' "$token_json" | gitea_json_get access_token)
    rt=$(printf '%s' "$token_json" | gitea_json_get refresh_token)
    expires_in=$(printf '%s' "$token_json" | gitea_json_get expires_in)
    if [[ -z "$at" || -z "$rt" ]]; then
        gitea_err "Token-Response unvollstaendig"
        return 6
    fi
    SENITY_AT="$at" SENITY_RT="$rt" SENITY_EXPIRES_IN="${expires_in:-3600}" \
    SENITY_SCOPES="$GITEA_SCOPES" SENITY_HOST="$GITEA_HOST" \
    python3 <<'PY' | gitea_atomic_write "$GITEA_AUTH_FILE" 0600
import os, json, time, urllib.request
at = os.environ['SENITY_AT']
rt = os.environ['SENITY_RT']
try:
    expires_in = int(os.environ.get('SENITY_EXPIRES_IN', '3600'))
except ValueError:
    expires_in = 3600
host = os.environ['SENITY_HOST']
now = int(time.time())
expires_at = now + max(60, expires_in - 60)
user = {'id': 0, 'login': ''}
try:
    req = urllib.request.Request(f'{host}/api/v1/user',
                                  headers={'Authorization': f'Bearer {at}'})
    with urllib.request.urlopen(req, timeout=10) as r:
        user = json.loads(r.read().decode())
except Exception:
    pass
out = {
    'gitea_user': user.get('login', ''),
    'gitea_user_id': user.get('id', 0),
    'refresh_token': rt,
    'access_token': at,
    'access_token_expires_at': expires_at,
    'scopes': os.environ['SENITY_SCOPES'],
    'connected_at': now,
}
print(json.dumps(out, indent=2))
PY
}

# ---- Docker-Config Patch ----------------------------------------------------
gitea_write_docker_config() {
    local at="$1"
    mkdir -p "$DOCKER_CONFIG_DIR"
    local existing="{}"
    [[ -f "$DOCKER_CONFIG_FILE" ]] && existing=$(cat "$DOCKER_CONFIG_FILE")
    SENITY_AT="$at" SENITY_EXISTING="$existing" SENITY_HOST_NAME="${GITEA_HOST#https://}" \
    python3 <<'PY' | gitea_atomic_write "$DOCKER_CONFIG_FILE" 0600
import os, json, base64
try:
    cfg = json.loads(os.environ['SENITY_EXISTING'])
    if not isinstance(cfg, dict): cfg = {}
except Exception:
    cfg = {}
cfg.setdefault('auths', {})
host = os.environ['SENITY_HOST_NAME'].rstrip('/')
auth = base64.b64encode(f"oauth2:{os.environ['SENITY_AT']}".encode()).decode()
cfg['auths'][host] = {'auth': auth}
print(json.dumps(cfg, indent=2))
PY
}

# ---- Revoke (best-effort) ---------------------------------------------------
gitea_revoke() {
    local rt="$1"
    [[ -z "$rt" ]] && return 0
    curl -sS -X POST \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "token=${rt}" \
        --data-urlencode "client_id=${GITEA_CLIENT_ID}" \
        "${GITEA_HOST}/login/oauth/revoke" >/dev/null 2>&1 || true
}

# ---- Token-Frische -----------------------------------------------------------
# Echo "fresh" | "stale" | "missing" auf stdout, immer Exit 0
gitea_token_freshness() {
    local skew="${1:-60}"
    if [[ ! -f "$GITEA_AUTH_FILE" ]]; then
        printf 'missing'
        return 0
    fi
    SENITY_AUTH_FILE="$GITEA_AUTH_FILE" SENITY_SKEW="$skew" python3 -c '
import os, json, sys, time
try:
    with open(os.environ["SENITY_AUTH_FILE"]) as f:
        d = json.load(f)
    exp = int(d.get("access_token_expires_at", 0))
    skew = int(os.environ["SENITY_SKEW"])
    print("fresh" if exp > int(time.time()) + skew else "stale")
except Exception:
    print("missing")
' 2>/dev/null
}
