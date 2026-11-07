#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Read the colour palettes that are built into the Ptyxis binary (they are INI files stored as plain text in it).
#   tools/ptyxis-palette.sh list            one line per palette: <Name><TAB><sections>   (sections: Light,Dark or "flat" = one set)
#   tools/ptyxis-palette.sh show <name>     the palette's INI text, verbatim (name match is case-insensitive; the first palette of that name when the binary has two)
# A palette starts at a `[Palette]` line and is valid when it has a Name= and a Color15= (a record is cut at the next palette or the first line
# that is not INI). Flat palettes have Background/Foreground/Cursor/Color0..15 directly; others have [Light] and/or [Dark] sections.
# Environment: PTYXIS_BIN (default /usr/bin/ptyxis; any file that contains the palette text, which is how the tests use it).
# Used by tools/scheme-from-ptyxis.py and the build-scheme skill to start a new scheme from a built-in palette. Needs strings (binutils) and awk.
set -euo pipefail
# Names are UTF-8 (Rosé Pine): read the binary as 8-bit strings (`strings -e S`; the default 7-bit mode drops any line with a non-ASCII
# byte) and treat everything as bytes (LC_ALL=C), so the names pass through unchanged. Case-insensitive match is ASCII-only.
export LC_ALL=C
bin="${PTYXIS_BIN:-/usr/bin/ptyxis}"
cmd="${1:-}"; name="${2:-}"
[ -r "$bin" ] || { echo "ptyxis-palette.sh: cannot read $bin (set PTYXIS_BIN)" >&2; exit 2; }
command -v strings >/dev/null 2>&1 || { echo "ptyxis-palette.sh: needs strings (binutils)" >&2; exit 2; }
records() {   # prints each valid palette as: a line "@@ <Name>" followed by its INI text, ended by "@@END"
    strings -a -e S "$bin" | awk '
        function flush() { if (inrec && nm != "" && c15) { print "@@ " nm; printf "%s", buf; print "@@END" } inrec = 0; buf = ""; nm = ""; c15 = 0 }
        /^\[Palette\]$/ { flush(); inrec = 1; buf = $0 "\n"; next }
        inrec && /^\(uuay\)/ { flush(); next }
        inrec && (/^\[[A-Za-z]+\]$/ || /^[A-Za-z0-9]+=/ || /^#/ || /^$/) {
            buf = buf $0 "\n"
            if ($0 ~ /^Name=/ && nm == "") nm = substr($0, 6)
            if ($0 ~ /^Color15=/) c15 = 1
            next
        }
        { flush() }
        END { flush() }'
}
case "$cmd" in
    list)
        records | awk '/^@@END$/ { printf "%s\t%s\n", nm, (sec == "" ? "flat" : sec); nm = ""; sec = ""; next }
                       /^@@ / { nm = substr($0, 4); next }
                       /^\[(Light|Dark)\]$/ { s = substr($0, 2, length($0) - 2); sec = (sec == "" ? s : sec "," s) }' ;;
    show)
        [ -n "$name" ] || { echo "usage: ptyxis-palette.sh show <name>" >&2; exit 2; }
        out=$(records | awk -v want="$name" 'BEGIN { w = tolower(want) }
            /^@@ / { hit = (!found && tolower(substr($0, 4)) == w); next }
            /^@@END$/ { if (hit) found = 1; hit = 0; next }
            hit { print }') || true
        [ -n "$out" ] || { echo "ptyxis-palette.sh: no built-in palette named '$name' (see: ptyxis-palette.sh list)" >&2; exit 1; }
        printf '%s\n' "$out" ;;
    *) echo "usage: ptyxis-palette.sh list | show <name>" >&2; exit 2 ;;
esac
