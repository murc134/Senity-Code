#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# claude-msh — Claude Code gegen Self-Hosted Modelle (Linux/macOS)
#
# Liest .env aus dem eigenen Verzeichnis und leitet auf MSH vLLM
# oder Gateway um. Primar: direkter vLLM-Endpoint (thinking support).
#
# Usage:
#   claude-msh                        Default-Modell qwen3.6
#   claude-msh "frag mich was"        Argumente an claude weiterleiten
#   claude-msh -m gpt-4o "..."        Modell waehlen
#
# Voraussetzung: claude CLI installiert + .env im Script-Verzeichnis.
# ══════════════════════════════════════════════════════════════
set -euo pipefail

# ── Script-Verzeichnis ermitteln ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── .env parsen ──
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

# ── Werte aus .env ──
MODEL="${1:-}"
LIST_ONLY=0
EXTRA=()
GATEWAY_URL="${CLAUDE_MSH_URL:-${ENV_VARS[MSH_API_URL]:-https://gateway.missionstarkeshandwerk.de}}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)  MODEL="$2"; shift 2 ;;
        -e|--endpoint) GATEWAY_URL="$2"; shift 2 ;;
        -l|--list)   LIST_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done

# Token: vLLM zuerst, dann Gateway
TOKEN="${ENV_VARS[MSH_VLLM_API_KEY]:-${LITELLM_MASTER_KEY:-${ENV_VARS[MSH_API_KEY]:-}}}"

if [[ -z "$TOKEN" ]]; then
    cat >&2 <<EOF
FEHLER: Kein Auth-Token gefunden.

Pruefe .env im Script-Verzeichnis: $ENV_FILE

Oder setz die Env-Variable: LITELLM_MASTER_KEY
EOF
    exit 1
fi

VLLM_URL="${ENV_VARS[MSH_VLLM_URL]:-}"
MODEL_DEFAULT="${ENV_VARS[MSH_VLLM_MODEL]:-qwen3.6}"

if [[ -z "$MODEL" ]]; then
    if [[ -n "$VLLM_URL" ]]; then
        MODEL="$MODEL_DEFAULT"
    else
        MODEL="qwen3.6"
    fi
fi

# Endpoint: vLLM primar, Fallback Gateway
if [[ -z "$GATEWAY_URL" || "$GATEWAY_URL" == *"missionstarkeshandwerk.de" ]]; then
    if [[ -n "$VLLM_URL" ]]; then
        GATEWAY_URL="$VLLM_URL"
    fi
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

# vLLM nutzt OpenAI-kompatibles Format
if [[ "$GATEWAY_URL" == *"$VLLM_URL"* && -n "$VLLM_URL" ]]; then
    export OPENAI_BASE_URL="$GATEWAY_URL"
    export OPENAI_API_KEY="$TOKEN"
    unset ANTHROPIC_BASE_URL 2>/dev/null || true
    unset ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
    unset ANTHROPIC_API_KEY 2>/dev/null || true
else
    export ANTHROPIC_BASE_URL="$GATEWAY_URL"
    export ANTHROPIC_API_KEY="$TOKEN"
    unset ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
    unset OPENAI_BASE_URL 2>/dev/null || true
    unset OPENAI_API_KEY 2>/dev/null || true
fi

exec claude --model "$MODEL" "${EXTRA[@]}"
