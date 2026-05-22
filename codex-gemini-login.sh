#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# codex-gemini-login.sh — Codex / Gemini CLI einrichten + anmelden
# Senity Workspace
#
# Eigenstaendiges Script — bewusst NICHT Teil von claude-senity.sh.
# Der Login passiert hier, getrennt vom normalen Container-Start.
#
# Ablauf:
#   1. Stellt das Docker-Image sicher (baut es bei Bedarf — der Build
#      installiert codex + gemini ins Image).
#   2. Startet codex bzw. gemini interaktiv im Workspace-Container.
#   3. Du meldest dich per OAuth an. Tokens landen in
#      workspace/.codex bzw. workspace/.gemini und bleiben erhalten —
#      beim naechsten ./claude-senity.sh stehen sie im Container bereit.
# ══════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="senity-claude:latest"
WORKSPACE="${SCRIPT_DIR}/workspace"

c_g="\033[0;32m"; c_m="\033[0;35m"; c_r="\033[0;31m"; c_x="\033[0m"
info() { printf "  ${c_m}[INFO]${c_x} %s\n" "$1"; }
ok()   { printf "  ${c_g}[OK]  ${c_x} %s\n" "$1"; }
err()  { printf "  ${c_r}[FAIL]${c_x} %s\n" "$1"; }

echo ""
echo "  ┌──────────────────────────────────────────┐"
echo "  │  Codex / Gemini — CLI-Login (Senity)      │"
echo "  └──────────────────────────────────────────┘"
echo ""

# ── TTY ──
if [[ ! -t 0 ]]; then
    err "Kein TTY verfuegbar. Bitte direkt aus einem Terminal starten."
    exit 1
fi

# ── Docker ──
if ! command -v docker &>/dev/null; then
    err "Docker nicht gefunden. Docker Desktop installieren und erneut starten."
    exit 1
fi
if ! docker info &>/dev/null; then
    err "Docker-Daemon laeuft nicht. Docker Desktop starten und erneut versuchen."
    exit 1
fi
ok "Docker bereit"

# ── Image sicherstellen (Build installiert codex + gemini) ──
if ! docker image inspect "$IMAGE" &>/dev/null; then
    info "Image '$IMAGE' fehlt — wird gebaut (installiert u.a. codex + gemini)..."
    if ! docker build -t "$IMAGE" "$SCRIPT_DIR"; then
        err "Image-Build fehlgeschlagen."
        exit 1
    fi
fi
ok "Image bereit: $IMAGE  (codex + gemini sind enthalten)"

mkdir -p "$WORKSPACE"

# ── Login im Container ──
run_login() {
    local label="$1"; shift
    echo ""
    info "Starte ${label}-Login im Container — folge dem Browser-/Device-Flow."
    docker run -it --rm \
        -v "${WORKSPACE}:/workspace" \
        -e "HOME=/workspace" \
        -e "TERM=xterm-256color" \
        -w /workspace \
        "$IMAGE" "$@"
}

echo ""
echo "  Was einrichten?"
echo "    [1] Codex (ChatGPT-Account)"
echo "    [2] Gemini (Google-Account)"
echo "    [3] Beide   (Default)"
echo "    [q] Abbrechen"
read -r -p "  Auswahl [3]: " sel
sel="${sel:-3}"

case "$sel" in
    1) run_login "Codex"  codex login ;;
    2) run_login "Gemini" gemini ;;
    3) run_login "Codex"  codex login
       run_login "Gemini" gemini ;;
    q|Q) info "Abgebrochen."; exit 0 ;;
    *)   err "Ungueltige Auswahl: $sel"; exit 1 ;;
esac

echo ""
ok "Login-Vorgang beendet."
info "Codex:  Token in workspace/.codex/   Gemini: Token in workspace/.gemini/"
info "Beim naechsten ./claude-senity.sh stehen codex/gemini im Container bereit."
echo ""
echo "  Hinweis: Bei Gemini im Menue 'Login with Google' waehlen; nach dem"
echo "           Anmelden mit /quit beenden. codex login beendet sich selbst."
echo ""
