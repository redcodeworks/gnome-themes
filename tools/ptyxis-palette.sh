#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Read the colour palettes built into the Ptyxis binary, BY ID (what Ptyxis stores in a profile's `palette` key; the Name is only for people).
#   tools/ptyxis-palette.sh list          one line per palette: <id><TAB><Name><TAB><sections>   (sections: Light,Dark or "flat" = one set)
#   tools/ptyxis-palette.sh show <id>     the palette's INI text, verbatim (the id is case-sensitive: `solarized` and `Solarized` differ)
# A thin wrapper around tools/ptyxis-ids.py, which reads the palettes from the binary's GResource (names are UTF-8, e.g. Rosé Pine).
# Environment: PTYXIS_BIN (default /usr/bin/ptyxis; or a directory of <id>.palette files, which is how the tests supply fixtures).
exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/ptyxis-ids.py" "$@"
