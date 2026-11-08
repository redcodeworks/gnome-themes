#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""List and read the colour palettes built into Ptyxis, by ID.

  python3 -I tools/ptyxis-ids.py list            one line per built-in: <id><TAB><Name><TAB><sections>   (sections: Light,Dark or flat)
  python3 -I tools/ptyxis-ids.py ids             the ids only, one per line
  python3 -I tools/ptyxis-ids.py show <id>       the palette's INI text, verbatim (the id is matched exactly, case-sensitive)

THE ID IS WHAT PTYXIS STORES. The profile's `palette` setting (dconf /org/gnome/Ptyxis/Profiles/<uuid>/palette) holds the palette ID, not
the display Name: for a built-in the id is the resource file name without `.palette`, case-sensitive ('nord', 'Gruvbox Material',
'Rosé Pine'; both `solarized` and `Solarized` exist and are different palettes). A value that is not an id makes Ptyxis fall back silently to
its default palette. Names are for people only.

The palettes are GResource files inside the binary: this reads the ELF section `.gresource.ptyxis` of /usr/bin/ptyxis (pure Python) and opens it
with Gio.Resource (python3-gobject), path /org/gnome/Ptyxis/palettes/. Environment: PTYXIS_BIN overrides the binary; it may also be a
DIRECTORY of `<id>.palette` files (how the tests supply fixtures). Importable: builtins() -> [(id, Name, sections, text)].
"""
import os, re, struct, sys

PREFIX = '/org/gnome/Ptyxis/palettes/'

def _gresource_bytes(path):
    with open(path, 'rb') as f: d = f.read()
    if d[:4] != b'\x7fELF' or d[4] != 2: raise SystemExit('ptyxis-ids.py: %s is not a 64-bit ELF file (set PTYXIS_BIN)' % path)
    shoff = struct.unpack_from('<Q', d, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3A)
    sec = [struct.unpack_from('<IIQQQQ', d, shoff + i * shentsize) for i in range(shnum)]   # name, type, flags, addr, offset, size
    stroff = sec[shstrndx][4]
    for name, _t, _f, _a, off, size in sec:
        if d[stroff + name:d.index(b'\0', stroff + name)] == b'.gresource.ptyxis': return d[off:off + size]
    raise SystemExit('ptyxis-ids.py: %s has no .gresource.ptyxis section (not a Ptyxis binary?)' % path)

def _sections(text): return ','.join(re.findall(r'^\[(Light|Dark)\]\s*$', text, re.M)) or 'flat'
def _name(text):
    m = re.search(r'^Name=(.*)$', text, re.M); return m.group(1).strip() if m else ''

def builtins(path=None):
    """[(id, Name, sections, text)] of every built-in palette, sorted by id."""
    path = path or os.environ.get('PTYXIS_BIN') or '/usr/bin/ptyxis'
    if not os.access(path, os.R_OK): raise SystemExit('ptyxis-ids.py: cannot read %s (set PTYXIS_BIN)' % path)
    items = []
    if os.path.isdir(path):
        for fn in os.listdir(path):
            if fn.endswith('.palette'):
                with open(os.path.join(path, fn), encoding='utf-8') as f: items.append((fn[:-8], f.read()))
    else:
        import gi; gi.require_version('Gio', '2.0')
        from gi.repository import Gio, GLib
        res = Gio.Resource.new_from_data(GLib.Bytes.new(_gresource_bytes(path)))
        for fn in res.enumerate_children(PREFIX, 0):
            if fn.endswith('.palette'):
                items.append((fn[:-8], bytes(res.lookup_data(PREFIX + fn, 0).get_data()).decode('utf-8')))
    return [(i, _name(t), _sections(t), t) for i, t in sorted(items)]

def main():
    sys.stdout.reconfigure(encoding='utf-8')
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd in ('list', 'ids'):
        for i, n, s, _ in builtins(): print(i if cmd == 'ids' else '%s\t%s\t%s' % (i, n, s))
    elif cmd == 'show' and len(sys.argv) > 2:
        for i, n, s, t in builtins():
            if i == sys.argv[2]: sys.stdout.write(t if t.endswith('\n') else t + '\n'); return
        sys.exit("ptyxis-ids.py: no built-in palette with id '%s' (ids are case-sensitive; see: ptyxis-ids.py list)" % sys.argv[2])
    else: sys.exit('usage: ptyxis-ids.py list | ids | show <id>')

if __name__ == '__main__': main()
