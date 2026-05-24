#!/usr/bin/env bash
# Rendert user-guide.html via Chrome / Chromium / Edge headless nach user-guide.pdf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="${1:-$SCRIPT_DIR/user-guide.html}"
OUTPUT="${2:-$SCRIPT_DIR/user-guide.pdf}"

find_browser() {
    for cmd in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge; do
        if command -v "$cmd" >/dev/null 2>&1; then echo "$cmd"; return 0; fi
    done
    # macOS-Pfade
    for app in \
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
        "/Applications/Chromium.app/Contents/MacOS/Chromium" \
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
        [[ -x "$app" ]] && { echo "$app"; return 0; }
    done
    echo ""
    return 1
}

BROWSER="$(find_browser)"
if [[ -z "$BROWSER" ]]; then
    echo "[render-pdf] Kein Chrome / Chromium / Edge gefunden." >&2
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo "[render-pdf] HTML-Quelle fehlt: $INPUT" >&2
    exit 1
fi

ABS_INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
TMP_PROFILE="$(mktemp -d -t senity-pdf-XXXXXX)"
trap 'rm -rf "$TMP_PROFILE"' EXIT

echo "[render-pdf] Browser: $BROWSER"
echo "[render-pdf] Input:   $ABS_INPUT"
echo "[render-pdf] Output:  $OUTPUT"

"$BROWSER" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --no-pdf-header-footer \
    --user-data-dir="$TMP_PROFILE" \
    --print-to-pdf="$OUTPUT" \
    "file://$ABS_INPUT" 2>/dev/null

if [[ ! -f "$OUTPUT" ]]; then
    echo "[render-pdf] PDF wurde nicht erzeugt." >&2
    exit 1
fi

echo "[render-pdf] PDF erzeugt: $OUTPUT ($(du -k "$OUTPUT" | cut -f1) KB)"
