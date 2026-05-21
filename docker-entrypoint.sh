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
    FACE="${ESC}[1;38;5;255m"                # weiss bold (SENITY Block-Letters)
    GLOW="${ESC}[38;5;${ACCENT_256}m"        # Pink-Glow (~ Brain-Glow)
    BRAIN="${ESC}[38;5;${PRIMARY_256}m"      # Lila (= Brain-Outline)
    NODE_PINK="${ESC}[38;5;${ACCENT_256}m"   # Dot-Cluster Variante 1 (ACCENT)
    NODE_PURP="${ESC}[38;5;${PRIMARY_256}m"  # Dot-Cluster Variante 2 (PRIMARY)
    ACC="${ESC}[38;5;${SECONDARY_256}m"      # SECONDARY (Fallback)
    R="${ESC}[0m"

    # Senity Brain-Logo: links Brain (= Outline, ~ Glow), umringt von verstreuten
    # Dot-Clustern (l-Gruppen mit kleinen I/t/;/,/!/+ Akzenten), rechts SENITY
    # in @-Block-Schrift (◙ aus Original auf @ gemappt — Bash-Byte-Slicing ASCII-safe).
    senity_banner_lines=(
        '                                                 ~~~~~~~~+'
        '                                               ~~~~~~~~~~~~~'
        '                                              ~~~~~~~~~~~~~~'
        '                          ,lllllI             ~~~~~~~~~~~~~~~'
        '                         llllllllll           ~~~~~~~~~~~~~~~  @@@@@@@@@'
        '                        lllllllllllI          ~~~~~~~~~~~~~~   @@@@@@@@@@@@@'
        '                        llllllllllll           ~~~~~~~~~~~~+  @@@@@@@@@@@@@@@@@'
        '                        llllllllllll             ~~~~~~~~~~~~ @@@@@@@@@@@@@@@@@@@'
        '                         llllllllll                     ~~~~~~ @@@@@@@@@@@@@@@@@@@@'
        '      lll                 ,lllllI      =========~=    @@  ~~~~~~@@@@@@@@@@@@@@@@@@@@@'
        '    lllllll                          ~==============  @@@  ~~~~~+ @@@@@@@@@@@@@@@@@@@@'
        '   lllllllll                        ~================  @@@  ~~~~~~ @@@@@@@@@@@@@@@@@@@@'
        '   lllllllll                       ===================  @@@  ~~~~~~ @@@@@@@@@@@@@@@@@@@@'
        '   llllllll,                       ===================  @@@@@  ~~~~~+ @@@@@@@@@@@@@@@@@@@'
        '      lll                          ===================  @@@@@@  ~~~~~~ @@@@@@@@@@@@@@@@@@'
        '                     lllll         ~=================~  @@@@@@@  ~~~~~~~~~~~  @@@@@@@@@@@@'
        '                  llllllllll        =================  @@@@@@@@@@  ~~~~~~~~~~~~ @@@@@@@@@@'
        '                 lllllllllllll       ==============~  @@@@@@@@@@@  +~~~~~~~~~~~~+ @@@@@@@@@'
        '                 lllllllllllll         ~==========  @@@@@@@@@@@@  +~~~~~~~~~~~~~~  @@@@@@@@'
        '                 lllllllllllll         ==== ==       @@@@@@@@@@@  ~~~~~~~~~~~~~~~+ @@@@@@@@'
        '                 lllllllllllll        ~====        ~~~~        ~~~~~~~~~~~~~~~~~~  @@@@@@@@@'
        '                  lllllllllll        !====      ~~~~~~~~~+~~~~~~~~~~~~~~~~~~~~~~~  @@@@@@@@@@@'
        '                    lllllll          ====      ~~~~~~~~~~~~~~~~~~~~+~~~~~~~~~~~~  @@@@@@@@@@@@@'
        '  lllll                         ~~======~      ~~~~~~~~~~~~~~        ~~~~~~~~+   @@@@@@@@@@@@@@@@'
        'llllllllI                     ~==========~     ~~~~~~~~~~~~    @@@@@           @@@@@@@@@@@@@@@@@@@@'
        'lllllllll                    ~=============     ~~~~~~~~~~   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'
        'lllllllll                    ==============      ~~~~~~~+   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@       @@@@@@@@@@      @@@@@@@@@@@@@@@@@  @@@@@@            @@@@@    @@@@@@@  @@@@@@@@@@@@@@@@@@@@@@@@@@         @@@@@@'
        'Illllllll                    ~=============~              @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@     @@@@@@@@@@@@@@@   @@@@@@@@@@@@@@@@@  @@@@@@@           @@@@@    @@@@@@@  @@@@@@@@@@@@@@@@@@@@@@@@@@@       @@@@@@@'
        '  lllll                       =================~     ~=~  @@@@@@@@@@@@   ==~  @@@@@@@@@@@@@@@@@@@@@@     @@@@@@@@@@@@@@@@   @@@@@@@@@@@@@@@@@  @@@@@@@@@         @@@@@    @@@@@@@  @@@@@@@@@@@@@@@@@@@@@@@@@@@      @@@@@@@'
        '                               ===========================~ @@@@@@@@  ~=======~ @@@@@@@@@@@@@@@@@@      @@@@@@@   @@@@@@    @@@@@@             @@@@@@@@@@        @@@@@    @@@@@@@         @@@@@@        @@@@@@@    @@@@@@@'
        '                                 =======    ~~==============~~~~~~~~~~========== @@@@@@@@@@@@@@@@       @@@@@@              @@@@@@             @@@@@@@@@@@       @@@@@    @@@@@@@         @@@@@@         @@@@@@@   @@@@@@'
        '                 llllll                         ~===============================  @@@@@@@@@@@@@@@@      @@@@@@@@            @@@@@@             @@@@@@@@@@@@@     @@@@@    @@@@@@@         @@@@@@          @@@@@@  @@@@@@'
        '               ;llllllll                         ==============================~  @@@@@@@@@@@@@@@@       @@@@@@@@@@@        @@@@@@@@@@@@@@     @@@@@@@@@@@@@@    @@@@@    @@@@@@@         @@@@@@           @@@@@@@@@@@@'
        '               llllllllll                        ~========~           ========~  @@@@@@@@@@@@@@@@@       @@@@@@@@@@@@@@     @@@@@@@@@@@@@@     @@@@@@ @@@@@@@@   @@@@@    @@@@@@@         @@@@@@            @@@@@@@@@@'
        '               tllllllll,                        ~=======   @@@@@@@@   +~~==~+  @@@@@@@@@@@@@@@@@@         @@@@@@@@@@@@@@   @@@@@@@@@@@@@@     @@@@@@   @@@@@@@@ @@@@@    @@@@@@@         @@@@@@             @@@@@@@@@'
        '                lllllllI                        !=====   @@@@@@@@@@@@@@      @@@@@@@@@@@@@@@@@@@                @@@@@@@@@   @@@@@@             @@@@@@    @@@@@@@@@@@@@    @@@@@@@         @@@@@@              @@@@@@@'
        '                                               ;====~  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@                   @@@@@@   @@@@@@             @@@@@@      @@@@@@@@@@@    @@@@@@@         @@@@@@              @@@@@@'
        '                                               ====~  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@         @@@       @@@@@@   @@@@@@             @@@@@@       @@@@@@@@@@    @@@@@@@         @@@@@@              @@@@@@'
        '                                           =======~  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@        @@@@@@@@@@@@@@@@@   @@@@@@@@@@@@@@@@@  @@@@@@        @@@@@@@@@    @@@@@@@         @@@@@@              @@@@@@'
        '                                          =========  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@       @@@@@@@@@@@@@@@@@    @@@@@@@@@@@@@@@@@  @@@@@@          @@@@@@@    @@@@@@@         @@@@@@              @@@@@@'
        '                                         ~=========  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@          @@@@@@@@@@@@@      @@@@@@@@@@@@@@@@@  @@@@@@           @@@@@@    @@@@@@@         @@@@@@              @@@@@@'
        '                        llllllll          =========  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@                   @@@                                                         @@@@@'
        '                       llllllllll          =======  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'
        '                      Illllllllll                  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'
        '                      ;llllllllll                   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'
        '                       Illllllllt      ;lllllll,        @@@@@@@@@@@@@@@@@@@@@@@@@@'
        '                         lllllI       tllllllllll          @@@@@@@@@@@@@@@@@@@@@@'
        '                                      lllllllllll            @@@@@@@@@@@@@@@@@@@'
        '                                      lllllllllll             @@@@@@@@@@@@@@@@@'
        '                                      lllllllllll'
        '                                        lllllll,'
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
                'l'|'I'|'t'|';'|','|'!'|'+')
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
                '=')  col="$BRAIN"; in_node=0 ;;
                '~')  col="$GLOW";  in_node=0 ;;
                '@')  col="$FACE";  in_node=0 ;;
                '.')  col="$GLOW";  in_node=0 ;;
                ' ')  col="reset";  in_node=0 ;;
                *)    col="$ACC";   in_node=0 ;;
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
    printf '%s   Senity Workspace  --  Senity Code CLI%s\n' "$FACE" "$R"
    printf '%s   Provider: Senity Chat Proxy%s\n'           "$NODE_PURP" "$R"
    printf '\n'
fi

# ── Initial-User-Nachricht aus SYSTEM_PROMPT.md ──
# Der Launcher schreibt den gereinigten SYSTEM_PROMPT.md-Inhalt in eine
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
