#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare each scheme's terminal colours with the Ptyxis built-in palette(s) of the same name (decides `ptyxis = ...` in scheme.toml).

  python3 -I tools/ptyxis-compare.py [scheme ...]            # the table
  python3 -I tools/ptyxis-compare.py --check [scheme ...]    # fail when a scheme's `ptyxis` declaration contradicts the data
PTYXIS_BIN overrides the binary (see tools/ptyxis-palette.sh).

For every scheme variant it prints the colour distance to each candidate built-in (names that start with the scheme title, plus HINTS). What is
compared are the colours the generator (tools/ptyxis-gen.py) would write for that variant, so scheme.toml's [<variant>.terminal] overrides count.
Distance per colour = CIE76 delta E in CIELAB (D65); a variant's distance is the MAXIMUM over the colours compared. 0.00 = identical.
  roles   the colours scheme.toml actually defines: Background, Foreground, Color1..6 (the six accents) and each of Color0, 7, 8, 9..14, 15 that a
          [<variant>.terminal] table sets. This decides. Colours the generator only fills with a default (Color7 = foreground, Color9..14 = the
          normal colour, ...) are not the scheme's own data, and a built-in's real white or brights would simply replace them.
  all18   all 18 colours (Background, Foreground, Color0..15), shown for information.
Cursor and titlebar are never compared (see below).

THRESHOLD (below) is the one place that defines a "close match": roles max delta E <= THRESHOLD. About 2.3 is a just noticeable difference, so 3
allows only rounding-level drift and a few units in one channel; anything visibly different (another shade of red, say) fails.

A built-in qualifies (`ptyxis = "<name>"` in scheme.toml) only when ALL of these hold:
  1. its roles distance is <= THRESHOLD for every variant the scheme has;
  2. the scheme has two variants: the built-in has [Light] and [Dark] sections, so it follows the system colour scheme. Two flat built-ins (Catppuccin
     Latte and Mocha) do not qualify: Ptyxis stores ONE palette name per profile, so a pair cannot follow light/dark; one flat built-in does not
     either (it would stay dark or light in the other mode);
  3. the scheme has one variant: the built-in is flat (a sectioned built-in switches to a light terminal under a light system setting, which a
     dark-only scheme never does: its GTK light slot is the dark values too).
