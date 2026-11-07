#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Self-test of a generated scheme (development; `just test <scheme>`). Needs python3-gobject, GTK 3, GTK 4, gnome-shell.

  python3 -I tools/selftest.py <scheme> [contrast|gtk3|gtk4|shell|all]

contrast : WCAG ratios from palette.toml (fg on window and view, dim text, text on each of the six accents, warning text)
gtk3/gtk4/shell (each in its own process, the toolkits cannot share one):
  structure : stock stylesheet and generated file are identical after masking colour tokens (0 differing lines)
  neutrals  : generated tokens equal to a stock neutral grey (stray default-Adwaita greys; pure black/white excluded)
  parse     : the default files and every accent (token map applied with sed to a temp copy) load without CSS errors,
              and no token of the default accent map survives in the accent result
  probe     : computed colours (GTK3: window, entry, selected row; GTK4: named colours; Shell: root, default button)
"""
import sys, os, re, subprocess, tempfile, shutil, tomllib, glob
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
from themegen import TOK, hx, chroma

def lum(c):
    f = lambda v: v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (f(v / 255) for v in hx(c)); return 0.2126 * r + 0.7152 * g + 0.0722 * b
def cr(a, b):
    x, y = sorted((lum(a), lum(b)), reverse=True); return (x + 0.05) / (y + 0.05)

scheme = sys.argv[1].rstrip('/') if len(sys.argv) > 1 else sys.exit(__doc__)
mode = sys.argv[2] if len(sys.argv) > 2 else 'all'
ROOT = os.path.dirname(HERE)
D = os.path.join(ROOT, scheme)
with open(D + '/palette.toml', 'rb') as f: M = tomllib.load(f)
FAIL = []
def ok(cond, msg):
    print(('PASS ' if cond else 'FAIL ') + msg)
    if not cond: FAIL.append(msg)

def contrast():
    for v, R in M['roles'].items():
        print('-- %s' % v)
        for name, a, b in (('fg on window', R['fg'], R['bg']), ('fg on view', R['fg'], R['bg_deep']), ('fg on headers', R['fg'], R['surface']),
                           ('fg on popovers', R['fg'], R['surface_high']), ('warning text', R['warning_fg'], R['yellow'])):
            r = cr(a, b); print('   %-15s %5.2f %s' % (name, r, '' if r >= 4.5 else '  < 4.5'))
            if name in ('fg on window', 'fg on view'): ok(r >= 4.5, '%s %s >= 4.5 (%.2f)' % (v, name, r))
        for n, (col, fg) in ((n, (t['color'], t['fg'])) for n, t in M['accents'][v].items()):
            r = cr(fg, col); print('   accent %-8s %s on %s %5.2f %s' % (n, fg, col, r, '' if r >= 4.5 else '  < 4.5 (best available)'))

# ---- sed maps, as themectl applies them ------------------------------------------------------------------------
def variant_of(rel):
    if rel.endswith('gtk-dark.css') or '-Dark' in rel: return 'dark'
    return 'dark' if M['dark_only'] else 'light'
def apply_map(src, dst, accent, v):
    m = '%s/accents/%s.%s.sed' % (D, accent, v)
    open(dst, 'w').write(subprocess.run(['sed', '-f', m, src], capture_output=True, text=True, check=True).stdout)
def keys(accent, v):
    return re.findall(r'^s\|(.*?)\|@@', open('%s/accents/%s.%s.sed' % (D, accent, v)).read(), re.M)

def mask(css):
    css = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
    css = re.sub(r'-st-accent(-fg)?-color', '#C', css)
    css = TOK.sub('#C', css)
    return css.strip()
def neutral_tokens(css):
    out = set()
    for t in TOK.findall(css):
        t = t.lower()
        if t in ('white', 'black'): continue
        if t.startswith('rgb'):
            n = [float(x) for x in re.findall(r'[\d.]+', t)[:3]]; rgb = tuple(int(x) for x in n)
        else: rgb = hx(t)
        if rgb in ((0, 0, 0), (255, 255, 255)): continue
        if chroma(rgb) <= 16: out.add(t)
    return out

def toolkit(kind):
    """Run the checks of one toolkit in this process."""
    import gi
    from gi.repository import Gio
    files = {}     # path -> (stock text, variant)
    if kind == 'gtk3':
        gi.require_version('Gtk', '3.0'); from gi.repository import Gtk
        R = '/org/gtk/libgtk/theme/Adwaita/'; sub = 'gtk-3.0'; src = {'gtk.css': 'gtk-contained.css', 'gtk-dark.css': 'gtk-contained-dark.css'}
    elif kind == 'gtk4':
        gi.require_version('Gtk', '4.0'); from gi.repository import Gtk
        R = '/org/gtk/libgtk/theme/Default/'; sub = 'gtk-4.0'; src = {'gtk.css': 'Default-light.css', 'gtk-dark.css': 'Default-dark.css'}
    if kind in ('gtk3', 'gtk4'):
        base = '%s/themes/%s/%s' % (D, M['gtk_name'], sub)
        for dst, s in src.items():
            if M['dark_only'] and dst == 'gtk.css': s = src['gtk-dark.css']
            files[base + '/' + dst] = (bytes(Gio.resources_lookup_data(R + s, 0).get_data()).decode(), variant_of(dst))
    else:
        res = Gio.Resource.load('/usr/share/gnome-shell/gnome-shell-theme.gresource')
        for v in (['dark'] if M['dark_only'] else ['dark', 'light']):
            p = '%s/themes/%s-%s/gnome-shell/gnome-shell.css' % (D, M['shell_name'], v.capitalize())
            files[p] = (bytes(res.lookup_data('/org/gnome/shell/theme/gnome-shell-%s.css' % v, 0).get_data()).decode(), v)
    tmp = tempfile.mkdtemp()
    def load(path):
        """CSS errors of the file as the toolkit sees it."""
        errs = []
        if kind == 'shell':
            try: Theme = St.Theme(); Theme.load_stylesheet(Gio.File.new_for_path(path))
            except Exception as e: errs.append(str(e))
        else:
            prov = Gtk.CssProvider(); prov.connect('parsing-error', lambda p, sec, e: errs.append(str(e)))
            try:
                prov.load_from_path(path)
            except Exception as e: errs.append(str(e))
        return errs
    if kind == 'shell':
        gi.require_version('St', '51'); gi.require_version('Clutter', '51'); from gi.repository import St
    for path, (stock, v) in files.items():
        rel = os.path.relpath(path, D); new = open(path).read()
        body = new[new.index('*/') + 2:] if kind == 'shell' else new[new.index('*/') + 2:]
        # structure: shell stock keeps its own header comment; compare after dropping comments
        a, b = mask(stock), mask(new)
        diff = sum(1 for x, y in zip(a.split('\n'), b.split('\n')) if x != y) + abs(len(a.split('\n')) - len(b.split('\n')))
        ok(diff == 0, '%s structure identical to stock after colour masking (%d differing lines)' % (rel, diff))
        stray = neutral_tokens(stock) & neutral_tokens(body)
        stray_n = sum(len(re.findall(re.escape(t), body, re.I)) for t in stray)
        print('     stray stock neutral tokens: %d distinct, %d occurrences%s' % (len(stray), stray_n, ' (%s)' % ', '.join(sorted(stray)[:6]) if stray else ''))
        e = load(path); ok(not e, '%s parses (%d errors %s)' % (rel, len(e), e[:2]))
        for acc in M['accents'][v if v in M['accents'] else 'dark']:
            if acc == M['default_accent']: continue
            dst = os.path.join(tmp, acc + '-' + os.path.basename(path)); apply_map(path, dst, acc, v)
            e = load(dst); left = [k for k in keys(acc, v) if re.search(re.escape(k), open(dst).read(), re.I)]
            ok(not e and not left, '%s accent %s: parses, %d default-accent tokens left' % (rel, acc, len(left)))
    # probes
    if kind == 'gtk3':
        win = Gtk.Window(); ent = Gtk.Entry(); tv = Gtk.TreeView()
        for path, (stock, v) in files.items():
            prov = Gtk.CssProvider(); prov.load_from_path(path)
            def col(w, st=Gtk.StateFlags.NORMAL, cls=None, fg=False):
                c = w.get_style_context(); sc = Gtk.StyleContext(); sc.set_path(c.get_path()); sc.add_provider(prov, 600)
                if cls: sc.add_class(cls)
                sc.set_state(st); r = sc.get_color(st) if fg else sc.get_background_color(st)
                return '#%02x%02x%02x' % (round(r.red * 255), round(r.green * 255), round(r.blue * 255))
            print('     probe %s: window bg %s, entry bg %s, entry text %s, selected row %s on %s' % (os.path.basename(path), col(win), col(ent), col(ent, fg=True),
                  col(tv, Gtk.StateFlags.SELECTED, 'view'), col(tv, Gtk.StateFlags.SELECTED, 'view', True)))
    elif kind == 'gtk4':
        for path, (stock, v) in files.items():
            prov = Gtk.CssProvider(); prov.load_from_path(path); w = Gtk.Window(); c = w.get_style_context(); c.add_provider(prov, 600)
            vals = []
            for n in ('theme_bg_color', 'theme_base_color', 'theme_fg_color', 'theme_selected_bg_color', 'theme_selected_fg_color'):
                okk, r = c.lookup_color(n); vals.append('%s %s' % (n.replace('theme_', ''), '#%02x%02x%02x' % (round(r.red * 255), round(r.green * 255), round(r.blue * 255)) if okk else '?'))
            print('     probe %s: %s' % (os.path.basename(path), ', '.join(vals)))
    else:
        from gi.repository import GObject
        for path, (stock, v) in files.items():
            ctx = GObject.new(St.ThemeContext); t = St.Theme(); t.load_stylesheet(Gio.File.new_for_path(path)); ctx.set_theme(t)
            root = ctx.get_root_node()
            def nd(typ, cls): return St.ThemeNode.new(ctx, root, t, typ.__gtype__, '', cls, '', '')
            h = lambda c: '#%02x%02x%02x' % (c.red, c.green, c.blue)
            b = nd(St.Button, 'button default')
            print('     probe %s: root text %s, default button bg %s text %s (palette accent %s, fg %s)' % (os.path.basename(path), h(root.get_foreground_color()),
                  h(b.get_background_color()), h(b.get_foreground_color()), M['accents'][v][M['default_accent']]['color'], M['accents'][v][M['default_accent']]['fg']))
            ok(h(b.get_background_color()) == M['accents'][v][M['default_accent']]['color'], '%s default button background is the scheme accent (not GNOME\'s runtime accent)' % os.path.basename(os.path.dirname(os.path.dirname(path))))
            for acc in M['accents'][v]:
                if acc == M['default_accent']: continue
                dst = os.path.join(tmp, acc + '-' + os.path.basename(path)); apply_map(path, dst, acc, v)
                t2 = St.Theme(); t2.load_stylesheet(Gio.File.new_for_path(dst)); c2 = GObject.new(St.ThemeContext); c2.set_theme(t2)
                b2 = St.ThemeNode.new(c2, c2.get_root_node(), t2, St.Button.__gtype__, '', 'button default', '', '')
                ok(h(b2.get_background_color()) == M['accents'][v][acc]['color'], '%s accent %s: default button bg %s' % (os.path.basename(os.path.dirname(os.path.dirname(path))), acc, h(b2.get_background_color())))
    shutil.rmtree(tmp)
    return not FAIL

if mode == 'contrast': contrast()
elif mode in ('gtk3', 'gtk4', 'shell'):
    if mode == 'shell':
        import glob as g
        mut = g.glob('/usr/lib64/mutter-*')[0]; os.environ['GI_TYPELIB_PATH'] = '/usr/lib64/gnome-shell:' + mut
    toolkit(mode); sys.exit(1 if FAIL else 0)
else:
    contrast(); rc = 0
    for k in ('gtk3', 'gtk4', 'shell'):
        env = dict(os.environ)
        if k == 'shell':
            mut = glob.glob('/usr/lib64/mutter-*')[0]; env['LD_LIBRARY_PATH'] = '/usr/lib64/gnome-shell:' + mut
        print('== %s %s' % (scheme, k)); rc |= subprocess.run([sys.executable, '-I', os.path.abspath(__file__), scheme, k], env=env).returncode
    sys.exit(rc or (1 if FAIL else 0))
