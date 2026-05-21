#!/usr/bin/env python3
# senity-mascot-filter.py
#
# PTY-Wrapper, der Claude Code als Kindprozess startet und in den ersten
# Sekunden der Ausgabe die Mascot-Zeilen der Welcome-Box auf Leerzeichen
# ersetzt. Nach FILTER_SECONDS wird der Filter deaktiviert, damit normale
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
import fcntl
import struct
import termios
import signal
import select

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

# Welcome-Box-Title-Rewrite: "Welcome to Claude Code vX.Y" -> "Senity Wksp vX.Y"
# Der Title wird im claude-Binary aus getrennten V8-Snapshot-Strings komponiert
# und ist daher nicht statisch byte-patchbar. Wir machen es zur Laufzeit.
TITLE_RE = re.compile(
    r"Welcome to\s+(?:Claude Code|Senity Wksp)\s+v([0-9A-Za-z][0-9A-Za-z.+\- ]*?)\s*$"
)
NEW_PRODUCT = "Senity Wksp"

# Arc-Box-Title-Rewrite (das ist die tatsaechliche Realitaet im aktuellen Claude
# Code Binary): Top-Border ist `╭─── Claude Code v1.0 ───╮`. Zeilen-Separator
# innerhalb der Box ist `\r\x1b[1B` (CR + cursor-down-1), nicht `\n`, daher
# arbeiten wir auf Chunk-Ebene, nicht zeilenweise.
ARC_TL = b"\xe2\x95\xad"  # ╭ U+256D
ARC_TR = b"\xe2\x95\xae"  # ╮ U+256E
CLAUDE_CODE = b"Claude Code"
SENITY_WKSP = b"Senity Wksp"  # gleiche Byte-/Cell-Breite (11), keine Padding-Korrektur noetig

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


def rewrite_titles_in_chunk(chunk: bytes) -> bytes:
    """
    Ersetzt "Claude Code" -> "Senity Wksp" in zwei eng definierten Kontexten:
      1. Welcome-Box-Top-Border (Bereich zwischen ╭ und ╮)
      2. OSC-Window-Title (ESC ] 0 ; ... BEL)
    Andere Vorkommen ("Claude Code'll be able..." im Trust-Dialog, "Check the
    Claude Code changelog" im Tipp-Bereich der Welcome-Box) bleiben erhalten.
    """
    if ARC_TL in chunk and CLAUDE_CODE in chunk:
        chunk = ARC_TITLE_RE.sub(lambda m: m.group(1) + SENITY_WKSP, chunk)
    if b"\x1b]0;" in chunk:
        chunk = OSC_TITLE_RE.sub(
            lambda m: m.group(1) + SENITY_WKSP + m.group(2), chunk
        )
    return chunk

_state = {
    "start": None,
    "off": False,
    "buf": b"",  # Zeilen-Buffer
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
    den Box-Edges durch "<star> Senity Wksp v<version>" und behalte die
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


def filter_line(raw_line: bytes) -> bytes:
    """
    Akzeptiert eine vollstaendige Zeile inklusive ANSI-Sequenzen.
    Wenn die Zeile als Mascot-Zeile erkannt wird, ersetzen wir den
    Content zwischen den ersten und letzten Box-V-Edges durch Spaces.
    Sonst Zeile unveraendert zurueck.
    """
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
        return data
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
    return process_chunk(data)


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
                        os.write(stdout_fd, chunk)
                    except OSError:
                        break
                else:
                    if _state["start"] is None:
                        _state["start"] = time.monotonic()
                    if time.monotonic() - _state["start"] > FILTER_SECONDS:
                        _state["off"] = True
                        try:
                            os.write(stdout_fd, chunk)
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
                            os.write(stdout_fd, chunk2)
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
