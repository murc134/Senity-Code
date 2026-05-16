#!/bin/bash
set -euo pipefail

# ── Senity Workspace Container Entry Point ──

# Config-Directory existenz pruefen — HOME=/workspace, daher /workspace/.claude
if [[ ! -d "${HOME}/.claude" ]]; then
    mkdir -p "${HOME}/.claude" 2>/dev/null || true
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
# Multi-Color (Logo-Style): weisser Bot + Pink-Brain-Glow + Lila-Akzente
# Skip wenn kein TTY oder SENITY_NO_BANNER gesetzt
if [[ -t 1 && -z "${SENITY_NO_BANNER:-}" ]]; then
    ESC=$'\033'
    FACE="${ESC}[1;38;5;255m"                # weiss bold (Gesicht + SENITY-Text, theme-unabhaengig)
    GLOW="${ESC}[38;5;${ACCENT_256}m"        # Pink-Glow (Brain)
    NODE_PINK="${ESC}[38;5;${ACCENT_256}m"   # Poempel-Variante 1 (ACCENT)
    NODE_PURP="${ESC}[38;5;${PRIMARY_256}m"  # Poempel-Variante 2 (PRIMARY)
    ACC="${ESC}[38;5;${SECONDARY_256}m"      # SECONDARY (Fallback)
    R="${ESC}[0m"

    # Senity Node-Graph Banner: verstreute Knoten (Pink/Lila wechselnd) +
    # Glow-Punkte (.) + Verbindungs-Linien (/, \, -, |),
    # rechts SENITY in @-Block-Schrift (aus Original-Banner exakt uebernommen).
    senity_banner_lines=(
        '                                                                                                         '
        '   #---#                                                                                                 '
        '   |   |          .                                                                                      '
        '   #---#---#                @@@@@@  @@@@@@@@ @@@     @@@ @@@ @@@@@@@@@@@@    @@@                         '
        '            \              @@@@@@@@ @@@@@@@@ @@@@    @@@ @@@ @@@@@@@@@ @@@  @@@                          '
        '             #             @@@@@    @@@      @@@@@@  @@@ @@@    @@@     @@@@@@@                          '
        '            /                @@@@@@@ @@@@@@@  @@@@@@@ @@@ @@@    @@@      @@@@@                          '
        '   #---#---#       .            @@@@ @@@      @@@ @@@@@@@ @@@    @@@      @@@@                           '
        '   |   |                    @@@@@@@@ @@@@@@@@ @@@   @@@@@ @@@    @@@      @@@@                           '
        '   #---#                     @@@@@@@  @@@@@@@@ @@@    @@@@ @@@    @@@       @@@                          '
        '                                                                                                         '
    )

    printf '\n'
    node_cluster=0
    in_node=0
    for line in "${senity_banner_lines[@]}"; do
        out=""
        last=""
        in_node=0
        for (( i=0; i<${#line}; i++ )); do
            c="${line:$i:1}"
            case "$c" in
                '#')
                    if (( in_node == 0 )); then
                        node_cluster=$(( node_cluster + 1 ))
                        in_node=1
                    fi
                    if (( node_cluster % 2 == 1 )); then
                        col="$NODE_PINK"
                    else
                        col="$NODE_PURP"
                    fi
                    ;;
                '*')  col="$GLOW"; in_node=0 ;;
                '@')  col="$FACE"; in_node=0 ;;
                '.')  col="$GLOW"; in_node=0 ;;
                ' ')  col="reset"; in_node=0 ;;
                *)    col="$ACC"; in_node=0 ;;
            esac
            if [[ "$col" != "$last" ]]; then
                if [[ "$col" == "reset" ]]; then
                    out+="$R"
                else
                    out+="$col"
                fi
                last="$col"
            fi
            out+="$c"
        done
        printf '%s%s\n' "$out" "$R"
    done
    printf '\n'
    printf '%s   Senity Workspace  --  Claude Code CLI%s\n' "$FACE" "$R"
    printf '%s   Provider: Senity Chat Proxy%s\n'           "$NODE_PURP" "$R"
    printf '\n'
fi

exec -- "$@"
