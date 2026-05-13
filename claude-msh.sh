#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# claude-msh — Claude Code gegen Self-Hosted Modelle (Linux/macOS)
#
# Spricht das oeffentliche Gateway https://gateway.missionstarkeshandwerk.de
# (Caddy → cc-adapter:8765 fuer /v1/messages, sonst LiteLLM:4000).
# Auth ueber LITELLM_MASTER_KEY (env-var oder ~/.config/claude-msh/auth).
#
# Usage:
#   claude-msh                        Default-Modell qwen3.6
#   claude-msh "frag mich was"        Argumente werden an `claude` durchgereicht
#   claude-msh -m gpt-4o "..."        Modell waehlen (siehe `claude-msh --list`)
#   claude-msh --list                 Verfuegbare Modelle vom Gateway abfragen
#   claude-msh -e <url> ...           Anderen Endpoint (z.B. http://localhost:11434)
#
# Voraussetzung: `claude` CLI installiert (npm install -g @anthropic-ai/claude-code).
# ══════════════════════════════════════════════════════════════
set -euo pipefail

GATEWAY_URL_DEFAULT="https://gateway.missionstarkeshandwerk.de"
MODEL_DEFAULT="qwen3.6"
AUTH_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-msh/auth"

GATEWAY_URL="${CLAUDE_MSH_URL:-$GATEWAY_URL_DEFAULT}"
MODEL="$MODEL_DEFAULT"
LIST_ONLY=0
EXTRA=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)    MODEL="$2"; shift 2 ;;
        -e|--endpoint) GATEWAY_URL="$2"; shift 2 ;;
        -l|--list)     LIST_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done

TOKEN="${LITELLM_MASTER_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"
if [[ -z "$TOKEN" && -f "$AUTH_FILE" ]]; then
    TOKEN="$(tr -d '[:space:]' < "$AUTH_FILE")"
fi

if [[ -z "$TOKEN" ]]; then
    cat >&2 <<EOF
FEHLER: Kein Auth-Token gefunden.

Setz die Env-Variable LITELLM_MASTER_KEY, oder schreib den Key nach:
    $AUTH_FILE   (chmod 600)

Den Key findest du auf opus in /home/msh/gateway-stack/.env (LITELLM_MASTER_KEY=...).
EOF
    exit 1
fi

if [[ "$LIST_ONLY" == "1" ]]; then
    curl -fsS -H "Authorization: Bearer $TOKEN" "$GATEWAY_URL/v1/models" \
        | python3 -c 'import sys,json
for m in json.load(sys.stdin).get("data", []):
    print(m["id"])'
    exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
    cat >&2 <<EOF
FEHLER: claude CLI nicht gefunden.
Installation: npm install -g @anthropic-ai/claude-code
EOF
    exit 1
fi

export ANTHROPIC_BASE_URL="$GATEWAY_URL"
export ANTHROPIC_AUTH_TOKEN="$TOKEN"
export ANTHROPIC_API_KEY="$TOKEN"

exec claude --model "$MODEL" "${EXTRA[@]}"
