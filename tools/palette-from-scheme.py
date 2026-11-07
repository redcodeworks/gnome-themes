#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Derive a scheme's generator tables (<scheme>/palette.toml) from its role file (<scheme>/scheme.toml).

  python3 -I tools/palette-from-scheme.py <scheme-dir> [--check]     # --check: print, write nothing

scheme.toml is small data: per variant ([dark], optional [light]) the roles
  bg_deep (the view: darkest dark surface, lightest light surface), bg (window), surface (headers,
  buttons, sidebars), surface_high (popovers, menus, dialogs), fg, fg_dim (readable secondary text),
  comment (mid grey: placeholders, borders), selection (informational), red orange yellow green
  cyan blue magenta purple (pink optional), plus [<variant>.ansi] = the six terminal accents
  (red green yellow blue magenta cyan, normal not bright), optionally a seventh `orange` (the scheme's own orange role
  colour; a scheme whose upstream has no orange, rose-pine and fairy-floss, simply omits it) and the root key default_accent.
Optional roles: popover (default surface_high), accent_fg (default bg_deep), warning_fg,
[<variant>.adw] secondary_sidebar (libadwaita override). Missing roles are DERIVED by fixed rules
(the generated palette.toml says which):
  surface ladder, dark  : bg = deep + 5.5 %, surface = + 16 %, surface_high = + 28 % towards fg
                          (the proportions of Gruvbox Material medium: #282828 -> #32302f/#45403d/#5a524c)
  surface ladder, light : bg = deep + 3 %, surface = + 6 %, surface_high = + 9 % towards fg
  fg_dim = fg 30 % towards bg;  comment = fg 55 % towards bg
Table rules (what the generators read): GTK ramp stops (stock grey level -> role): dark 0 black,
45 deep, 53 bg, 66 surface, 91 surface_high, 145 comment, 238/255 fg; light 0/46 fg, 145 comment,
224 surface_high, 237 surface, 246 bg, 255 deep. Shell ramp: dark 0/34.67 deep, 55.33 bg, 66.33
surface, 86.67 surface_high, 156/179 fg_dim, 250/255 fg; light 0/46 fg, 145 comment, 224
surface_high, 237 surface, 250/255 deep. Families: blue = the DEFAULT ACCENT, red = red, green =
green, orange = yellow (GTK warning) or orange (Shell), exact stock colours to roles. Text on an
accent = accent_fg; per accent it is switched to a better-contrast ink only when the default fails
4.5:1 (then the default accent_fg is nudged by one blue step so the sed token map stays unambiguous,
as is the success green when it equals the accent colour).
"""
import sys, os, tomllib, colorsys

def hx(s):
    s = s.lstrip('#'); return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))
def th(t): return '#%02x%02x%02x' % tuple(max(0, min(255, round(v))) for v in t)
def mix(a, b, t): return th(tuple(x + (y - x) * t for x, y in zip(hx(a), hx(b))))
def lum(c):
    f = lambda v: v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (f(v / 255) for v in hx(c)); return 0.2126 * r + 0.7152 * g + 0.0722 * b
def contrast(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True); return (la + 0.05) / (lb + 0.05)
def nudge(c, n=1):
    r, g, b = hx(c); return th((r, g, b + n if b + n <= 255 else b - n))

LADDER = {'dark': (0.055, 0.16, 0.28), 'light': (0.03, 0.06, 0.09)}
ANSI = ('red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'orange')   # the six terminal colours plus the optional orange

def resolve(S):
    """Fill derived roles; returns {variant: roles}, notes."""
    out, notes = {}, []
    for v in ('dark', 'light'):
        if v not in S: continue
        R = dict(S[v]); deep, fg = R['bg_deep'], R['fg']
        for role, t in zip(('bg', 'surface', 'surface_high'), LADDER[v]):
            if role not in R:
                R[role] = mix(deep, fg, t); notes.append('%s.%s derived: %s %.1f%% towards fg' % (v, role, deep, t * 100))
        for role, t in (('fg_dim', 0.30), ('comment', 0.55)):
            if role not in R:
                R[role] = mix(fg, R['bg'], t); notes.append('%s.%s derived: fg %d%% towards bg' % (v, role, t * 100))
        R.setdefault('popover', R['surface_high'] if v == 'dark' else deep); R.setdefault('accent_fg', deep)
        out[v] = R
    return out, notes

def pick_fg(R, color, inks):
    """(accent_fg for this accent, overridden?)"""
    d = R['accent_fg']
    if contrast(d, color) >= 4.5: return d, False
    best = max(inks, key=lambda c: contrast(c, color))
    if contrast(best, color) > contrast(d, color) + 0.3: return best, True
    return d, False

def build(S):
    roles, notes = resolve(S)
    dflt = S['default_accent']; dark_only = 'light' not in roles
    inks_dark = [roles['dark']['bg_deep'], roles['dark']['bg']] + ([roles['light']['fg']] if not dark_only else [])
    inks_light = [roles['dark']['fg']] + ([roles['light']['bg_deep']] if not dark_only else [])
    ink = {'dark': min(inks_dark, key=lum), 'light': max(inks_light, key=lum)}
    acc, rl = {}, {}
    for v, R in roles.items():
        A = S[v]['ansi']; table = {}
        for n in [x for x in ANSI if x in A]:
            fg, _ = pick_fg(R, A[n], [ink['dark'], ink['light']]); table[n] = [A[n].lower(), fg.lower()]
        dfl = table[dflt][1]
        if len({t[1] for t in table.values()}) > 1:
            # the text-on-accent colour varies with the accent: the default one must be a token of its own (it
            # equals bg_deep otherwise, and the lerp(accent, accent_fg) text shades would collide with the tints
            # towards `top`), so it moves 8 blue steps (3 %, invisible); accents sharing it move with it
            new = nudge(dfl, 8).lower()
            notes.append('%s.accent_fg %s -> %s (the text colour varies per accent: the default needs its own token)' % (v, dfl, new))
            for n in table:
                if table[n][1] == dfl: table[n][1] = new
            dfl = new
        R['accent_fg'] = dfl
        # roles that share the accent colour would make the token map ambiguous: nudge the other role
        for role in ('red', 'green', 'yellow', 'orange'):
            if R[role].lower() == A[dflt].lower():
                # the orange role is the anchor of a whole family of derived shades, like the accent: a 1-unit nudge lets
                # shades of the two families collapse into one token, so it moves 8 blue steps (3 %, invisible)
                R[role] = nudge(R[role], 8 if role == 'orange' else 1); notes.append('%s.%s nudged to %s (it equals the default accent; keeps accent tokens unique)' % (v, role, R[role]))
        acc[v] = table
    return roles, acc, notes

def toml_str(v): return '"%s"' % v
def ramp_text(r): return '[' + ',\n        '.join(','.join('[%s,"%s"]' % (g, c) for g, c in r[i:i + 4]) for i in range(0, len(r), 4)) + ']'

def tables(R, v, kind, accent):
    """ramp / fam / exact for one variant of GTK or Shell."""
    deep, bg, sf, hi, fg, dim, com = (R[k] for k in ('bg_deep', 'bg', 'surface', 'surface_high', 'fg', 'fg_dim', 'comment'))
    if kind == 'gtk' and v == 'dark':
        ramp = [(0, '#000000'), (45, deep), (53, bg), (66, sf), (91, hi), (145, com), (238, fg), (255, fg)]
        fam = {'blue': ('#15539e', accent), 'red': ('#cc0000', R['red']), 'orange': ('#f57900', R['yellow']), 'green': ('#4e9a06', R['green'])}
        ex = [('#26ab62', R['green'], ''), ('#26a269', R['green'], 'GTK4 stock success green'), ('#3584e4', accent, ''), ('#eeeeec', fg, '')]
    elif kind == 'gtk':
        ramp = [(0, fg), (46, fg), (145, com), (224, hi), (237, sf), (246, bg), (255, deep)]
        fam = {'blue': ('#3584e4', accent), 'red': ('#cc0000', R['red']), 'orange': ('#f57900', R['yellow']), 'green': ('#4e9a06', R['green'])}
        ex = [('#33d17a', R['green'], ''), ('#2ec27e', R['green'], 'GTK4 stock success green (light)'), ('#2e3436', fg, ''), ('#f6f5f4', bg, '')]
    elif v == 'dark':
        ramp = [(0, deep), (34.67, deep), (55.33, bg), (66.33, sf), (86.67, hi), (156, dim), (179, dim), (250, fg), (255, fg)]
        fam = {'blue': ('#3584e4', accent), 'red': ('#c01c28', R['red']), 'orange': ('#ff7800', R['orange']), 'green': ('#26a269', R['green'])}
        ex = [('#cd9309', R['yellow'], 'warning yellow (hue 43, would fall in the orange family)'), ('#a5a5b7', dim, 'web-login title, dim text'),
              ('#54545a', sf, 'notification/message card: surface'), ('#45454a', mix(bg, sf, 0.5), 'message card stacked behind the front one: bg and surface mixed 50 %')]
    else:
        ramp = [(0, fg), (46, fg), (145, com), (224, hi), (237, sf), (250, deep), (255, deep)]
        fam = {'blue': ('#3584e4', accent), 'red': ('#c01c28', R['red']), 'orange': ('#e66100', R['orange']), 'green': ('#26a269', R['green'])}
        ex = [('#e5a50a', R['yellow'], 'warning yellow'), ('#a5a5b7', com, '')]
    return ramp, fam, ex

def emit_variant(name, R, v, kind, accent):
    ramp, fam, ex = tables(R, v, kind, accent)
    top = R['fg'] if v == 'dark' else R['bg_deep']
    L = ['[%s]' % name]
    if kind == 'shell': L.append('selected_ctx = false   # Shell\'s :selected is a plain hover/keyboard-focus state, not text on an accent fill')
    L += ['ramp = ' + ramp_text(ramp), 'fg = "%s"' % R['fg'], 'top = "%s"' % top, 'accent_fg = "%s"' % R['accent_fg'], 'view = "%s"' % R['bg_deep'], '[%s.fam]' % name]
    L += ['%s = ["%s","%s"]' % (k, a, b) for k, (a, b) in fam.items()]
    L += ['[%s.exact]' % name]
    L += ['"%s" = "%s"%s' % (a, b, ('      # ' + c) if c else '') for a, b, c in ex]
    return '\n'.join(L) + '\n'

def main():
    if len(sys.argv) < 2: sys.exit(__doc__)
    d = sys.argv[1].rstrip('/')
    with open(d + '/scheme.toml', 'rb') as f: S = tomllib.load(f)
    roles, acc, notes = build(S)
    dflt = S['default_accent']; dark_only = 'light' not in roles
    out = ['# SPDX-License-Identifier: MIT',
           '# GENERATED by tools/palette-from-scheme.py from scheme.toml (edit that, then run `just generate`): the tables read by',
           '# tools/gtk3-theme-gen.py, gtk4-theme-gen.py, shell-theme-gen.py and libadwaita-gen.py. Rules: see the script header.']
    out += ['# derived: ' + n for n in notes] or ['# (no role was derived: scheme.toml lists them all)']
    out += ['title = "%s"' % S['title'], 'gtk_name = "%s"' % S['gtk_name'], 'shell_name = "%s"' % S['shell_name'],
            'credit = "%s"' % S['credit'], 'default_accent = "%s"' % dflt, 'dark_only = %s' % str(dark_only).lower(), '']
    for v in roles:
        out.append(emit_variant(v, roles[v], v, 'gtk', acc[v][dflt][0]))
    out.append('# [shell.*]: stock Shell greys differ from GTK\'s, so the ramps have their own stops.\n')
    for v in roles:
        out.append(emit_variant('shell.' + v, roles[v], v, 'shell', acc[v][dflt][0]))
    out.append('# accents: [accents.<variant>.<name>] color = the terminal\'s ANSI colour, fg = text on it (contrast in tools/selftest.py)')
    for v in roles:
        for n in acc[v]:
            out.append('[accents.%s.%s]\ncolor = "%s"\nfg = "%s"' % ((v, n) + tuple(acc[v][n])))
    out.append('\n# roles for tools/libadwaita-gen.py')
    for v, R in roles.items():
        sec = S[v].get('adw', {}).get('secondary_sidebar') or (R['bg'] if v == 'dark' else mix(R['bg'], R['surface'], 0.5))
        wfg = R.get('warning_fg') or max([R['fg'], roles['dark']['bg_deep']], key=lambda c: contrast(c, R['yellow']))
        out.append('[roles.%s]' % v)
        for k in ('bg_deep', 'bg', 'surface', 'surface_high', 'popover', 'fg', 'red', 'green', 'yellow'):
            out.append('%s = "%s"' % (k, R[k]))
        out += ['accent = "%s"' % acc[v][dflt][0], 'accent_fg = "%s"' % R['accent_fg'], 'warning_fg = "%s"' % wfg, 'secondary_sidebar = "%s"' % sec]
    text = '\n'.join(out) + '\n'
    if '--check' in sys.argv: print(text)
    else: open(d + '/palette.toml', 'w').write(text); print('wrote %s/palette.toml%s' % (d, ' (' + '; '.join(notes) + ')' if notes else ''))

main()
