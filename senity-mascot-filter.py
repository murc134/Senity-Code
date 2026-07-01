#!/usr/bin/env python3
# senity-mascot-filter.py
#
# PTY-Wrapper, der Claude Code als Kindprozess startet und in den ersten
# Sekunden der Ausgabe die Mascot-Zeilen der Welcome-Box bzw. des kompakten
# Start-Headers durch Senity-Branding ersetzt. Nach FILTER_SECONDS wird der Filter deaktiviert, damit normale
# TUI-Nutzung (Box-Edges, Cursor, Inhaltsdarstellung) unbeeintraechtigt
# bleibt.
#
# Heuristik (Zeichen-agnostisch):
#   - Eine Zeile gilt als Mascot-Zeile, wenn sie zwischen zwei vertikalen
#     Box-Edges (U+2502 BOX DRAWINGS LIGHT VERTICAL "|") einen Content-Bereich
#     hat, der zu >= 60 % aus nicht-alphanumerischen, nicht-Whitespace-Chars
#     besteht.
#   - Auch Unicode-Block-Chars (U+2588 etc.) zaehlen als Mascot-Chars und
#     werden durch das Heuristik-Kriterium automatisch erfasst.
#   - Box-Edges (│, ╭, ╮, ╰, ╯, ─) bleiben erhalten, nur der Mascot-Content
#     wird durch Leerzeichen ersetzt.
#
# Begruendung: Anthropic-Maskottchen-Zeichen liegen im claude-Native-Binary
# als V8-Snapshot dedupliziert vor und werden zur Laufzeit komponiert
# (kein zusammenhaengender String) -- statisches Binary-Patching nicht
# moeglich. PTY-Post-Processing ist der pragmatische Weg.

import pty
import os
import sys
import time
import re
import json
import hashlib
import urllib.parse
import fcntl
import struct
import termios
import signal
import select

def _read_theme_file(path: str) -> dict[str, str]:
    values = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                key = key.strip()
                val = val.strip().split("#", 1)[0].strip()
                if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                    val = val[1:-1]
                values[key] = val
    except OSError:
        pass
    return values


THEME_VALUES = _read_theme_file(os.environ.get("SENITY_THEME_FILE", "/etc/senity-theme.conf"))

