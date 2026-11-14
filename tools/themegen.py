# SPDX-License-Identifier: MIT
"""Shared recolour engine for the candy-for-gnome generators (tools/gtk3-theme-gen.py,
tools/gtk4-theme-gen.py, tools/shell-theme-gen.py): takes a stock GTK or GNOME Shell stylesheet VERBATIM and replaces COLOUR VALUES only,
driven by a palette TOML. No toolkit-specific code here (no gi import)."""
import colorsys, re, os, sys

def arg(name):
    """--name=VALUE from argv, or None."""
    for a in sys.argv[1:]:
        if a.startswith('--%s=' % name): return a.split('=', 1)[1]
    return None

def hx(s):
    s = s.lstrip('#')
    if len(s) == 3: s = ''.join(c * 2 for c in s)
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))
def th(t): return '#%02x%02x%02x' % tuple(max(0, min(255, round(v))) for v in t)

def load_meta(path):
    """Root-level scheme data of a palette TOML (title, credit, names, default_accent, ...)."""
    import tomllib
    with open(path, 'rb') as f: return tomllib.load(f)

def load_palette(path, section=None):
    """Palette data lives in a TOML file (one per scheme, --palette=FILE). section: read the
    [<section>.dark] / [<section>.light] tables instead of [dark] / [light] (the GNOME Shell
    generator uses "shell", because stock Shell's greys differ from GTK's). A dark-only scheme has
    no light table; callers loop over the variants that are present. Each variant table also gets
    P['accents'] ({name: {color, fg}} from [accents.<variant>.<name>]) and P['accent'] (the default
    accent colour)."""
    root = load_meta(path)
    d = root[section] if section else root
    d = {v: d[v] for v in ('dark', 'light') if v in d}
    for v, P in d.items():
        P['ramp'] = [(g, c) for g, c in P['ramp']]
        P['fam'] = {k: tuple(x) for k, x in P['fam'].items()}
        P['accents'] = root.get('accents', {}).get(v, {})
        P['accent'] = P['accents'][root['default_accent']]['color'] if P['accents'] else P['fam']['blue'][1]
    return d

def with_accent(P, name):
    """A copy of variant palette P with the accent family (blue anchor target, exact entries that
    map to the default accent, text-on-accent colour) switched to accent <name>."""
    import copy
    a = P['accents'][name]; old = P['accent'].lower(); Q = copy.deepcopy(P)
    Q['fam']['blue'] = (P['fam']['blue'][0], a['color'])
    Q['exact'] = {k: (a['color'] if v.lower() == old else v) for k, v in P['exact'].items()}
    Q['accent_fg'] = a['fg']; Q['accent'] = a['color']
    return Q

def accent_dir_write(adir, accent, rel, text):
    """Write the output of an accent run under <adir>/<accent>/<rel> (used by --accent-dir)."""
    p = os.path.join(adir, accent, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'w').write(text)

def lerp(a, b, t): return tuple(x + (y - x) * t for x, y in zip(a, b))
def hsl_l(rgb): return colorsys.rgb_to_hls(*(v / 255 for v in rgb))[1]
def family(rgb):
    h = colorsys.rgb_to_hls(*(v / 255 for v in rgb))[0] * 360
    if 170 <= h < 275: return 'blue'
    if h >= 335 or h < 15: return 'red'
    if h < 75: return 'orange'
    if h < 170: return 'green'
    return 'blue'
def chroma(rgb): return max(rgb) - min(rgb)

def map_rgb(rgb, P, accent_ctx=False):
    key = th(rgb)
    if key in P['exact']: return hx(P['exact'][key])
    if chroma(rgb) <= 16:                       # neutral: ramp
        g = sum(rgb) / 3
        R = P['ramp']
        for (g0, c0), (g1, c1) in zip(R, R[1:]):
            if g <= g1:
                return lerp(hx(c0), hx(c1), (g - g0) / (g1 - g0) if g1 > g0 else 0)
        return hx(R[-1][1])
    fam = family(rgb)
    a_stock, a_new = P['fam'][fam]
    La = hsl_l(hx(a_stock)); L = hsl_l(rgb); tgt = hx(a_new)
    if L <= La: return lerp(tgt, (0, 0, 0), 1 - L / La)
    return lerp(tgt, hx(P['top']), (L - La) / (1 - La))

