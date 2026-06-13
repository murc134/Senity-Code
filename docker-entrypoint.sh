#!/bin/bash
set -euo pipefail

# ── Senity Workspace Container Entry Point ──

# Config-Directory existenz pruefen — HOME=/workspace, daher /workspace/.claude
if [[ ! -d "${HOME}/.claude" ]]; then
    mkdir -p "${HOME}/.claude" 2>/dev/null || true
fi

# ── Onboarding-/Login-Screen unterdruecken ──
# Claude Code zeigt die Login-Auswahl ("Select login method"), solange
# ~/.claude.json kein hasCompletedOnboarding:true enthaelt. Da der Provider
# fest der Senity Chat Proxy ist, wird Onboarding einmalig als abgeschlossen
# markiert. Zusaetzlich wird customApiKeyResponses.rejected geleert: Claude
# Code behandelt einen via ANTHROPIC_API_KEY gesetzten Key als "custom API
# key" mit Approve/Reject — ein einmal abgelehnter Key wuerde sonst dauerhaft
# zum Login-Screen fuehren.
# Zusaetzlich wird das Theme bei jedem Start auf "senity" gesetzt — so ist das
# Senity-Theme immer der Default (das Bundle bringt "senity" als auswaehlbares
# Theme mit, siehe patch-claude-header.js / themeStructureReplacements).
CLAUDE_JSON="${HOME}/.claude.json"
if command -v jq >/dev/null 2>&1; then
    if [[ -f "$CLAUDE_JSON" ]]; then
        tmp_json="$(mktemp)"
        if jq '.hasCompletedOnboarding = true
               | .theme = "senity"
               | if has("customApiKeyResponses")
                 then .customApiKeyResponses.rejected = []
                 else . end' \
              "$CLAUDE_JSON" > "$tmp_json" 2>/dev/null; then
            cat "$tmp_json" > "$CLAUDE_JSON"
        fi
        rm -f "$tmp_json"
    else
        printf '{"hasCompletedOnboarding":true,"theme":"senity"}\n' > "$CLAUDE_JSON"
    fi

    # ── MCP node_modules sicherstellen ──
    # senity-mcps wird im 'pull'-Modus geklont (kein fresh), damit die
    # node_modules unterhalb jedes <mcp>/-Ordners persistent bleiben.
    # Beim ersten Start (oder nach manuellem Loeschen) fehlt das Verzeichnis
    # und wird hier einmalig installiert. Danach kein Overhead.
    if command -v npm >/dev/null 2>&1; then
        shopt -s nullglob
        for pkg_json in /workspace/.mcp/senity-mcps/*/package.json; do
            mcp_dir="$(dirname "$pkg_json")"
            if [[ ! -d "$mcp_dir/node_modules" ]]; then
                echo "[mcp] install deps: $(basename "$mcp_dir")"
                (cd "$mcp_dir" && npm install --silent --no-audit --no-fund 2>&1 | tail -n 3) || \
                    echo "[mcp] WARN: install fuer $(basename "$mcp_dir") fehlgeschlagen"
            fi
        done
        shopt -u nullglob
    fi

    # ── MCP-Server-Sync ──
    # Quelle 1 (Repo, read-only): /workspace/.mcp/senity-mcps/mcpServers.json
    #   - vom Host-Launcher bei jedem Start frisch geklont (fresh-Modus)
    #   - enthaelt nur Server-Struktur (command/args/env-Schluessel), KEINE Secrets
    # Quelle 2 (User, persistent): /workspace/.mcp-config.json
    #   - gitignored, vom Nutzer gepflegt
    #   - liefert env-Overrides (z.B. API-Keys) UND eigene zusaetzliche Server
    # Merge-Regel: Repo-Struktur als Basis, .mcp-config.json deep-merged (Werte
    # aus der User-Datei gewinnen). Resultat ersetzt .mcpServers in .claude.json.
    MCP_REPO="${HOME}/.mcp/senity-mcps/mcpServers.json"
    MCP_USER="${HOME}/.mcp-config.json"
    if [[ -f "$MCP_REPO" || -f "$MCP_USER" ]]; then
        tmp_repo="$(mktemp)"
        tmp_user="$(mktemp)"
        [[ -f "$MCP_REPO" ]] && jq '.mcpServers // .' "$MCP_REPO" > "$tmp_repo" 2>/dev/null || echo '{}' > "$tmp_repo"
        [[ -f "$MCP_USER" ]] && jq '.mcpServers // .' "$MCP_USER" > "$tmp_user" 2>/dev/null || echo '{}' > "$tmp_user"
        tmp_merged="$(mktemp)"
        # Deep-Merge: a * b -> rekursiv, b gewinnt bei Konflikt
        if jq -s '.[0] * .[1]' "$tmp_repo" "$tmp_user" > "$tmp_merged" 2>/dev/null; then
            tmp_out="$(mktemp)"
            if jq --slurpfile m "$tmp_merged" '.mcpServers = $m[0]' "$CLAUDE_JSON" > "$tmp_out" 2>/dev/null; then
                cat "$tmp_out" > "$CLAUDE_JSON"
            fi
            rm -f "$tmp_out"
        fi
        rm -f "$tmp_repo" "$tmp_user" "$tmp_merged"
    fi
fi

# ── Senity Theme laden (zentrale Farb-Konfiguration) ──
# Defaults, falls Theme-File fehlt
PRIMARY_256=99
SECONDARY_256=141
ACCENT_256=199
THEME_FILE="${SENITY_THEME_FILE:-/etc/senity-theme.conf}"
if [[ -f "$THEME_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$THEME_FILE"
fi

# ── Senity Banner ──
# Senity Brain-Logo: Brain (= + ~ glow), Dot-Cluster (l/I/t/;/,/!/+) und SENITY-Block (@).
# Skip wenn kein TTY oder SENITY_NO_BANNER gesetzt.
if [[ -t 1 && -z "${SENITY_NO_BANNER:-}" ]]; then
    ESC=$'\033'

    # Senity Wordmark in Unicode-Block-Schrift mit vertikalem Lila->Pink-Verlauf:
    # Zeile 1 startet in Senity-Lila (PRIMARY), die letzte Zeile endet in Pink
    # (ACCENT), dazwischen wird in 24-Bit-Truecolor linear interpoliert. So
    # markiert die farbige Variante (im Gegensatz zum bewusst weissen Launcher-
    # Banner) den Uebergang Host -> Senity. Endpunkte folgen dem Theme via
    # *_RGB; die 256-Color-Indizes des Themes approximieren #875faf schlecht
    # (139 ist blasses Mauve), darum interpolieren wir auf RGB statt auf Index.
    # Der Akzent-Dot (●) wird inline auf den Pink-Ton umgeschaltet -- so
    # umgehen wir Bash-Byte-Slicing-Probleme mit Multibyte-Chars.
    senity_banner_lines=(
        '   ███████╗███████╗███╗   ██╗██╗████████╗██╗   ██╗'
        '   ██╔════╝██╔════╝████╗  ██║██║╚══██╔══╝╚██╗ ██╔╝'
        '   ███████╗█████╗  ██╔██╗ ██║██║   ██║    ╚████╔╝ '
        '   ╚════██║██╔══╝  ██║╚██╗██║██║   ██║     ╚██╔╝  '
        '   ███████║███████╗██║ ╚████║██║   ██║      ██║   ●'
        '   ╚══════╝╚══════╝╚═╝  ╚═══╝╚═╝   ╚═╝      ╚═╝   '
    )

    # RGB-Endpunkte aus dem Theme (Fallback: Senity-Lila #875faf -> Pink #ff00af).
    IFS=';' read -r pr pg pb <<< "${PRIMARY_RGB:-135;95;175}"
    IFS=';' read -r ar ag ab <<< "${ACCENT_RGB:-255;0;175}"
    GLOW="${ESC}[38;2;${ar};${ag};${ab}m"     # Pink (Akzent-Dot)
    NODE_PURP="${ESC}[38;2;${pr};${pg};${pb}m" # Lila (Subtitle)
    R="${ESC}[0m"
    span=$(( ${#senity_banner_lines[@]} - 1 ))

    printf '\n'
    for idx in "${!senity_banner_lines[@]}"; do
        line="${senity_banner_lines[$idx]}"
        r=$(( pr + (ar - pr) * idx / span ))
        g=$(( pg + (ag - pg) * idx / span ))
        b=$(( pb + (ab - pb) * idx / span ))
        line_col="${ESC}[1;38;2;${r};${g};${b}m"
        # Dot inline auf Pink einfaerben, Rest in der Zeilen-Verlaufsfarbe.
        rendered="${line//●/${R}${GLOW}●${R}${line_col}}"
        printf '%s%s%s\n' "$line_col" "$rendered" "$R"
    done
    printf '\n'
    printf '%s   Senity Workspace  --  Senity Code CLI%s\n' "$NODE_PURP" "$R"
    printf '%s   Provider: Senity Chat Proxy%s\n'           "$NODE_PURP" "$R"
    printf '\n'
fi

# ── Initial-User-Nachricht aus INITIAL_PROMPT.md ──
# Der Launcher schreibt den gereinigten INITIAL_PROMPT.md-Inhalt in eine
# Datei innerhalb /workspace und setzt SENITY_INITIAL_PROMPT_FILE. Wir
# lesen den Inhalt hier (Multi-Line in Bash zuverlaessig) und haengen ihn
# als letztes Positional-Argument an, sodass Claude Code ihn als erste
# User-Nachricht erhaelt. Die Datei wird nach dem Lesen geloescht (oneshot).
if [[ -n "${SENITY_INITIAL_PROMPT_FILE:-}" && -f "${SENITY_INITIAL_PROMPT_FILE}" ]]; then
    initial_prompt="$(cat "${SENITY_INITIAL_PROMPT_FILE}")"
    rm -f "${SENITY_INITIAL_PROMPT_FILE}" 2>/dev/null || true
    if [[ -n "${initial_prompt}" ]]; then
        exec -- "$@" "${initial_prompt}"
    fi
fi

exec -- "$@"