# ANSI Escape Sequences entfernen, damit unsere Heuristik den realen Text sieht.
# Wir entfernen die Sequenzen nur fuer die Klassifikation; die Daten gehen
# mit Original-ANSI weiter an das Terminal raus.
ANSI_RE = re.compile(rb"\x1b\[[0-9;]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

# Vertikale Box-Edges (UTF-8): U+2502 BOX DRAWINGS LIGHT VERTICAL = 0xE2 0x94 0x82
BOX_V = b"\xe2\x94\x82"  # │

# Welche Chars zaehlen als "harmlos" und sollen nicht gefiltert werden:
# ASCII letters, digits, raume, common punctuation, box-drawing chars.
SAFE_ASCII = set(range(0x20, 0x7F))
# Whitespace
WS = set(b" \t")
# Box-drawing range U+2500..U+257F (UTF-8 lead 0xE2 0x94 oder 0xE2 0x95)
# Wir behandeln das byteweise: jedes Byte 0xE2/0x94/0x95 + Followups = Box.

FILTER_SECONDS = 5.0

# Welcome-Box-Title-Rewrite: "Welcome to Claude Code vX.Y" -> "Senity Code vX.Y"
# Der Title wird im claude-Binary aus getrennten V8-Snapshot-Strings komponiert
# und ist daher nicht statisch byte-patchbar. Wir machen es zur Laufzeit.
# "Senity Wksp" bleibt in der Alternation, damit aeltere gepatchte Builds
# weiterhin idempotent erkannt werden.
TITLE_RE = re.compile(
    r"Welcome to\s+(?:Claude Code|Senity Code|Senity Wksp)\s+v([0-9A-Za-z][0-9A-Za-z.+\- ]*?)\s*$"
)
NEW_PRODUCT = "Senity Code"

# Arc-Box-Title-Rewrite (das ist die tatsaechliche Realitaet im aktuellen Claude
# Code Binary): Top-Border ist `╭─── Claude Code v1.0 ───╮`. Zeilen-Separator
# innerhalb der Box ist `\r\x1b[1B` (CR + cursor-down-1), nicht `\n`, daher
# arbeiten wir auf Chunk-Ebene, nicht zeilenweise.
ARC_TL = b"\xe2\x95\xad"  # ╭ U+256D
ARC_TR = b"\xe2\x95\xae"  # ╮ U+256E
CLAUDE_CODE = b"Claude Code"
SENITY_CODE = b"Senity Code"  # gleiche Byte-/Cell-Breite (11), keine Padding-Korrektur noetig

# Nur "Claude Code" treffen, das ZWISCHEN dem Top-Arc-Paar ╭...╮ liegt
# (Welcome-Box-Titelzeile). Lookahead stellt sicher, dass nach Claude Code
# innerhalb derselben Top-Border ein ╮ folgt, bevor ein weiteres ╮/╭ kommt.
# So bleibt z.B. "Check the Claude Code changelog" im Tipp-Bereich
# (zwischen │...│-Edges, nicht zwischen ╭...╮) unveraendert.
ARC_TITLE_RE = re.compile(
    rb"(\xe2\x95\xad(?:(?!\xe2\x95\xae|\xe2\x95\xad).){0,300}?)Claude Code"
    rb"(?=(?:(?!\xe2\x95\xae|\xe2\x95\xad).){0,500}?\xe2\x95\xae)",
    re.DOTALL,
)

# OSC Window-Title: ESC ] 0 ; <title> BEL  oder  ESC ] 0 ; <title> ESC \
OSC_TITLE_RE = re.compile(
    rb"(\x1b\]0;[^\x07\x1b]*?)Claude Code([^\x07\x1b]*?(?:\x07|\x1b\\))"
)

# Kompakter Claude-Code-Header (ohne Box) nutzt links drei Mascot-Zeilen:
#   " ▐▛███▜▌   Claude Code v..."
#   "▝▜█████▛▘  <model>"
#   "  ▘▘ ▝▝    <cwd>"
# Wir ersetzen nur den linken 11-Zellen-Bereich und behalten den Rest.
COMPACT_MASCOT_WIDTH = 11
COMPACT_MASCOT_GLYPHS = set("▐▛█▜▌▝▘")
COMPACT_CLAUDE_MASCOT = (
    " ▐▛███▜▌   ",
    "▝▜█████▛▘  ",
    "  ▘▘ ▝▝    ",
)

# Senity-Head-Logo als 11x6-Pixel-Konstellation (Ticket #2435), abgeleitet aus
# den Kreis-Koordinaten von "Senity head black.svg" (569x557 -> 11x6 Raster).
# Jede Terminalzelle traegt zwei vertikale Pixel via Halbblock-Trick: bei zwei
# verschiedenfarbigen Pixeln faerbt Foreground die obere Haelfte (Zeichen
# U+2580 OBERE HALBE BLOCKZELLE) und Background die untere. Pixel-Codes:
# b = Blau, p = Pink, v = Violett, Space = leer.
SENITY_HEAD_PIXELS = (
    "   b p     ",
    "b    v     ",
    "b b vp  p  ",
    "  b   v v  ",
    "   b v     ",
    "    b      ",
)

_MASCOT_RGB_RE = re.compile(r"^\d{1,3};\d{1,3};\d{1,3}$")


def _mascot_rgb(key: str, default: str) -> str:
    val = os.environ.get(f"SENITY_{key}") or THEME_VALUES.get(key) or default
    if not _MASCOT_RGB_RE.match(val):
        val = default
    return val


# Markenfarben des Senity-Heads (theme-/env-ueberschreibbar):
# Blau #33378C, Pink #E5007E, Violett #694C99.
MASCOT_PIXEL_COLORS = {
    "b": _mascot_rgb("MASCOT_BLUE_RGB", "51;55;140"),
    "p": _mascot_rgb("MASCOT_PINK_RGB", "229;0;126"),
    "v": _mascot_rgb("MASCOT_PURPLE_RGB", "105;76;153"),
}


def _render_senity_head(pixels):
    """
    Kompiliert die Pixel-Map zu drei vorgefaerbten Terminal-Zeilen mit exakt
    COMPACT_MASCOT_WIDTH sichtbaren Zellen. Jede Zelle traegt ihren eigenen
    SGR-Reset, damit keine Farbe in den nachfolgenden Header-Text blutet.
    """
    lines = []
    for top_row, bot_row in zip(pixels[0::2], pixels[1::2]):
        cells = []
        for top, bot in zip(top_row, bot_row):
            top_rgb = MASCOT_PIXEL_COLORS.get(top)
            bot_rgb = MASCOT_PIXEL_COLORS.get(bot)
            if top_rgb is None and bot_rgb is None:
                cells.append(" ")
            elif bot_rgb is None:
                cells.append(f"\x1b[38;2;{top_rgb}m▀\x1b[0m")
            elif top_rgb is None:
                cells.append(f"\x1b[38;2;{bot_rgb}m▄\x1b[0m")
            elif top_rgb == bot_rgb:
                cells.append(f"\x1b[38;2;{top_rgb}m█\x1b[0m")
            else:
                cells.append(f"\x1b[38;2;{top_rgb};48;2;{bot_rgb}m▀\x1b[0m")
        lines.append("".join(cells))
    return tuple(lines)


# Vorgefaerbte Zeilen (enthalten bereits alle ANSI-Sequenzen und Resets).
COMPACT_SENITY_MASCOT = _render_senity_head(SENITY_HEAD_PIXELS)

# Terminal-Hyperlinks: OSC 8. Der Filter laeuft im Container, das Terminal
# sitzt aber auf dem Host. Deshalb bekommt er vom Launcher eine Mapping-Liste
# Containerpfad -> Hostpfad und verlinkt sichtbare URLs/Dateipfade.
LINKIFY_ENABLED = os.environ.get("SENITY_LINKIFY", "1").lower() not in (
    "0", "false", "no", "off"
)
LINK_RGB = os.environ.get("SENITY_LINK_RGB") or THEME_VALUES.get("LINK_RGB") or "106;155;204"
LINK_COLOR_ENABLED = os.environ.get("SENITY_LINK_COLOR", "1").lower() not in (
    "0", "false", "no", "off"
)
LINK_COLOR_RE = re.compile(r"^\d{1,3};\d{1,3};\d{1,3}$")
if not LINK_COLOR_RE.match(LINK_RGB):
    LINK_RGB = "106;155;204"
LINK_FG = f"\x1b[38;2;{LINK_RGB}m".encode("ascii") if LINK_COLOR_ENABLED else b""
LINK_FG_RESET = b"\x1b[39m" if LINK_COLOR_ENABLED else b""
OSC8_MARKER = b"\x1b]8;"
TERMINAL_ESCAPE_RE = re.compile(
    rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|"
    rb"\x1b\[[0-?]*[ -/]*[@-~]|"
    rb"\x1b[@-Z\\-_]"
)
ANSI_SGR_RE = re.compile(rb"\x1b\[[0-?]*[ -/]*m")
CSI_PRIVATE_MODE_RE = re.compile(rb"^\x1b\[\?([0-9;]*)([hl])$")
MOUSE_MODE_PARAMS = {b"9", b"1000", b"1002", b"1003", b"1005", b"1006", b"1007", b"1015", b"1016"}
ALT_SCREEN_PARAMS = {b"47", b"1047", b"1049"}
LINK_TOKEN = rb"[^\s<>()\[\]{}\"'`:|\x1b]+"
URL_OR_PATH_RE = re.compile(
    rb"(?P<url>(?:https?|ftp)://[^\s<>()\[\]{}\"'`\x1b]+)"
    rb"|(?P<path>"
    rb"(?:/workspace(?:" + rb"/" + LINK_TOKEN + rb")*/?)(?::\d+(?::\d+)?)?"
    rb"|(?:[A-Za-z]:[\\/](?:" + LINK_TOKEN + rb"[\\/])*" + LINK_TOKEN + rb")(?::\d+(?::\d+)?)?"
    rb"|(?:\.{1,2}[\\/](?:" + LINK_TOKEN + rb"[\\/])*" + LINK_TOKEN + rb")(?::\d+(?::\d+)?)?"
    rb"|(?:[A-Za-z0-9_.@+-]+[\\/])+" + LINK_TOKEN + rb"(?::\d+(?::\d+)?)?"
    rb"|(?:[A-Za-z0-9_.@+-]+[\\/])(?::\d+(?::\d+)?)?"
    rb"|(?:[A-Za-z0-9_.@+-]+\.[A-Za-z][A-Za-z0-9_+-]{0,11}|\.[A-Za-z0-9_-]{2,})(?::\d+(?::\d+)?)?"
    rb")"
)
LOCATION_RE = re.compile(r"^(?P<path>.+?)(?::(?P<line>\d+)(?::(?P<col>\d+))?)?$")
WINDOWS_ABS_RE = re.compile(r"^[A-Za-z]:[\\/]")
TRAILING_PUNCT = b".,;!?:"
_PATH_MAPS = None
_RECENT_CONTAINER_DIRS: list[str] = []
MAX_RECENT_CONTAINER_DIRS = 32
IN_FULLSCREEN_TUI = False


def _strip_mouse_reporting_enabled() -> bool:
    value = os.environ.get("SENITY_STRIP_MOUSE_REPORTING", "auto").lower()
    if value in ("1", "true", "yes", "on"):
        return True
    if value in ("0", "false", "no", "off"):
        return False
    host_term = os.environ.get("SENITY_HOST_TERM_PROGRAM") or os.environ.get("TERM_PROGRAM", "")
    return "warp" in host_term.lower()


STRIP_MOUSE_REPORTING = _strip_mouse_reporting_enabled()


def _linkify_in_tui_enabled() -> bool:
    value = os.environ.get("SENITY_LINKIFY_IN_TUI", "0").lower()
    return value in ("1", "true", "yes", "on")


LINKIFY_IN_TUI = _linkify_in_tui_enabled()


def _visible_host_paths_mode() -> str:
    value = os.environ.get("SENITY_VISIBLE_HOST_PATHS", "auto").lower()
    if value in ("1", "true", "yes", "on"):
        return "all"
    if value in ("0", "false", "no", "off"):
        return "off"
    if value in ("safe", "layout", "conservative"):
        return "safe"
    host_term = os.environ.get("SENITY_HOST_TERM_PROGRAM") or os.environ.get("TERM_PROGRAM", "")
    return "safe" if "warp" in host_term.lower() else "off"


VISIBLE_HOST_PATHS_MODE = _visible_host_paths_mode()
VISIBLE_HOST_PATHS = VISIBLE_HOST_PATHS_MODE != "off"


def _is_windows_abs(path_text: str) -> bool:
    return bool(WINDOWS_ABS_RE.match(path_text)) or path_text.startswith("\\\\")


def _add_path_map(maps, container_path, host_path):
    if not container_path or not host_path:
        return
    container_path = container_path.rstrip("/") or "/"
    if not container_path.startswith("/"):
        return
    pair = (container_path, host_path)
    if pair not in maps:
        maps.append(pair)


def _load_path_maps():
    global _PATH_MAPS
    if _PATH_MAPS is not None:
        return _PATH_MAPS
    maps = []
    raw = os.environ.get("SENITY_LINK_PATH_MAP", "").strip()
    if raw:
        try:
            data = json.loads(raw)
            if isinstance(data, list):
                for item in data:
                    if not isinstance(item, dict):
                        continue
                    _add_path_map(maps, item.get("container"), item.get("host"))
        except Exception:
            pass
    _add_path_map(maps, "/workspace/.claude", os.environ.get("SENITY_HOST_CLAUDE_DIR"))
    _add_path_map(maps, "/workspace", os.environ.get("SENITY_HOST_WORKSPACE"))
    maps.sort(key=lambda item: len(item[0]), reverse=True)
    _PATH_MAPS = maps
    return maps


def _host_join(base: str, rel: str) -> str:
    if not rel:
        return base
    if _is_windows_abs(base):
        return base.rstrip("\\/") + "\\" + rel.replace("/", "\\")
    return base.rstrip("/") + "/" + rel


def _container_to_host_path(container_path: str) -> str:
    container_path = os.path.normpath(container_path).replace("\\", "/")
    for container_base, host_base in _load_path_maps():
        base = container_base.rstrip("/") or "/"
        if container_path == base or container_path.startswith(base + "/"):
            rel = container_path[len(base):].lstrip("/")
            return _host_join(host_base, rel)
    return container_path


def _host_to_container_path(host_path: str):
    for container_base, host_base in _load_path_maps():
        if _is_windows_abs(host_base) or host_base.startswith("\\\\"):
            host_norm = host_path.replace("/", "\\").rstrip("\\/")
            base_norm = host_base.replace("/", "\\").rstrip("\\/")
            host_cmp = host_norm.casefold()
            base_cmp = base_norm.casefold()
            sep = "\\"
        else:
            host_norm = host_path.replace("\\", "/").rstrip("/")
            base_norm = host_base.replace("\\", "/").rstrip("/")
            host_cmp = host_norm
            base_cmp = base_norm
            sep = "/"
        if host_cmp == base_cmp or host_cmp.startswith(base_cmp + sep):
            rel = host_norm[len(base_norm):].lstrip("\\/")
            return os.path.normpath(container_base.rstrip("/") + "/" + rel.replace("\\", "/")).replace("\\", "/")
    return None


def _container_path_kind(container_path: str) -> str:
    try:
        if os.path.isdir(container_path):
            return "dir"
        if os.path.lexists(container_path):
            return "file"
    except OSError:
        pass
    return "unknown"


def _remember_container_dir(container_dir: str):
    container_dir = os.path.normpath(container_dir).replace("\\", "/")
    if not container_dir.startswith("/"):
        return
    candidates = [container_dir]
    parent = os.path.dirname(container_dir.rstrip("/"))
    if parent and parent != container_dir:
        candidates.append(parent)
    for candidate in candidates:
        if candidate in _RECENT_CONTAINER_DIRS:
            _RECENT_CONTAINER_DIRS.remove(candidate)
        _RECENT_CONTAINER_DIRS.insert(0, candidate)
    del _RECENT_CONTAINER_DIRS[MAX_RECENT_CONTAINER_DIRS:]


def _remember_container_path(container_path: str, kind: str | None = None):
    kind = kind or _container_path_kind(container_path)
    if kind == "dir":
        _remember_container_dir(container_path)
    elif kind == "file":
        _remember_container_dir(os.path.dirname(container_path))


def _recent_search_roots():
    roots = []
    for root in _RECENT_CONTAINER_DIRS:
        try:
            if os.path.isdir(root) and root not in roots:
                roots.append(root)
        except OSError:
            continue
    return roots


def _relative_search_roots(path_text: str = ""):
    roots = []

    def add(root):
        root = os.path.normpath(root).replace("\\", "/")
        if root not in roots:
            roots.append(root)

    prefer_recent = path_text.startswith(("./", "../", ".\\", "..\\")) or "/" in path_text or "\\" in path_text
    if prefer_recent:
        for root in _recent_search_roots():
            add(root)
    add(os.getcwd())
    add("/workspace")
    try:
        for name in os.listdir("/workspace/projects"):
            candidate = os.path.join("/workspace/projects", name)
            if os.path.isdir(candidate):
                add(candidate)
    except OSError:
        pass
    for container_base, _host_base in _load_path_maps():
        if not container_base.startswith("/workspace/projects/"):
            continue
        try:
            if os.path.isdir(container_base):
                add(container_base)
        except OSError:
            continue
    if not prefer_recent:
        for root in _recent_search_roots():
            add(root)
    return roots


def _file_uri(host_path: str) -> str:
    if host_path.startswith("\\\\"):
        unc = host_path.lstrip("\\").replace("\\", "/")
        return "file://" + urllib.parse.quote(unc, safe="/:")
    if _is_windows_abs(host_path):
        path_part = host_path.replace("\\", "/")
        return "file:///" + urllib.parse.quote(path_part, safe="/:")
    path_part = host_path.replace("\\", "/")
    if not path_part.startswith("/"):
        path_part = os.path.abspath(path_part)
    return "file://" + urllib.parse.quote(path_part, safe="/:")


def _editor_uri(host_path: str, line: str | None = None, col: str | None = None) -> str:
    fmt = os.environ.get("SENITY_FILE_LINK_FORMAT", "file").strip().lower()
    if fmt not in ("vscode", "vscode-insiders", "vscodium", "cursor", "windsurf"):
        return _file_uri(host_path)
    path_part = host_path.replace("\\", "/")
    if path_part.startswith("//"):
        path_part = path_part.lstrip("/")
    suffix = ""
    if line:
        suffix = f":{line}"
        if col:
            suffix += f":{col}"
    return f"{fmt}://file/" + urllib.parse.quote(path_part, safe="/:") + suffix


def _visible_host_label(host_path: str, original_path: str, line: str | None, col: str | None) -> bytes:
    label = host_path
    if original_path.endswith(("/", "\\")) and not label.endswith(("/", "\\")):
        label += "\\" if _is_windows_abs(label) else "/"
    if line:
        label += f":{line}"
        if col:
            label += f":{col}"
    return label.encode("utf-8", "replace")


def _visible_path_label(host_path: str, original_path: str, line: str | None, col: str | None, kind: str, uri: str) -> bytes:
    if kind == "file":
        return uri.encode("ascii", "ignore")
    return _visible_host_label(host_path, original_path, line, col)


def _line_for_match(visible: bytes, start: int, end: int) -> bytes:
    line_start = visible.rfind(b"\n", 0, start) + 1
    line_end = visible.find(b"\n", end)
    if line_end == -1:
        line_end = len(visible)
    return visible[line_start:line_end]


def _line_looks_like_table(line: bytes) -> bool:
    text = line.decode("utf-8", "ignore")
    if any(ch in text for ch in "┌┬┐└┴┘┼╞╪╡╤╧╒╓╔╗╚╝╠╣╦╩╬"):
        return True
    if text.count("|") >= 2:
        return True
    if text.count("│") >= 2 and "├" not in text and "└" not in text:
        return True
    return False


def _allow_visible_path_override(visible: bytes, start: int, end: int) -> bool:
    if VISIBLE_HOST_PATHS_MODE == "all":
        return True
    if VISIBLE_HOST_PATHS_MODE != "safe":
        return False
    return not _line_looks_like_table(_line_for_match(visible, start, end))


def _split_location(path_text: str):
    m = LOCATION_RE.match(path_text)
    if not m:
        return path_text, None, None
    return m.group("path"), m.group("line"), m.group("col")


def _resolve_container_path(path_text: str):
    path_text = path_text.replace("\\", "/")
    candidates = []
    if path_text.startswith("/"):
        candidates.append(os.path.normpath(path_text))
    else:
        for root in _relative_search_roots(path_text):
            candidate = os.path.normpath(os.path.join(root, path_text))
            if candidate not in candidates:
                candidates.append(candidate)
    for candidate in candidates:
        try:
            if os.path.lexists(candidate):
                return candidate
        except OSError:
            continue
    return None


def _path_target_for(raw: bytes, visible_override: bool = True):
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    path_text, _line, _col = _split_location(text)
    if _is_windows_abs(path_text):
        uri = _editor_uri(path_text, _line, _col)
        container_path = _host_to_container_path(path_text)
        kind = _container_path_kind(container_path) if container_path else "unknown"
        if container_path:
            _remember_container_path(container_path, kind)
        use_visible = VISIBLE_HOST_PATHS and visible_override
        label = _visible_path_label(path_text, path_text, _line, _col, kind, uri) if use_visible else None
        return uri, label, not use_visible
    container_path = _resolve_container_path(path_text)
    if not container_path:
        return None
    kind = _container_path_kind(container_path)
    _remember_container_path(container_path, kind)
    host_path = _container_to_host_path(container_path)
    uri = _editor_uri(host_path, _line, _col)
    use_visible = VISIBLE_HOST_PATHS and visible_override
    label = _visible_path_label(host_path, path_text, _line, _col, kind, uri) if use_visible else None
    return uri, label, not use_visible


def _trim_trailing(raw: bytes):
    end = len(raw)
    while end > 0 and raw[end - 1:end] in TRAILING_PUNCT:
        end -= 1
    return raw[:end], raw[end:]


def _osc8(uri: str, label: bytes) -> bytes:
    uri_bytes = uri.encode("ascii", "ignore")
    link_id = hashlib.sha256(uri_bytes).hexdigest()[:16].encode("ascii")
    if LINK_FG and b"\x1b" not in label:
        label = LINK_FG + label + LINK_FG_RESET
    return b"\x1b]8;id=senity-" + link_id + b";" + uri_bytes + b"\x1b\\" + label + b"\x1b]8;;\x1b\\"


def _osc8_uri_part(seq: bytes):
    if not seq.startswith(OSC8_MARKER):
        return None
    if seq.endswith(b"\x1b\\"):
        body = seq[len(OSC8_MARKER):-2]
    elif seq.endswith(b"\x07"):
        body = seq[len(OSC8_MARKER):-1]
    else:
        return None
    _params, sep, uri = body.partition(b";")
    if not sep:
        return None
    return uri


def _filter_terminal_escape(seq: bytes) -> bytes:
    global IN_FULLSCREEN_TUI
    m = CSI_PRIVATE_MODE_RE.match(seq)
    if m:
        params = [p for p in m.group(1).split(b";") if p]
        if any(p in ALT_SCREEN_PARAMS for p in params):
            IN_FULLSCREEN_TUI = m.group(2) == b"h"
    if not STRIP_MOUSE_REPORTING:
        return seq
    if not m or m.group(2) != b"h":
        return seq
    if not any(p in MOUSE_MODE_PARAMS for p in params):
        return seq
    kept = [p for p in params if p not in MOUSE_MODE_PARAMS]
    if not kept:
        return b""
    return b"\x1b[?" + b";".join(kept) + b"h"


def _linkify_visible_bytes(raw_run: bytes, visible: bytes, visible_to_raw: list[int]) -> bytes:
    out = bytearray()
    raw_pos = 0
    for m in URL_OR_PATH_RE.finditer(visible):
        raw_start = visible_to_raw[m.start()]
        raw_end = visible_to_raw[m.end() - 1] + 1
        out.extend(raw_run[raw_pos:raw_start])

        visible_match = m.group(0)
        core, _suffix = _trim_trailing(visible_match)
        if not core:
            out.extend(raw_run[raw_start:raw_end])
        elif m.group("url"):
            try:
                uri = core.decode("utf-8")
                core_raw_end = visible_to_raw[m.start() + len(core) - 1] + 1
                out.extend(_osc8(uri, raw_run[raw_start:core_raw_end]))
                out.extend(raw_run[core_raw_end:raw_end])
            except UnicodeDecodeError:
                out.extend(raw_run[raw_start:raw_end])
        else:
            visible_override = _allow_visible_path_override(visible, m.start(), m.start() + len(core))
            target = _path_target_for(core, visible_override)
            if target:
                uri, label_override, wrap = target
                core_raw_end = visible_to_raw[m.start() + len(core) - 1] + 1
                label = label_override if label_override is not None else raw_run[raw_start:core_raw_end]
                if wrap:
                    out.extend(_osc8(uri, label))
                else:
                    out.extend(label)
                out.extend(raw_run[core_raw_end:raw_end])
            else:
                out.extend(raw_run[raw_start:raw_end])
        raw_pos = raw_end
    out.extend(raw_run[raw_pos:])
    return bytes(out)


def _linkify_ansi_run(run: bytes) -> bytes:
    if not run:
        return run
    visible = bytearray()
    visible_to_raw = []
    pos = 0
    for esc in TERMINAL_ESCAPE_RE.finditer(run):
        if esc.start() > pos:
            segment = run[pos:esc.start()]
            visible.extend(segment)
            visible_to_raw.extend(range(pos, esc.start()))
        pos = esc.end()
    if pos < len(run):
        segment = run[pos:]
        visible.extend(segment)
        visible_to_raw.extend(range(pos, len(run)))
    if not visible:
        return run
    return _linkify_visible_bytes(run, bytes(visible), visible_to_raw)


def _should_linkify_text() -> bool:
    return LINKIFY_IN_TUI or not IN_FULLSCREEN_TUI


def _flush_linkify_run(out: bytearray, run: bytearray):
    if run:
        out.extend(_linkify_ansi_run(bytes(run)))
        run.clear()


def linkify_chunk(chunk: bytes) -> bytes:
    if not LINKIFY_ENABLED or not chunk:
        return chunk
    out = bytearray()
    run = bytearray()
    pos = 0
    in_existing_link = False
    for esc in TERMINAL_ESCAPE_RE.finditer(chunk):
        if esc.start() > pos:
            text_segment = chunk[pos:esc.start()]
            if in_existing_link:
                out.extend(text_segment)
            elif _should_linkify_text():
                run.extend(text_segment)
            else:
                out.extend(text_segment)
        seq = esc.group(0)
        existing_uri = _osc8_uri_part(seq)
        if existing_uri is not None:
            _flush_linkify_run(out, run)
            out.extend(seq)
            in_existing_link = bool(existing_uri)
        elif in_existing_link:
            out.extend(seq)
        elif ANSI_SGR_RE.fullmatch(seq):
            if _should_linkify_text():
                run.extend(seq)
            else:
                out.extend(seq)
        else:
            _flush_linkify_run(out, run)
            out.extend(_filter_terminal_escape(seq))
        pos = esc.end()
    if pos < len(chunk):
        text_segment = chunk[pos:]
        if in_existing_link:
            out.extend(text_segment)
        elif _should_linkify_text():
            run.extend(text_segment)
        else:
            out.extend(text_segment)
    _flush_linkify_run(out, run)
    return bytes(out)


def rewrite_titles_in_chunk(chunk: bytes) -> bytes:
    """
    Ersetzt "Claude Code" -> "Senity Code" in zwei eng definierten Kontexten:
      1. Welcome-Box-Top-Border (Bereich zwischen ╭ und ╮)
      2. OSC-Window-Title (ESC ] 0 ; ... BEL)
    Andere Vorkommen ("Claude Code'll be able..." im Trust-Dialog, "Check the
    Claude Code changelog" im Tipp-Bereich der Welcome-Box) bleiben erhalten.
    """
    if ARC_TL in chunk and CLAUDE_CODE in chunk:
        chunk = ARC_TITLE_RE.sub(lambda m: m.group(1) + SENITY_CODE, chunk)
    if b"\x1b]0;" in chunk:
        chunk = OSC_TITLE_RE.sub(
            lambda m: m.group(1) + SENITY_CODE + m.group(2), chunk
        )
    if COMPACT_CLAUDE_MASCOT[0].encode("utf-8") in chunk:
        # COMPACT_SENITY_MASCOT-Zeilen sind bereits vorgefaerbt (inkl. Resets).
        for old, new in zip(COMPACT_CLAUDE_MASCOT, COMPACT_SENITY_MASCOT):
            chunk = chunk.replace(old.encode("utf-8"), new.encode("utf-8"), 1)
        chunk = chunk.replace(CLAUDE_CODE, SENITY_CODE, 1)
    return chunk

_state = {
    "start": None,
    "off": False,
    "buf": b"",  # Zeilen-Buffer
    "compact_mascot_next": None,
}


def is_mascot_line(stripped: bytes) -> bool:
    """
    Entscheidet anhand einer einzelnen Welcome-Box-Innen-Zeile (ohne Box-Edges)
    ob sie als Mascot-Zeile gilt.
    """
    if len(stripped) < 4:
        return False
    # Nur die druckbaren Bytes zaehlen
    printable = bytes(b for b in stripped if b not in WS)
    if len(printable) < 3:
        return False
    # ASCII-Anteil: A-Za-z0-9
    alnum = sum(1 for b in printable if (0x30 <= b <= 0x39) or (0x41 <= b <= 0x5A) or (0x61 <= b <= 0x7A))
    alnum_ratio = alnum / len(printable)
    return alnum_ratio < 0.30


def strip_ansi(raw: bytes) -> bytes:
    return ANSI_RE.sub(b"", raw)


def try_rewrite_title(raw_line: bytes):
    """
    Wenn raw_line die Welcome-Box-Title-Zeile ist, ersetze den Inhalt zwischen
    den Box-Edges durch "<star> Senity Code v<version>" und behalte die
    sichtbare Innenbreite. Liefert die neue Zeile zurueck oder None bei No-Match.
    """
    raw_first = raw_line.find(BOX_V)
    raw_last = raw_line.rfind(BOX_V)
    if raw_first == -1 or raw_last == -1 or raw_last <= raw_first:
        return None
    plain = strip_ansi(raw_line)
    p_first = plain.find(BOX_V)
    p_last = plain.rfind(BOX_V)
    if p_first == -1 or p_last == -1 or p_last <= p_first:
        return None
    inner_plain = plain[p_first + len(BOX_V):p_last]
    try:
        inner_str = inner_plain.decode("utf-8", "replace")
    except Exception:
        return None
    if "Welcome to" not in inner_str:
        return None
    m = TITLE_RE.search(inner_str.strip())
    if not m:
        return None
    version = m.group(1).strip()
    star = "✻"  # ✻
    has_star = star in inner_str
    core = f"{star} {NEW_PRODUCT} v{version}" if has_star else f"{NEW_PRODUCT} v{version}"
    # Innen-Layout: 1 Leerspalte vorne, dann core, dann padding bis alte Breite
    old_width = len(inner_str)  # Codepoints == cells (ASCII + ✻ sind je 1 cell)
    new_inner = " " + core
    if len(new_inner) > old_width:
        new_inner = new_inner[:old_width]
    else:
        new_inner = new_inner + " " * (old_width - len(new_inner))
    head = raw_line[:raw_first + len(BOX_V)]
    tail = raw_line[raw_last:]
    return head + new_inner.encode("utf-8") + tail


def _split_line_ending(raw_line: bytes):
    for ending in (b"\r\n", b"\n", b"\r"):
        if raw_line.endswith(ending):
            return raw_line[:-len(ending)], ending
    return raw_line, b""


def _looks_like_compact_mascot_prefix(plain: str) -> bool:
    prefix = plain[:COMPACT_MASCOT_WIDTH + 3]
    return any(ch in COMPACT_MASCOT_GLYPHS for ch in prefix)


def try_rewrite_compact_mascot(raw_line: bytes):
    """
    Ersetzt den kompakten dreizeiligen Claude-Mascot-Header links durch ein
    kleines Senity-Mascot. Der restliche Text (Version, Modell, Pfad) bleibt.
    """
    body, ending = _split_line_ending(raw_line)
    if not body:
        return None
    plain = strip_ansi(body).decode("utf-8", "replace")

    line_idx = None
    if "Claude Code v" in plain and _looks_like_compact_mascot_prefix(plain):
        line_idx = 0
        _state["compact_mascot_next"] = 1
    elif _state.get("compact_mascot_next") in (1, 2):
        next_idx = _state["compact_mascot_next"]
        if not _looks_like_compact_mascot_prefix(plain):
            _state["compact_mascot_next"] = None
            return None
        line_idx = next_idx
        _state["compact_mascot_next"] = next_idx + 1 if next_idx < 2 else None
    else:
        return None

    rest = plain[COMPACT_MASCOT_WIDTH:] if len(plain) >= COMPACT_MASCOT_WIDTH else ""
    if line_idx == 0:
        rest = rest.replace("Claude Code", NEW_PRODUCT, 1)
    # Vorgefaerbte Mascot-Zeile (inkl. eigener SGR-Resets) plus Resttext.
    rendered = f"{COMPACT_SENITY_MASCOT[line_idx]}{rest}"
    return rendered.encode("utf-8") + ending


def filter_line(raw_line: bytes) -> bytes:
    """
    Akzeptiert eine vollstaendige Zeile inklusive ANSI-Sequenzen.
    Wenn die Zeile als Mascot-Zeile erkannt wird, ersetzen wir den
    Content zwischen den ersten und letzten Box-V-Edges durch Spaces.
    Sonst Zeile unveraendert zurueck.
    """
    rewritten = try_rewrite_compact_mascot(raw_line)
    if rewritten is not None:
        return rewritten
    rewritten = try_rewrite_title(raw_line)
    if rewritten is not None:
        return rewritten
    plain = strip_ansi(raw_line)
    # Box-Edges suchen
    first = plain.find(BOX_V)
    last = plain.rfind(BOX_V)
    if first == -1 or last == -1 or last <= first + len(BOX_V):
        return raw_line
    inner = plain[first + len(BOX_V):last]
    if not is_mascot_line(inner):
        return raw_line
    # Original-Zeile rekonstruieren: behalte Box-Edges, ersetze
    # alle nicht-Whitespace, nicht-BoxDrawing Bytes durch Leerzeichen.
    # Wir bauen Byte-fuer-Byte ueber raw_line, ueberspringen ANSI-Sequenzen.
    out = bytearray()
    i = 0
    in_box = False
    boxdrawing_first_seen = False
    boxdrawing_last_pos = None
    # Vereinfachte Strategie: parsing entlang raw_line; im Bereich
    # zwischen erstem und letztem BOX_V alles Nicht-Whitespace-NonBox
    # zu Space machen. ANSI bleibt erhalten.
    n = len(raw_line)
    # Vorher Box-V-Positionen im RAW-String finden (per Sub-Search):
    raw_first = raw_line.find(BOX_V)
    raw_last = raw_line.rfind(BOX_V)
    if raw_first == -1 or raw_last == -1 or raw_last <= raw_first:
        return raw_line

    # Inside-Bereich neutralisieren
    head = raw_line[:raw_first + len(BOX_V)]
    inside = raw_line[raw_first + len(BOX_V):raw_last]
    tail = raw_line[raw_last:]

    # In inside ANSI-Sequenzen behalten, druckbare Bytes -> Space
    inside_new = bytearray()
    i = 0
    while i < len(inside):
        b = inside[i]
        # ANSI-CSI / OSC erkennen
        if b == 0x1b:  # ESC
            # Sequenz konservieren
            m = ANSI_RE.match(inside, i)
            if m:
                inside_new.extend(m.group(0))
                i = m.end()
                continue
        # Whitespace/CR/LF unveraendert lassen
        if b in (0x09, 0x0a, 0x0d, 0x20):
            inside_new.append(b)
            i += 1
            continue
        # Multi-byte UTF-8 char ueberspringen (kann Box-Drawing sein)
        if b >= 0xC0:
            # bestimme Laenge
            if b >= 0xF0:
                clen = 4
            elif b >= 0xE0:
                clen = 3
            else:
                clen = 2
            chunk = inside[i:i+clen]
            # U+2500..U+257F (Box Drawings)
            is_box = (clen == 3 and chunk[0] == 0xE2 and chunk[1] in (0x94, 0x95))
            if is_box:
                inside_new.extend(chunk)
            else:
                inside_new.extend(b" " * clen)
            i += clen
            continue
        # Sonstiges druckbares Byte -> Space
        inside_new.append(0x20)
        i += 1

    return bytes(head) + bytes(inside_new) + bytes(tail)


def process_chunk(data: bytes) -> bytes:
    """
    Zeilenweise Verarbeitung. Letzte unvollstaendige Zeile wird im _state['buf']
    gepuffert, damit wir nicht mitten in einer Zeile filtern.
    """
    out = bytearray()
    buf = _state["buf"] + data
    # Split auf \n, behalte Trenner zurueck
    while True:
        nl = buf.find(b"\n")
        if nl == -1:
            break
        line = buf[:nl + 1]
        out.extend(filter_line(line))
        buf = buf[nl + 1:]
    _state["buf"] = buf
    return bytes(out)


def flush_buffer() -> bytes:
    if _state["buf"]:
        out = filter_line(_state["buf"])
        _state["buf"] = b""
        return out
    return b""


def master_read(fd):
    data = os.read(fd, 8192)
    if _state["off"]:
        return linkify_chunk(data)
    if _state["start"] is None:
        _state["start"] = time.monotonic()
    if time.monotonic() - _state["start"] > FILTER_SECONDS:
        _state["off"] = True
        # Pufferrest noch filtern, dann durchreichen
        flushed = flush_buffer()
        return flushed + data
    # Chunk-Level: Arc-Title + OSC-Title rewrite (vor dem Line-Buffering, weil
    # die Welcome-Box \r\x1b[1B als Zeilenseparator benutzt, nicht \n).
    data = rewrite_titles_in_chunk(data)
    return linkify_chunk(process_chunk(data))


def stdin_read(fd):
    return os.read(fd, 8192)


def _get_winsize(fd):
    """Liefere (rows, cols) des angegebenen TTY-fd, oder Fallback 24x80."""
    try:
        s = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\x00" * 8)
        rows, cols, _, _ = struct.unpack("HHHH", s)
        if rows and cols:
            return rows, cols
    except Exception:
        pass
    return 24, 80


def _set_winsize(fd, rows, cols):
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except Exception:
        pass


def _set_raw(fd):
    """
    Setze ein TTY-fd in den Raw-Mode (kein ICRNL, kein ICANON, kein ECHO, ...).
    Liefert die alten termios-Attribute zurueck, damit wir sie spaeter
    wiederherstellen koennen. Bei nicht-TTY-fd: None zurueck.
    """
    try:
        old = termios.tcgetattr(fd)
    except termios.error:
        return None
    new = list(old)
    # new = [iflag, oflag, cflag, lflag, ispeed, ospeed, cc]
    new[0] &= ~(termios.IGNBRK | termios.BRKINT | termios.PARMRK | termios.ISTRIP
                | termios.INLCR | termios.IGNCR | termios.ICRNL | termios.IXON)
    new[1] &= ~termios.OPOST
    new[3] &= ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG | termios.IEXTEN)
    new[2] &= ~(termios.CSIZE | termios.PARENB)
    new[2] |= termios.CS8
    try:
        termios.tcsetattr(fd, termios.TCSANOW, new)
    except termios.error:
        return None
    return old