# Colour tokens. Relative-colour functions (GTK 4: rgb(from X r g b / calc(alpha * .4)),
# hsl(from X h calc(s * 1.2) ...)) are NOT matched as a whole: only the origin colour X inside
# them is, so the function syntax stays intact. black/white right after "from " are left alone
# (alpha-only origins), as is currentColor.
TOK = re.compile(r'#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b|rgba?\((?!\s*from\b)[^)]*\)|(?<!from )(?<![\w-])white(?![\w-])|(?<!from )(?<![\w-])black(?![\w-])')
STATS = {'unmapped': 0}

def conv(tok, prop, P, fgctx):
    t = tok.lower()
    if t.startswith('rgb'):
        v = [x.strip() for x in t[t.index('(') + 1:-1].split(',')]
        rgb = tuple(int(float(x)) for x in v[:3]); a = v[3] if len(v) > 3 else None
        if rgb in ((0, 0, 0), (255, 255, 255)): return tok
        n = th(map_rgb(rgb, P))
        r, g, b = hx(n)
        return 'rgba(%d, %d, %d, %s)' % (r, g, b, a) if a is not None else 'rgb(%d, %d, %d)' % (r, g, b)
    if t in ('white', 'black'):
        if not (prop == 'color' or prop == 'caret-color'): return tok     # shadows, backgrounds: leave
        if t == 'white' and fgctx: return P['accent_fg']
        return P['fg']
    rgb = hx(t)
    if fgctx and prop == 'color':
        L = hsl_l(rgb)                  # text on an accent/coloured background:
        if L >= 0.5:                    # white -> accent_fg, dimmed whites -> accent_fg blended into the accent
            k = 0.25 + 0.75 * (L - 0.5) / 0.5
            return th(lerp(hx(P['fam']['blue'][1]), hx(P['accent_fg']), k))
    return th(map_rgb(rgb, P))

def has_coloured_bg(body):
    for d in body.split(';'):
        if ':' not in d: continue
        p, v = d.split(':', 1)
        if p.strip().startswith('background'):
            for tk in TOK.findall(v):
                if tk.lower().startswith('rgb'):
                    n = [float(x) for x in tk[tk.index('(') + 1:-1].split(',')]
                    if len(n) > 3 and n[3] < 0.9: continue   # translucent fills sit on a dark/neutral surface
                    rgb = tuple(int(x) for x in n[:3])
                elif tk.lower() in ('white', 'black'): continue
                else: rgb = hx(tk)
                if chroma(rgb) > 16: return True
    return False

def recolour(css, P):
    def body_sub(m):
        sel, body = m.group(1), m.group(2)
        fgctx = has_coloured_bg(body) or (P.get('selected_ctx', True) and bool(re.search(r':selected|(?<![-\w])selection(?![-\w])', sel)))
        out = []
        for d in body.split(';'):
            if ':' in d:
                p, v = d.split(':', 1)
                v = TOK.sub(lambda mm: conv(mm.group(0), p.strip(), P, fgctx), v)
                d = p + ':' + v
            out.append(d)
        return sel + '{' + ';'.join(out) + '}'
    css = re.sub(r'([^{}]*)\{([^{}]*)\}', body_sub, css)
    def dc(m):                                   # @define-color name value;
        name, val = m.group(1), m.group(2)
        if name in ('theme_selected_fg_color', 'theme_unfocused_selected_fg_color'):
            return '@define-color %s %s;' % (name, P['accent_fg'])
        if name == 'text_view_bg':
            return '@define-color %s %s;' % (name, P['view'])
        val = TOK.sub(lambda mm: conv(mm.group(0), 'color', P, False), val)
        return '@define-color %s %s;' % (name, val)
    return re.sub(r'@define-color (\w+) ([^;]+);', dc, css)

