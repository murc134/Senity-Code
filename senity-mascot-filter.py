#!/usr/bin/env python3
# senity-mascot-filter.py
#
# PTY-Wrapper, der Claude Code als Kindprozess startet und in den ersten
# Sekunden der Ausgabe die Block-Element-Zeichen des Anthropic-Maskottchens
# (U+2588 FULL BLOCK, U+2590 RIGHT HALF, U+259B/C/D, U+258C, U+2598) durch
# ASCII-Spaces ersetzt. Nach 2.5 s wird der Filter deaktiviert, damit der
# Block-Cursor und sonstige Block-Element-Nutzung der TUI nicht beschnitten
# wird.
#
# Begruendung: Die Maskottchen-Zeichen liegen im claude-Native-Binary als
# V8-Snapshot dedupliziert vor — kein zusammenhaengender String, daher kein
# direkter Binary-Patch moeglich. PTY-Post-Processing ist der pragmatische
# Weg, die Welcome-Box ohne Maskottchen zu rendern.

import pty
import os
import sys
import time

BLOCK_CHARS = [
    b'\xe2\x96\x90',  # U+2590 RIGHT HALF BLOCK
    b'\xe2\x96\x9b',  # U+259B QUADRANT UPPER LEFT AND LOWER LEFT AND LOWER RIGHT
    b'\xe2\x96\x88',  # U+2588 FULL BLOCK
    b'\xe2\x96\x9c',  # U+259C QUADRANT UPPER LEFT AND UPPER RIGHT AND LOWER RIGHT
    b'\xe2\x96\x8c',  # U+258C LEFT HALF BLOCK
    b'\xe2\x96\x9d',  # U+259D QUADRANT UPPER RIGHT
    b'\xe2\x96\x98',  # U+2598 QUADRANT UPPER LEFT
]

FILTER_SECONDS = 2.5

_state = {'start': None, 'off': False}


def master_read(fd):
    data = os.read(fd, 8192)
    if _state['off']:
        return data
    if _state['start'] is None:
        _state['start'] = time.monotonic()
    if time.monotonic() - _state['start'] > FILTER_SECONDS:
        _state['off'] = True
        return data
    for ch in BLOCK_CHARS:
        data = data.replace(ch, b' ')
    return data


def stdin_read(fd):
    return os.read(fd, 8192)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.stderr.write('usage: senity-mascot-filter.py <cmd> [args...]\n')
        sys.exit(2)
    pty.spawn(sys.argv[1:], master_read, stdin_read)
