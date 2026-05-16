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
    BOT=$'\033[38;5;255m'      # weiss (Bot-Body)
    GLOW=$'\033[38;5;199m'     # pink/magenta (Brain-Glow)
    TXT=$'\033[1;38;5;255m'    # weiss bold (SENITY-Text)
    ACC=$'\033[38;5;141m'      # helles Lila (Nodes / Dots)
    PURP=$'\033[38;5;99m'      # dunkles Lila (Swirl)
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
    for line in "${senity_banner_lines[@]}"; do
        out=""
        last=""
        for (( i=0; i<${#line}; i++ )); do
            c="${line:$i:1}"
            case "$c" in
                '#')  col="$BOT"  ;;
                '*')  col="$GLOW" ;;
                '@')  if (( i >= 46 )); then col="$TXT"; else col="$PURP"; fi ;;
                '.')  col="$GLOW" ;;
                ' ')  col="reset" ;;
                *)    col="$ACC"  ;;
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
    printf '%s   Senity Workspace  --  Claude Code CLI%s\n' "$TXT" "$R"
    printf '%s   Provider: Senity Chat Proxy%s\n'           "$PURP" "$R"
    printf '\n'
fi

exec -- "$@"
