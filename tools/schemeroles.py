# SPDX-License-Identifier: MIT
"""Shared by tools/ptyxis-compare.py, tools/scheme-from-ptyxis.py and tools/gtksourceview-gen.py: load a scheme's roles (with the derived ones filled in
by the rules of palette-from-scheme.py) and the colour helpers. Not a program."""
import os, tomllib, importlib.util, colorsys

_p = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'palette-from-scheme.py')
_spec = importlib.util.spec_from_file_location('palette_from_scheme', _p)
pfs = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(pfs)
mix, contrast, hx, th, lum = pfs.mix, pfs.contrast, pfs.hx, pfs.th, pfs.lum

def load(scheme_dir):
    """(S, roles, slots): S = raw scheme.toml, roles = {variant: resolved roles}, slots = [(slot, variant)] for the
    light and dark slot; a dark-only scheme fills the light slot from the dark variant (the GTK light slot rule)."""
    with open(os.path.join(scheme_dir, 'scheme.toml'), 'rb') as f: S = tomllib.load(f)
    roles, _ = pfs.resolve(S)
    slots = [('light', 'light' if 'light' in roles else 'dark'), ('dark', 'dark')]
    if 'dark' not in roles: slots = [('light', 'light')]     # light-only scheme: no dark slot
    return S, roles, slots

NAMES = ('red', 'green', 'yellow', 'blue', 'magenta', 'cyan')

def ptyxis_ids(S):
    """(dark_id, light_id) of the scheme's Ptyxis built-in(s): `ptyxis = "<id>"` is required; `ptyxis_light = "<id>"` is for a scheme whose light
    variant is a separate flat built-in; without it the light mode uses `ptyxis` too. The id is what Ptyxis stores in a profile's `palette`
    key (the resource file name without `.palette`, case-sensitive), not the display Name. Exits when `ptyxis` is missing."""
    v = S.get('ptyxis'); lt = S.get('ptyxis_light')
    if not isinstance(v, str) or not v.strip(): raise SystemExit('scheme.toml: `ptyxis = "<Ptyxis built-in id>"` is required (with ptyxis_reason; see tools/ptyxis-ids.py list)')
    if lt is not None and (not isinstance(lt, str) or not lt.strip()): raise SystemExit('scheme.toml: ptyxis_light must be a built-in id')
    return v, (lt or v)

def slot_colors(S, roles, variant):
    """The 18 terminal colours (Background, Foreground, Color0..15, upper-case hex) a variant stands for: Background = bg_deep, Foreground = fg,
    Color1..6 = the accents, Color0/7/8..15 from the `[<variant>.terminal]` table (else defaults); what compare tools measure built-ins against."""
    R, T = roles[variant], S[variant].get('terminal', {})
    A = S[variant]['ansi']
    c = {}
    fg = T.get('foreground', R['fg']); c['Foreground'] = fg
    c['Background'] = T.get('background', R['bg_deep'])
    c['Cursor'] = T.get('cursor', fg)
    c['Color0'] = T.get('black', R['surface'])
    for i, n in enumerate(NAMES):
        c['Color%d' % (i + 1)] = A[n]
        c['Color%d' % (i + 9)] = T.get('bright_' + n, A[n])
    c['Color7'] = T.get('white', fg)
    c['Color8'] = T.get('bright_black', R['comment'])
    c['Color15'] = T.get('bright_white', c['Color7'])
    return {k: v.upper() for k, v in c.items()}

def nudge_to(color, bgs, need):
    """Change only the LIGHTNESS of `color` (hue and saturation kept), away from the backgrounds `bgs` (a colour or a list; lighter
    on dark ones, darker on light ones), in 1 % steps until it has contrast `need` on every one of them; returns (color, steps)."""
    bgs = [bgs] if isinstance(bgs, str) else list(bgs)
    dark = sum(lum(b) for b in bgs) / len(bgs) < 0.18
    h, l, s = colorsys.rgb_to_hls(*(v / 255 for v in hx(color)))
    c, n = color, 0
    while min(contrast(c, b) for b in bgs) < need and n < 100:
        n += 1; l2 = min(1.0, l + 0.01 * n) if dark else max(0.0, l - 0.01 * n)
        c = th(tuple(v * 255 for v in colorsys.hls_to_rgb(h, l2, s)))
    return c, n
