#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare each scheme's terminal colours with the Ptyxis built-in palettes (checks the `ptyxis` / `ptyxis_light` ids in scheme.toml).

  python3 -I tools/ptyxis-compare.py [scheme ...]            # the table: every candidate built-in with its distance, declared ones marked
  python3 -I tools/ptyxis-compare.py --check [scheme ...]    # fail when a declared id or a source declaration contradicts the data
PTYXIS_BIN overrides the binary (see tools/ptyxis-ids.py).

THE TERMINAL IS A PTYXIS BUILT-IN, ALWAYS. Ptyxis keys a profile's `palette` setting by palette ID (the resource file name without
`.palette`, case-sensitive), never by display Name, and there are no generated palettes. A scheme declares `ptyxis = "<id>"`, and for a
scheme with a dark and a light variant whose built-ins are two separate flat palettes also `ptyxis_light = "<id>"` (switch-theme picks one by
the system colour scheme); a built-in with [Light] and [Dark] sections needs only `ptyxis`; a scheme whose light variant has no built-in keeps
the dark one for both modes (`ptyxis_reason` says so). `--check` verifies that every declared id exists in the Ptyxis binary (ids are
case-sensitive: `solarized` and `Solarized` are two palettes), that `ptyxis_light` is only used where it makes sense, and `ptyxis_reason` is set.

