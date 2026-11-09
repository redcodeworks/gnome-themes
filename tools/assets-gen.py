#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Write the shared GTK theme assets: assets/gtk-3.0/ and assets/gtk-4.0/ (the stock PNG and SVG files the theme CSS refers to as url("assets/...")).

  python3 -I tools/assets-gen.py [--check]      # --check: write nothing, exit 1 when the files differ from the installed GTK's

Every scheme's gtk.css uses the same unmodified stock assets (no generator recolours them), so the repo stores them ONCE, here, and the installer
copies them into each installed theme folder (gtk-3.0/assets, gtk-4.0/assets) so installed themes stay complete real directories. Files whose
content is already right are not rewritten (`just generate` for several schemes may run this in parallel). Needs python3-gobject, GTK 3 and GTK 4.
"""
import sys, os, subprocess
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def one(ver, check):
    import gi
    gi.require_version('Gtk', ver + '.0')
    from gi.repository import Gio, Gtk  # noqa: F401
    res = '/org/gtk/libgtk/theme/%s/assets' % ('Adwaita' if ver == '3' else 'Default')
    out = os.path.join(ROOT, 'assets', 'gtk-%s.0' % ver); os.makedirs(out, exist_ok=True)
    want = {n: bytes(Gio.resources_lookup_data(res + '/' + n, 0).get_data()) for n in Gio.resources_enumerate_children(res, 0)}
    bad = 0
    for n, data in want.items():
        p = os.path.join(out, n)
        if os.path.exists(p) and open(p, 'rb').read() == data: continue
        bad += 1
        if not check: open(p, 'wb').write(data)
    stale = [n for n in os.listdir(out) if n not in want]
    for n in stale:
        bad += 1
        if not check: os.remove(os.path.join(out, n))
    print('assets/gtk-%s.0: %d files, %d differ%s' % (ver, len(want), bad, '' if check else ' (written)' if bad else ''))
    return bad

if __name__ == '__main__':
    check = '--check' in sys.argv
    if len(sys.argv) > 1 and sys.argv[1] in ('3', '4'): sys.exit(1 if one(sys.argv[1], check) else 0)
    rc = 0
    for v in ('3', '4'):
        r = subprocess.run([sys.executable, '-I', os.path.abspath(__file__), v] + (['--check'] if check else []))
        rc |= r.returncode
    sys.exit(rc if check else 0)
