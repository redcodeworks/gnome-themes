#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Write a DRAFT <scheme-dir>/scheme.toml from a Ptyxis built-in palette (the start of a new scheme; see .claude/skills/build-scheme).

  python3 -I tools/scheme-from-ptyxis.py <scheme-dir> <ptyxis-id> [<light-id>]

<ptyxis-id> is the ID of a built-in Ptyxis palette (`tools/ptyxis-ids.py list`; the id is what Ptyxis stores in a profile, case-sensitive, not the
display Name; PTYXIS_BIN overrides the binary) or the path of a palette INI file (then the draft says `no_builtin`). A palette with [Dark] / [Light]
sections gives both variants; a flat palette gives the dark variant (or the light one when its background is light and no light palette is
given); <light-id> adds a light variant from a second flat palette (the draft then also says `ptyxis_light`). Refuses to overwrite an existing
scheme.toml.

Mapping (nothing is invented without a mark): Background -> bg_deep, Foreground -> fg, Color1..6 -> red green yellow blue magenta cyan (the six
accents, [<variant>.ansi]), purple = magenta. Everything a palette cannot give is DERIVED and listed as a `# TODO`: orange (red and yellow mixed
50 %), selection (bg_deep 20 % towards fg), the surface ladder and fg_dim/comment (the fixed rules of palette-from-scheme.py), default_accent (the
accent with the best contrast on bg_deep, with the numbers as the reason), accent_fg (listed when an accent fails 4.5:1 with bg_deep ink),
dark-only or not, the credit/licence lines for NOTICE. Black, white, brights and cursor that differ from the defaults of
schemeroles.slot_colors are written to [<variant>.terminal], which always carries `source = "<id>"` (checked by tools/ptyxis-compare.py --check).
title, gtk_name and shell_name come from the directory name. The draft is not a finished scheme: resolve every TODO, then run `just generate <scheme>`.
"""
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # python3 -I does not add the script dir
import schemeroles as sr
import importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location('ptyxis_ids', os.path.join(HERE, 'ptyxis-ids.py'))
pids = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(pids)
NAMES = sr.NAMES

def parse_ini(text):
    sec, cur = {}, 'Palette'
    for l in text.splitlines():
        l = l.strip()
        m = re.match(r'\[(\w+)\]$', l)
        if m: cur = m[1]; sec.setdefault(cur, {}); continue
        if '=' in l and not l.startswith('#'):
            k, v = l.split('=', 1); sec.setdefault(cur, {})[k.strip()] = v.strip()
    return sec

def load_palette(ref):
    """(id or None, {section: {key: value}}) from a built-in id or a file path."""
    if os.path.isfile(ref): return None, parse_ini(open(ref, encoding='utf-8').read())
    for i, n, sections, text in pids.builtins():
        if i == ref: return i, parse_ini(text)
    sys.exit("no built-in palette with id '%s' (ids are case-sensitive; see tools/ptyxis-ids.py list) and no such file" % ref)

def variants_of(sec, want):
    """The colour set for variant `want` ('dark'|'light') of a parsed palette, or None."""
    for key in (want.capitalize(), 'Palette'):
        d = sec.get(key)
        if d and 'Color1' in d: return {k: v.lower() for k, v in d.items()}
    return None

def title_of(d): return ' '.join(w.capitalize() for w in d.split('-'))

def build(scheme_dir, ref, ref_light=None):
    d = os.path.basename(os.path.abspath(scheme_dir))
    name, sec = load_palette(ref)
    name = name or os.path.basename(ref)
    is_id = not os.path.isfile(ref)
    sets = {}
    if ref_light:
        lname, lsec = load_palette(ref_light); lname = lname or os.path.basename(ref_light)
        sets['dark'] = variants_of(sec, 'dark'); sets['light'] = variants_of(lsec, 'light')
        src = {'dark': name, 'light': lname}
    else:
        dk, lt = (variants_of(sec, v) if v.capitalize() in sec else None for v in ('dark', 'light'))
        if dk and lt: sets['dark'], sets['light'] = dk, lt
        else:
            flat = variants_of(sec, 'dark')
            sets['light' if flat and sr.pfs.lum(flat['Background']) > 0.5 else 'dark'] = flat
        src = {'dark': name, 'light': name}
    sets = {k: v for k, v in sets.items() if v}
    if not sets: sys.exit('the palette has no usable colour set (no Color1)')
    todo = []
    L = ['# SPDX-License-Identifier: MIT',
         '# DRAFT written by tools/scheme-from-ptyxis.py from the Ptyxis built-in palette id(s): %s. Not finished: resolve every TODO below (and delete the' % ', '.join(sorted(set(src[v] for v in sets))),
         '# TODO lines when done), then `just generate %s`. Roles the palette cannot give are DERIVED or INVENTED here and say so.' % d,
         '# TODO verify the palette against the scheme\'s official spec or repo (this draft only knows the Ptyxis copy, often a Gogh port).']
    if not is_id: todo.append('ptyxis: the palette is a file, not a built-in; add `ptyxis = "<id>"` of the built-in the terminal should show (tools/ptyxis-ids.py list) and `ptyxis_reason`')
    todo.append('credit: set `credit` and add the palette credit and licence to NOTICE (provenance notes in this header: verified vs invented values)')
    todo.append('orange: the palette has none; the orange role below is DERIVED (red and yellow mixed 50 %). Keep, replace with the scheme\'s own orange (then add a seventh `orange` accent in [<variant>.ansi]) or say it is derived')
    todo.append('surface ladder: bg, surface and surface_high are DERIVED by the fixed rules; set them when the palette defines steps')
    todo.append('fg_dim / comment: DERIVED; set comment to the scheme\'s real comment colour (the palette\'s Color8 is shown beside each variant)')
    todo.append('selection: DERIVED (bg_deep 20 % towards fg); use the scheme\'s own selection colour when it has one')
    todo.append('purple: set to magenta; use the scheme\'s own purple when it has one')
    dark_only = 'light' not in sets
    todo.append('dark-only or not: %s' % ('this draft is dark only (no [light] section); add a light variant when the scheme has an official one (then the GTK light slot is no longer the dark values)' if dark_only else 'both variants were taken from the palette(s); confirm the light one is official, not a Gogh invention'))
    body = []
    best = []
    for v in ('dark', 'light'):
        if v not in sets: continue
        p = sets[v]
        bg, fg = p['Background'], p['Foreground']
        acc = {n: p['Color%d' % (i + 1)] for i, n in enumerate(NAMES)}
        orange = sr.mix(acc['red'], acc['yellow'], 0.5)
        sel = sr.mix(bg, fg, 0.2)
        roles = ['[%s]' % v, 'bg_deep = "%s"' % bg, 'fg = "%s"' % fg, 'selection = "%s"   # DERIVED (TODO)' % sel]
        roles += ['%s = "%s"' % (n, acc[n]) for n in ('red',)] + ['orange = "%s"   # DERIVED (TODO)' % orange]
        roles += ['%s = "%s"' % (n, acc[n]) for n in ('yellow', 'green', 'cyan', 'blue', 'magenta')] + ['purple = "%s"   # = magenta (TODO)' % acc['magenta']]
        roles.append('# palette Color8 (bright black) = %s: a candidate for `comment`' % p.get('Color8', '?'))
        roles += ['[%s.ansi]' % v] + ['%s = "%s"' % (n, acc[n]) for n in NAMES]
        # terminal overrides: whatever differs from the generator defaults
        S = {'title': 't', v: {'bg_deep': bg, 'fg': fg, 'selection': sel, 'red': acc['red'], 'orange': orange, 'yellow': acc['yellow'], 'green': acc['green'],
                               'cyan': acc['cyan'], 'blue': acc['blue'], 'magenta': acc['magenta'], 'purple': acc['magenta'], 'ansi': acc, 'terminal': {}}}
        R, _ = sr.pfs.resolve(S)
        base = sr.slot_colors(S, R, v)
        term = []
        def diff(key, ck, val):
            if val and val.lower() != base[ck].lower(): term.append('%s = "%s"   # Ptyxis %s' % (key, val, ck))
        diff('cursor', 'Cursor', p.get('Cursor')); diff('black', 'Color0', p.get('Color0')); diff('white', 'Color7', p.get('Color7'))
        diff('bright_black', 'Color8', p.get('Color8'))
        for i, n in enumerate(NAMES): diff('bright_' + n, 'Color%d' % (i + 9), p.get('Color%d' % (i + 9)))
        eff7 = p.get('Color7') or base['Color7']      # slot_colors defaults bright_white to the (possibly overridden) white, not to fg
        if p.get('Color15') and p['Color15'].lower() != eff7.lower(): term.append('bright_white = "%s"   # Ptyxis Color15' % p['Color15'])
        # `source` is always written: the built-in is the source of truth (tools/ptyxis-compare.py --check compares against it); what differs from
        # the generator defaults is listed beside it. A palette that is a file, not a built-in, needs `no_builtin` instead (TODO)
        roles += ['[%s.terminal]' % v, ('source = "%s"   # Ptyxis built-in id' % src[v]) if is_id else 'no_builtin = "TODO the palette is a file, not a built-in: say why"'] + term
        body.append('\n'.join(roles))
        c = {n: sr.contrast(acc[n], bg) for n in NAMES}
        top = max(c, key=c.get); best.append((v, top, c[top]))
        if sr.contrast(fg, bg) < 4.5: todo.append('contrast: %s fg on bg_deep is below 4.5:1; fix the palette values' % v)
        weak = [n for n in NAMES if sr.contrast(bg, acc[n]) < 4.5]
        todo.append('accent_fg (%s): bg_deep text on %s is below 4.5:1; palette-from-scheme.py then picks a better ink per accent, check `just test %s`, or set accent_fg' % (v, ', '.join(weak), d) if weak else
                    'accent_fg (%s): every accent reaches 4.5:1 with bg_deep ink; no override needed (confirm)' % v)
    v0, top, cr = best[0]
    todo.append('default_accent: proposed "%s" (best contrast on bg_deep, %.1f:1 in the %s variant); confirm or choose the scheme\'s signature colour and give a one-line reason' % (top, cr, v0))
    L += ['# TODO list (decisions only a human or agent can make):'] + ['# TODO %s' % t for t in todo]
    L += ['title = "%s"' % title_of(d), 'gtk_name = "%s"' % title_of(d).replace(' ', '-'), 'shell_name = "%s-Shell"' % title_of(d).replace(' ', '-'),
          'credit = "TODO credit line"'] + (['ptyxis = "%s"' % src['dark' if 'dark' in sets else 'light']] + (['ptyxis_light = "%s"' % src['light']] if ref_light else []) + ['ptyxis_reason = "TODO one line: which built-in and why"'] if is_id else []) + ['default_accent = "%s"   # TODO reason' % top, '']
    return '\n'.join(L) + '\n' + '\n\n'.join(body) + '\n', todo

def main():
    if len(sys.argv) < 3 or sys.argv[1] in ('-h', '--help'): sys.exit(__doc__)
    d = sys.argv[1].rstrip('/'); out = os.path.join(d, 'scheme.toml')
    if os.path.exists(out): sys.exit('refusing to overwrite %s (an existing scheme); edit it by hand' % out)
    text, todo = build(d, sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    os.makedirs(d, exist_ok=True)
    with open(out, 'w') as f: f.write(text)
    print('wrote %s (DRAFT)\nTODO:' % out)
    for t in todo: print('  - ' + t)

if __name__ == '__main__': main()