def _restore_termios(fd, old):
    if old is None:
        return
    try:
        termios.tcsetattr(fd, termios.TCSANOW, old)
    except Exception:
        pass


def _spawn_filtered(argv):
    """
    Eigener pty.spawn-Ersatz: erbt die Window-Size vom STDIN-TTY auf das neue
    inner-pty, damit Claude Code seine TUI mit korrekter Geometrie rendert.
    Sonst ist die default-Groesse 0x0 und Claude rendert nichts.
    Zusaetzlich Propagation von SIGWINCH und sauberer EOF/EXIT-Loop.
    """
    # Winsize vom aktuellen stdin (= aeusserer pty-slave) holen, bevor wir
    # forken. Damit hat das innere pty fuer claude eine sinnvolle Geometrie.
    parent_rows, parent_cols = _get_winsize(sys.stdin.fileno())

    pid, master_fd = pty.fork()
    if pid == 0:
        # Child: winsize auf eigene stdin (inner slave) setzen, dann exec
        _set_winsize(sys.stdin.fileno(), parent_rows, parent_cols)
        try:
            os.execvp(argv[0], argv)
        except OSError as e:
            sys.stderr.write(f"execvp failed: {e}\n")
            os._exit(127)

    # SIGWINCH durchreichen: wenn Host-Terminal die Groesse aendert,
    # reichen wir das ans innere pty weiter.
    def _on_winch(_sig, _frm):
        r, c = _get_winsize(sys.stdin.fileno())
        _set_winsize(master_fd, r, c)
    try:
        signal.signal(signal.SIGWINCH, _on_winch)
    except Exception:
        pass

    # SIGTERM/SIGINT an Child weiterleiten (PID 1 im Container).
    # Ohne dies sendet Docker SIGTERM an uns, aber claude bekommt nichts
    # und wird nach 10s hart per SIGKILL getoetet.
    def _forward_signal(sig, _frame):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass
    for _sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(_sig, _forward_signal)
        except Exception:
            pass

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()
    # Raw-Mode auf den OUTER-Slave (= unser stdin) setzen. Sonst wandelt die
    # Line-Discipline eingehendes \r in \n um (ICRNL); claude im TUI-Raw-Mode
    # erwartet aber \r als Enter und ignoriert \n. Ohne Raw passt der Trust-
    # Dialog nicht und der ganze TUI-Input ist subtil kaputt.
    old_termios = _set_raw(stdin_fd)
    _dbg = os.environ.get("SENITY_FILTER_DEBUG") == "1"
    if _dbg:
        sys.stderr.write(f"[filter] stdin_fd={stdin_fd} stdout_fd={stdout_fd} master_fd={master_fd} winsize={parent_rows}x{parent_cols} raw={old_termios is not None}\n")
        sys.stderr.flush()
    fds = [master_fd, stdin_fd]
    try:
        while True:
            try:
                r, _, _ = select.select(fds, [], [], 0.2)
            except (OSError, ValueError):
                break
            if master_fd in r:
                try:
                    chunk = os.read(master_fd, 8192)
                except OSError:
                    chunk = b""
                if not chunk:
                    break
                out = master_read(master_fd) if False else None
                # master_read erwartet selbst os.read; wir muessen die Logik
                # umkehren, weil wir hier schon gelesen haben. Daher direkt
                # rewrite_titles_in_chunk + process_chunk anwenden.
                if _state["off"]:
                    try:
                        os.write(stdout_fd, linkify_chunk(chunk))
                    except OSError:
                        break
                else:
                    if _state["start"] is None:
                        _state["start"] = time.monotonic()
                    if time.monotonic() - _state["start"] > FILTER_SECONDS:
                        _state["off"] = True
                        try:
                            os.write(stdout_fd, linkify_chunk(chunk))
                        except OSError:
                            break
                    else:
                        # Chunk direkt durchreichen, nach Titel-Rewrite.
                        # KEIN Line-Buffering, weil Claude die Welcome-Box
                        # mit \r\x1b[1B (CR + cursor-down-1) als Zeilen-
                        # separator rendert, nicht mit \n. Line-Buffering
                        # wuerde alles bis FILTER_SECONDS zurueckhalten.
                        chunk2 = rewrite_titles_in_chunk(chunk)
                        try:
                            os.write(stdout_fd, linkify_chunk(chunk2))
                        except OSError:
                            break
            if stdin_fd in r:
                try:
                    data = os.read(stdin_fd, 8192)
                except OSError:
                    data = b""
                if _dbg:
                    sys.stderr.write(f"[filter] stdin {len(data)}b: {data!r}\n")
                    sys.stderr.flush()
                if not data:
                    fds = [master_fd]
                else:
                    try:
                        os.write(master_fd, data)
                    except OSError:
                        break
    finally:
        _restore_termios(stdin_fd, old_termios)
        try:
            os.close(master_fd)
        except Exception:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.stderr.write("usage: senity-mascot-filter.py <cmd> [args...]\n")
        sys.exit(2)
    _spawn_filtered(sys.argv[1:])