PRINCIPLE (source order): an OFFICIAL source (the scheme's own repo, tmTheme, terminal port) comes first, the Ptyxis built-in second, invented
values last. Every variant says where it comes from, in its [<variant>.terminal] table: `source = "<built-in id>"` (for a built-in with [Light]
and [Dark] sections the section of the variant is used, for two flat built-ins each variant names its own), `source = "official: <repo/url, date>"`
plus `builtin_differs = { name = "<built-in id>", de = <max delta E over the 18 colours>, note = "<why>" }` (`--check` recomputes de, 0.1 tolerance), or
`no_builtin = "<why>"` (no built-in exists for that variant; the scheme's own values stay).
The scheme's colours and the built-in the terminal really shows are NOT forced to be equal any more: the delta E is information (printed by the
table and, for the declared ids, by `--check` on stderr). What stays enforced: a listed nudge
    [<variant>.nudge]
    Foreground = { from = "<source value>", to = "<our value>", de = <delta E>, why = "<reason>" }
(a colour moved off its source because a contrast check of the GTK colours forces it) must be true: `from` the source's value, `to` the value in use,
`de` the CIE76 delta E between them (within 0.1), `why` a real reason, at most NUDGE_MAX; a nudge for a colour that no longer differs is stale.

Distance per colour = CIE76 delta E in CIELAB (D65); a variant's distance is the MAXIMUM over the colours compared.
  roles   the colours scheme.toml actually defines: Background, Foreground, Color1..6 (the six accents) and each of Color0, 7, 8, 9..14, 15 that a
          [<variant>.terminal] table sets.
  all18   all 18 colours (Background, Foreground, Color0..15), shown for information.
Cursor and titlebar are never compared. THRESHOLD marks a "close match" in the table (roles max delta E <= THRESHOLD; about 2.3 is a just
noticeable difference).
A dark-only scheme that declares a sectioned built-in shows that built-in's [Light] section under a light system colour scheme; scheme.toml must
say `ptyxis_light_section_accepted = true` (Nordic with Nord: a deliberate decision).
"""
import sys, os, re, glob, unicodedata
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # python3 -I does not add the script dir
import schemeroles as sr
import importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location('ptyxis_ids', os.path.join(HERE, 'ptyxis-ids.py'))
pids = importlib.util.module_from_spec(_s); _s.loader.exec_module(pids)

THRESHOLD = 3.0    # max CIE76 delta E over the roles; marks a "close match" in the table
NUDGE_MAX = 6.0    # max CIE76 delta E of one listed nudge (a colour moved off its source because a contrast check forces it); the single definition of "small"
KEYS = ['Background', 'Foreground'] + ['Color%d' % i for i in range(16)]
# built-in names that do not start with the scheme title (the Ubuntu terminal palette is Aubergine; Nordic is the Nord palette)
HINTS = {'aubergine': ['Ubuntu'], 'nordic': ['Nord']}
TERMINAL_KEYS = {'black': 'Color0', 'white': 'Color7', 'bright_black': 'Color8', 'bright_white': 'Color15',
                 **{'bright_' + n: 'Color%d' % (i + 9) for i, n in enumerate(sr.NAMES)}}

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

_cache = {}
def builtins():
    """{id: (Name, sections, text)} of the Ptyxis binary (PTYXIS_BIN)."""
    key = os.environ.get('PTYXIS_BIN')
    if key not in _cache: _cache[key] = {i: (n, s, t) for i, n, s, t in pids.builtins()}
    return _cache[key]

def builtin_set(pid, variant):
    """The colour set of built-in `pid` for the variant ('dark'|'light'): its own section, else the flat one; None when there is none."""
    if pid not in builtins(): return None
    sec = ini(builtins()[pid][2])
    for key in (variant.capitalize(), 'Palette'):
        if sec.get(key, {}).get('Color1'): return {k: v.upper() for k, v in sec[key].items()}
    return None

def candidates(scheme, title):
    """[(id, Name, sections)] of built-ins whose id or Name starts with the scheme title (or a HINT)."""
    stems = [norm(title)] + [norm(h) for h in HINTS.get(scheme, [])]
    return [(i, n, sec) for i, (n, sec, _) in sorted(builtins().items(), key=lambda kv: kv[1][0]) if any(norm(x).startswith(st) for st in stems for x in (i, n))]

def role_keys(S, variant):
    """The colours scheme.toml defines for the variant (see the header)."""
    T = S[variant].get('terminal', {})
    return ['Background', 'Foreground'] + ['Color%d' % i for i in range(1, 7)] + sorted((TERMINAL_KEYS[k] for k in T if k in TERMINAL_KEYS), key=lambda k: int(k[5:]))

def distance(S, roles, variant, pid):
    """(roles max dE, worst role colour, all18 max dE) of the scheme's `variant` against built-in `pid`, or None when it has no palette for it."""
    b = builtin_set(pid, variant)
    if not b: return None
    mine = sr.slot_colors(S, roles, variant)
    d = {k: de(mine[k], b[k]) for k in KEYS if k in b}
    rk = {k: d[k] for k in role_keys(S, variant) if k in d}
    return max(rk.values()), max(rk, key=rk.get), max(d.values())

def declared(scheme_dir):
    """[(variant, id, sections, roles max dE, worst, all18)] for the ids the scheme declares: dark -> `ptyxis`, light -> `ptyxis_light` (else `ptyxis`);
    a dark-only scheme has the dark row only."""
    S, roles, _ = sr.load(scheme_dir); dk, lt = sr.ptyxis_ids(S); rows = []
    for variant, pid in (('dark', dk), ('light', lt)):
        if variant not in S or pid not in builtins(): continue
        dist = distance(S, roles, variant, pid)
        if dist: rows.append((variant, pid, builtins()[pid][1], *dist))
    return rows

def compare(scheme_dir):
    """[(variant, id, Name, sections, roles max dE, worst, all18)] for every variant and candidate built-in."""
    S, roles, slots = sr.load(scheme_dir)
    scheme = os.path.basename(os.path.abspath(scheme_dir)); rows = []
    for slot, variant in slots:
        if slot == 'light' and variant == 'dark': continue   # dark-only scheme: the light slot is the dark variant
        for i, n, sec in candidates(scheme, S['title']):
            dist = distance(S, roles, variant, i)
            if dist: rows.append((variant, i, n, sec, *dist))
    return rows

def id_problems(scheme_dir):
    """Problems with the `ptyxis` / `ptyxis_light` / `ptyxis_reason` declarations of one scheme (see the header); [] when fine."""
    S, _, _ = sr.load(scheme_dir); scheme = os.path.basename(os.path.abspath(scheme_dir)); bad = []
    dk, lt = sr.ptyxis_ids(S); two = 'light' in S
    if not S.get('ptyxis_reason', '').strip(): bad.append('%s: ptyxis_reason missing' % scheme)
    for key, pid in (('ptyxis', dk), ('ptyxis_light', S.get('ptyxis_light'))):
        if pid is not None and pid not in builtins():
            alt = [i for i in builtins() if i.lower() == pid.lower()]
            bad.append('%s: %s = "%s" is not a Ptyxis built-in id%s (Ptyxis would fall back to its default palette)' % (scheme, key, pid, '; did you mean "%s"? ids are case-sensitive' % alt[0] if alt else ''))
    if bad: return bad
    if S.get('ptyxis_light') is not None:
        if not two: bad.append('%s: ptyxis_light is set but the scheme has no light variant' % scheme)
        if builtins()[dk][1] != 'flat': bad.append('%s: ptyxis_light is set but "%s" has [Light] and [Dark] sections and covers both modes' % (scheme, dk))
        if builtins()[lt][1] != 'flat': bad.append('%s: ptyxis_light "%s" must be a flat built-in' % (scheme, lt))
    if not two and builtins()[dk][1] != 'flat' and not S.get('ptyxis_light_section_accepted'):
        bad.append('%s: a sectioned built-in ("%s") on a dark-only scheme shows its [Light] section under a light system scheme; set ptyxis_light_section_accepted = true to accept that' % (scheme, dk))
    return bad

def terminal_problems(scheme_dir):
    """Problems with the `source` / `no_builtin` / `builtin_differs` / nudge declarations of one scheme (see the header); [] when fine."""
    S, roles, _ = sr.load(scheme_dir)
    scheme = os.path.basename(os.path.abspath(scheme_dir)); bad = []
    for v in [v for v in ('dark', 'light') if v in S]:
        T = S[v].get('terminal', {}); N = S[v].get('nudge', {}); src = str(T.get('source', '')).strip(); nob = str(T.get('no_builtin', '')).strip()
        who = '%s %s' % (scheme, v)
        if bool(src) == bool(nob): bad.append('%s: [%s.terminal] needs exactly one of source = "<built-in id>" or no_builtin = "<why>"' % (who, v)); continue
        if nob:
            if N: bad.append('%s: nudges listed but the variant has no built-in source' % who)
            continue
        mine = sr.slot_colors(S, roles, v)
        if src.startswith('official:'):
            # an official source wins over the built-in: the built-in is named with its measured distance (information)
            bd = T.get('builtin_differs')
            if not isinstance(bd, dict) or not bd.get('name') or len(str(bd.get('note', '')).strip()) < 10:
                bad.append('%s: an official source needs builtin_differs = { name, de, note } (the built-in it differs from, the delta E, why official wins)' % who); continue
            bb = builtin_set(bd['name'], v)
            if not bb: bad.append('%s: builtin_differs names "%s", which is not a Ptyxis built-in id with a %s palette' % (who, bd['name'], v)); continue
            d = max(de(mine[k], bb[k]) for k in KEYS if k in bb)
            if abs(bd.get('de', -1) - d) > 0.1: bad.append('%s: builtin_differs de %s is not the computed %.1f' % (who, bd.get('de'), d))
            for k, n in N.items():   # nudges are measured against the official value (`from`), which only scheme.toml knows
                if k not in KEYS or k not in mine: bad.append('%s: nudge key %s unknown' % (who, k)); continue
                if n.get('to', '').upper() != mine[k]: bad.append('%s: nudge %s: to %s is not the value in use %s' % (who, k, n.get('to'), mine[k]))
                nd = de(n.get('from', '#000000'), mine[k])
                if abs(n.get('de', -1) - nd) > 0.1: bad.append('%s: nudge %s: de %s is not the computed %.2f' % (who, k, n.get('de'), nd))
                if nd > NUDGE_MAX: bad.append('%s: nudge %s is %.2f dE, above NUDGE_MAX %.1f' % (who, k, nd, NUDGE_MAX))
                if len(str(n.get('why', '')).strip()) < 10: bad.append('%s: nudge %s has no reason' % (who, k))
            continue
        b = builtin_set(src, v)
        if not b: bad.append('%s: source "%s" is not a Ptyxis built-in id with a %s palette' % (who, src, v)); continue
        for k in KEYS:
            if k not in b or k not in mine: continue
            d = de(mine[k], b[k]); n = N.get(k)
            if n:
                if d <= 0.001: bad.append('%s: nudge %s is listed but %s equals the built-in (stale)' % (who, k, k)); continue
                if n.get('from', '').upper() != b[k]: bad.append('%s: nudge %s: from %s is not the built-in value %s' % (who, k, n.get('from'), b[k]))
                if n.get('to', '').upper() != mine[k]: bad.append('%s: nudge %s: to %s is not the value in use %s' % (who, k, n.get('to'), mine[k]))
                if abs(n.get('de', -1) - d) > 0.1: bad.append('%s: nudge %s: de %s is not the computed %.2f' % (who, k, n.get('de'), d))
                if d > NUDGE_MAX: bad.append('%s: nudge %s is %.2f dE, above NUDGE_MAX %.1f' % (who, k, d, NUDGE_MAX))
                if len(str(n.get('why', '')).strip()) < 10: bad.append('%s: nudge %s has no reason' % (who, k))
        for k in N:
            if k not in KEYS: bad.append('%s: nudge key %s is not one of %s' % (who, k, ', '.join(KEYS[:3]) + ' ...'))
    return bad

def main():
    root = os.path.join(HERE, '..')
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    schemes = args or sorted(os.path.basename(os.path.dirname(p)) for p in glob.glob(os.path.join(root, '*', 'scheme.toml')))
    path = lambda s: s if os.path.isdir(s) else os.path.join(root, s)
    sys.stdout.reconfigure(encoding='utf-8'); sys.stderr.reconfigure(encoding='utf-8')
    if '--check' in sys.argv:
        bad = []
        for s in schemes:
            p = path(s); prob = id_problems(p); bad += prob + terminal_problems(p)
            if not prob:
                for v, pid, sec, mx, w, a in declared(p):
                    print('info: %s %s -> built-in id "%s" (%s): roles max dE %.2f (%s), all18 %.2f' % (s, v, pid, sec, mx, w, a), file=sys.stderr)
        print('\n'.join(bad)); sys.exit(1 if bad else 0)
    print('close match = roles max delta E (CIE76) <= %.1f; "declared" marks the id scheme.toml names\n' % THRESHOLD)
    print('%-16s %-7s %-32s %-26s %-11s %7s %-9s %7s' % ('scheme', 'variant', 'id', 'Name', 'sections', 'roles', 'worst', 'all18'))
    for s in schemes:
        S, _, _ = sr.load(path(s)); dk, lt = sr.ptyxis_ids(S)
        rows = compare(path(s))
        if not rows: print('%-16s %-7s %s' % (s, '-', '(no built-in of that name)')); continue
        for v, i, n, sec, mx, w, a in rows:
            mark = 'declared' if i == (dk if v == 'dark' else lt) else ('close' if mx <= THRESHOLD else '')
            print('%-16s %-7s %-32s %-26s %-11s %7.2f %-9s %7.2f   %s' % (s, v, i, n, sec, mx, w, a, mark))

if __name__ == '__main__': main()
