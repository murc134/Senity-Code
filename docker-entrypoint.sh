#!/bin/bash
set -euo pipefail

# ── Senity Workspace Container Entry Point ──

# Config-Directory existenz pruefen — HOME=/workspace, daher /workspace/.claude
if [[ ! -d "${HOME}/.claude" ]]; then
    mkdir -p "${HOME}/.claude" 2>/dev/null || true
fi

# ── Senity Banner ──
# Multi-Color (Logo-Style): weisser Bot + Pink-Brain-Glow + Lila-Akzente
# Skip wenn kein TTY oder SENITY_NO_BANNER gesetzt
if [[ -t 1 && -z "${SENITY_NO_BANNER:-}" ]]; then
    # ANSI 256-Color Codes (matches Senity logo)
    FACE=$'\033[1;38;5;255m'    # weiss bold (Gesicht + SENITY-Text)
    GLOW=$'\033[38;5;199m'      # pink/magenta (Brain-Glow)
    NODE_PINK=$'\033[38;5;199m' # pink (Pömpel-Variante 1)
    NODE_PURP=$'\033[38;5;99m'  # dunkles Lila (Pömpel-Variante 2)
    ACC=$'\033[38;5;141m'       # helles Lila (Fallback)
    R=$'\033[0m'

    senity_banner_lines=(
        '                      ******                                                                         '
        '            ###     ********@@@@                                                                    '
        '           #####     ****** @@@@@@@@                                                                '
        '           #####   ## ******@@@@@@@@@@                                                              '
        ' ####        #  ********  ***@@@@@@@@@@                                                             '
        ' #####          *********  ****@@@@@@@@@                                                            '
        '         ###    *********    ****#@@@@@@@                                                           '
        '        #####   ********      ******#@@@@                                                           '
        '       #######   ****       .********@@@@@                                                          '
        '        #####   ***  ***************#@@@@@@@                                                        '
        '####         ******  ******@@@@@##@@@@@@@@@@@                                                       '
        '####         *******  ****@@@@@@@@@@@@@@@@@@@@  @@@@@@  @@@@@@@@ @@@     @@@ @@@ @@@@@@@@@@@@    @@@'
        ' ##          *************@@@@@@***@@@@@@@@@@  @@@@@@@@ @@@@@@@@ @@@@    @@@ @@@ @@@@@@@@@ @@@  @@@ '
        '       ####    **    *************** @@@@@@@@  @@@@@    @@@      @@@@@@  @@@ @@@    @@@     @@@@@@@ '
        '       ####           *****@@@@*****@@@@@@@@    @@@@@@@ @@@@@@@  @@@@@@@ @@@ @@@    @@@      @@@@@  '
        '       ####          ***@@@@@@@@@@@@@@@@@@@@       @@@@ @@@      @@@ @@@@@@@ @@@    @@@      @@@@   '
        '                   **** @@@@@@@@@@@@@@@@@@@@   @@@@@@@@ @@@@@@@@ @@@   @@@@@ @@@    @@@      @@@@   '
        '           ###    ***** @@@@@@@@@@@@@@@@@@@    @@@@@@@  @@@@@@@@ @@@    @@@@ @@@    @@@       @@@   '
        '          #####    ****@@@@@@@@@@@@@@@@                                                             '
        '          #####   ####  @@@@@@@@@@@@@                                                               '
        '                 #####     @@@@@@@@@                                                                '
        '                 #####                                                                              '
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