The generated palette also carries a titlebar colour; flat built-ins have none (only 7 of the 244 built-ins define one), so a built-in never
reproduces it. `--check` verifies the declarations in scheme.toml (`ptyxis = "<built-in name>"` must qualify, `ptyxis = "generated"` must have
no qualifying built-in, `ptyxis_reason` is required) and needs the Ptyxis binary or PTYXIS_BIN.
"""
import sys, os, re, glob, subprocess, unicodedata
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # python3 -I does not add the script dir
import schemeroles as sr
import importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location('ptyxis_gen', os.path.join(HERE, 'ptyxis-gen.py'))
pg = importlib.util.module_from_spec(_s); _s.loader.exec_module(pg)

THRESHOLD = 3.0    # max CIE76 delta E over the roles; the single definition of "close match"
KEYS = ['Background', 'Foreground'] + ['Color%d' % i for i in range(16)]
# built-in names that do not start with the scheme title (the Ubuntu terminal palette is Aubergine; Nordic is the Nord palette)
HINTS = {'aubergine': ['Ubuntu'], 'nordic': ['Nord']}
TERMINAL_KEYS = {'black': 'Color0', 'white': 'Color7', 'bright_black': 'Color8', 'bright_white': 'Color15',
                 **{'bright_' + n: 'Color%d' % (i + 9) for i, n in enumerate(pg.NAMES)}}

def norm(s): return re.sub(r'[^a-z0-9]', '', unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode().lower())

def lab(h):
    r, g, b = [v / 255 for v in sr.hx(h)]
    f = lambda c: c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = f(r), f(g), f(b)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047; y = 0.2126 * r + 0.7152 * g + 0.0722 * b; z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    t = lambda v: v ** (1 / 3) if v > 216 / 24389 else (24389 / 27 * v + 16) / 116
    return 116 * t(y) - 16, 500 * (t(x) - t(y)), 200 * (t(y) - t(z))

def de(a, b): return sum((p - q) ** 2 for p, q in zip(lab(a), lab(b))) ** 0.5

def ini(text):
    sec, cur = {}, 'Palette'
    for l in text.splitlines():
        l = l.strip(); m = re.match(r'\[(\w+)\]$', l)
        if m: cur = m[1]; sec.setdefault(cur, {}); continue
        if '=' in l and not l.startswith('#'): k, v = l.split('=', 1); sec.setdefault(cur, {})[k.strip()] = v.strip()
    return sec

def tool(*a): return subprocess.run([os.path.join(HERE, 'ptyxis-palette.sh'), *a], capture_output=True, text=True, encoding='utf-8')

def builtins():
    r = tool('list')
    if r.returncode: sys.exit(r.stderr.strip())
    return [l.split('\t') for l in r.stdout.splitlines() if l]

def builtin_set(name, variant):
    """The colour set of built-in `name` for the variant ('dark'|'light'): its own section, else the flat one."""
    sec = ini(tool('show', name).stdout)
    for key in (variant.capitalize(), 'Palette'):
        if sec.get(key, {}).get('Color1'): return {k: v.upper() for k, v in sec[key].items()}
    return None

def candidates(scheme, title, names):
    stems = [norm(title)] + [norm(h) for h in HINTS.get(scheme, [])]
    out = []
    for n, sections in names:
        if any(norm(n).startswith(s) for s in stems) and n not in [o[0] for o in out]: out.append((n, sections))
    return out

def role_keys(S, variant):
    """The colours scheme.toml defines for the variant (see the header)."""
    T = S[variant].get('terminal', {})
    return ['Background', 'Foreground'] + ['Color%d' % i for i in range(1, 7)] + sorted((TERMINAL_KEYS[k] for k in T if k in TERMINAL_KEYS), key=lambda k: int(k[5:]))

def compare(scheme_dir):
    """[(variant, builtin, sections, roles max dE, roles worst colour, all18 max dE)] for every variant and candidate built-in."""
    S, roles, slots = sr.load(scheme_dir)
    scheme = os.path.basename(os.path.abspath(scheme_dir))
    names = builtins(); rows = []
    for slot, variant in slots:
        if slot == 'light' and variant == 'dark': continue   # dark-only scheme: the light slot is the dark variant
        mine = pg.slot_colors(S, roles, variant)
        for n, sections in candidates(scheme, S['title'], names):
            b = builtin_set(n, variant)
            if not b: continue
            d = {k: de(mine[k], b[k]) for k in KEYS if k in b}
            rk = {k: d[k] for k in role_keys(S, variant) if k in d}
            rows.append((variant, n, sections, max(rk.values()), max(rk, key=rk.get), max(d.values())))
    return rows

def qualifying(scheme_dir):
    """Built-in names that qualify for the scheme under rules 1-3 of the header."""
    S, roles, slots = sr.load(scheme_dir)
    variants = [v for v in ('dark', 'light') if v in S]
    rows = compare(scheme_dir); out = []
    for n, sections in {(r[1], r[2]) for r in rows}:
        mine = [r for r in rows if r[1] == n]
        if sorted(r[0] for r in mine) != sorted(variants) or any(r[3] > THRESHOLD for r in mine): continue
        if len(variants) == 2 and sections != 'Light,Dark': continue
        if len(variants) == 1 and sections != 'flat': continue
        out.append(n)
    return sorted(out)

def main():
    root = os.path.join(HERE, '..')
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    schemes = args or sorted(os.path.basename(os.path.dirname(p)) for p in glob.glob(os.path.join(root, '*', 'scheme.toml')))
    path = lambda s: s if os.path.isdir(s) else os.path.join(root, s)
    if '--check' in sys.argv:
        bad = []
        for s in schemes:
            S, _, _ = sr.load(path(s)); choice = sr.ptyxis_choice(S); q = qualifying(path(s))
            if choice is None and q: bad.append('%s: declared generated but %s qualifies' % (s, ', '.join(q)))
            if choice is not None and choice not in q: bad.append('%s: declared built-in "%s" does not qualify (qualifying: %s)' % (s, choice, ', '.join(q) or 'none'))
            if not S.get('ptyxis_reason', '').strip(): bad.append('%s: ptyxis_reason missing' % s)
        print('\n'.join(bad)); sys.exit(1 if bad else 0)
    print('close match = roles max delta E (CIE76) <= %.1f\n' % THRESHOLD)
    print('%-16s %-7s %-32s %-11s %7s %-9s %7s' % ('scheme', 'variant', 'built-in', 'sections', 'roles', 'worst', 'all18'))
    for s in schemes:
        rows = compare(path(s))
        if not rows: print('%-16s %-7s %s' % (s, '-', '(no built-in of that name)')); continue
        for v, n, sec, mx, w, a in rows:
            print('%-16s %-7s %-32s %-11s %7.2f %-9s %7.2f%s' % (s, v, n, sec, mx, w, a, '   close' if mx <= THRESHOLD else ''))

if __name__ == '__main__': main()
