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

# ── Image sicherstellen — es muss existieren UND codex + gemini enthalten ──
# (ein altes Image von vor der codex/gemini-Einfuehrung wird sonst nicht erkannt).
image_has_clis() {
    docker run --rm --entrypoint sh "$IMAGE" \
        -c 'command -v codex >/dev/null 2>&1 && command -v gemini >/dev/null 2>&1' &>/dev/null
}
need_build=0
if ! docker image inspect "$IMAGE" &>/dev/null; then
    info "Image '$IMAGE' fehlt."
    need_build=1
elif ! image_has_clis; then
    info "Vorhandenes Image enthaelt codex/gemini noch nicht — Rebuild noetig."
    need_build=1
fi
if [[ $need_build -eq 1 ]]; then
    info "Baue Image '$IMAGE' (installiert u.a. codex + gemini)..."
    if ! docker build -t "$IMAGE" "$SCRIPT_DIR"; then
        err "Image-Build fehlgeschlagen."
        exit 1
    fi
fi
ok "Image bereit: $IMAGE"

mkdir -p "$WORKSPACE"

# ── Token-Dateien zur Erfolgskontrolle (workspace-relativ) ──
CODEX_CRED=".codex/auth.json"
GEMINI_CRED=".gemini/oauth_creds.json"

# ── Login im Container ──
# 1) prueft, ob die CLI ueberhaupt im Image ist (npm-Install ist soft-fail),
# 2) startet den interaktiven Login, 3) verifiziert per Token-Datei.
run_login() {
    local label="$1" cred="$2"; shift 2
    local cli="$1"
    if ! docker run --rm --entrypoint sh "$IMAGE" -c "command -v $cli >/dev/null 2>&1"; then
        err "${label}: '$cli' ist nicht im Image — npm-Install beim Build fehlgeschlagen."
        err "       Image neu bauen:  docker build -t $IMAGE \"$SCRIPT_DIR\""
        return 1
    fi
    echo ""
    info "Starte ${label}-Login im Container — folge dem Browser-/Device-Flow."
    docker run -it --rm \
        -v "${WORKSPACE}:/workspace" \
        -e "HOME=/workspace" \
        -e "TERM=xterm-256color" \
        -w /workspace \
        "$IMAGE" "$@"
    local rc=$?
    if [[ -e "${WORKSPACE}/${cred}" ]]; then
        ok "${label}: angemeldet."
        return 0
    fi
    err "${label}: kein Token gefunden — Login nicht abgeschlossen (Exit $rc)."
    return 1
}

echo ""
echo "  Was einrichten?"
echo "    [1] Codex (ChatGPT-Account)"
echo "    [2] Gemini (Google-Account)"
echo "    [3] Beide   (Default)"
echo "    [q] Abbrechen"
read -r -p "  Auswahl [3]: " sel
sel="${sel:-3}"

overall=0
case "$sel" in
    1) run_login "Codex"  "$CODEX_CRED"  codex login || overall=1 ;;
    2) run_login "Gemini" "$GEMINI_CRED" gemini       || overall=1 ;;
    3) run_login "Codex"  "$CODEX_CRED"  codex login  || overall=1
       run_login "Gemini" "$GEMINI_CRED" gemini       || overall=1 ;;
    q|Q) info "Abgebrochen."; exit 0 ;;
    *)   err "Ungueltige Auswahl: $sel"; exit 1 ;;
esac

echo ""
if [[ $overall -eq 0 ]]; then
    ok "Login abgeschlossen — beim naechsten ./claude-senity.sh stehen die CLIs"
    ok "angemeldet im Container bereit (Token in workspace/.codex bzw. .gemini)."
else
    err "Mindestens ein Login wurde nicht abgeschlossen — Script erneut ausfuehren."
fi
echo ""
echo "  Hinweis: Bei Gemini im Menue 'Login with Google' waehlen; nach dem"
echo "           Anmelden mit /quit beenden. 'codex login' beendet sich selbst."
echo "  Re-Login: workspace/.codex bzw. workspace/.gemini loeschen, Script erneut starten."
echo ""
exit $overall
