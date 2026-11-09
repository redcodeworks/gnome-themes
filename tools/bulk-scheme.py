#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Turn Ptyxis built-in palettes into gnome-themes schemes in bulk. tools/ptyxis-schemes.tsv is the source of truth.

  python3 -I tools/bulk-scheme.py inventory              # (re)write the TSV from the built-ins and the rules below; keeps built/excluded rows
  python3 -I tools/bulk-scheme.py build [name ...] [--limit N]   # build the `todo` rows (or the named ones): draft, finalize, generate, check
  python3 -I tools/bulk-scheme.py status                 # counts per status

TSV columns: scheme, dark_id, light_id, status (existing | todo | built | excluded), reason, origin.
  `dark_id` is the Ptyxis built-in id of the (first) palette, `light_id` the light partner of a flat pair ('-' when none; a built-in with
  [Light]/[Dark] sections needs only dark_id). `origin` is the URL the built-in's own header names ('-' when it names none).
Deterministic defaults replacing the TODO decisions of tools/scheme-from-ptyxis.py (documented in CLAUDE.md): derived orange, surface ladder,
selection, comment, purple = magenta stay DERIVED (the generated palette.toml says so); default_accent is the draft's proposal (best contrast
on bg_deep); no seventh accent; credit and ptyxis_reason are written from the built-in's id and header. A scheme that fails
tools/selftest.py or tools/ptyxis-compare.py --check is removed again and its row becomes `excluded` with the first failure as the reason.
"""
import sys, os, re, shutil, subprocess, unicodedata, importlib.util
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
def _load(name, f):
    s = importlib.util.spec_from_file_location(name, os.path.join(HERE, f)); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
pids = _load('ptyxis_ids', 'ptyxis-ids.py'); sfp = _load('scheme_from_ptyxis', 'scheme-from-ptyxis.py')
TSV = os.path.join(HERE, 'ptyxis-schemes.tsv')

# built-ins the 13 existing schemes already use (id -> existing scheme)
EXISTING = {'Catppuccin Mocha': 'catppuccin', 'Catppuccin Latte': 'catppuccin', 'dracula': 'dracula', 'Everforest': 'everforest',
            'Fairy Floss Dark': 'fairy-floss', 'Gruvbox Material': 'gruvbox-material', 'Material': 'material', 'Monokai Dark': 'monokai',
            'nord': 'nordic', 'Rosé Pine': 'rose-pine', 'Rosé Pine Dawn': 'rose-pine', 'solarized': 'solarized',
            'Sweet Eliverlara': 'sweet', 'Tokyo Night': 'tokyo-night', 'Tokyo Night Day': 'tokyo-night', 'Ubuntu': 'aubergine'}
# a flat dark + flat light built-in of one family become ONE scheme (name: dark id, light id)
PAIRS = {'homebrew': ('Homebrew', 'Homebrew Light'), 'tomorrow': ('Tomorrow Night', 'Tomorrow')}
# generic terminal presets and single-hue palettes: nothing to theme sensibly
GENERIC = {'campbell': 'generic terminal preset (Windows Terminal default)', 'gnome': 'generic terminal preset', 'gnome-high-contrast': 'generic terminal preset',
           'GNOME Legacy': 'generic terminal preset', 'linux': 'generic terminal preset (Linux console)', 'rxvt': 'generic terminal preset',
           'tango': 'generic terminal preset', 'xterm': 'generic terminal preset', 'Terminal Basic': 'generic terminal preset (macOS Basic)',
           'Powershell': 'generic terminal preset', 'Ibm3270': 'IBM 3270 mainframe preset, not a colour scheme',
           'Ibm 3270 (High Contrast)': 'IBM 3270 mainframe preset, not a colour scheme'}
for _m in ('Amber', 'Cyan', 'Green', 'Red', 'White', 'Yellow'): GENERIC['Mono ' + _m] = 'single-hue palette: the six accents cannot be told apart'

RENAME = {'Solarized': 'solarized-classic', 'Fairy Floss': 'fairy-floss-classic'}   # ids whose kebab name would clash with an existing scheme

def kebab(s):
    s = unicodedata.normalize('NFKD', s); s = ''.join(c for c in s if not unicodedata.combining(c))
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')

def origin_of(text):
    m = re.search(r'https?://[^\n]+', text); return m.group(0).strip().rstrip('.,)').replace(' ', '%20') if m else '-'

def read():
    rows = []
    if os.path.exists(TSV):
        for l in open(TSV, encoding='utf-8').read().splitlines()[1:]:
            if l.strip(): rows.append(l.split('\t'))
    return rows
def write(rows):
    with open(TSV, 'w', encoding='utf-8') as f:
        f.write('scheme\tdark_id\tlight_id\tstatus\treason\torigin\n')
        for r in sorted(rows, key=lambda r: r[0]): f.write('\t'.join(r) + '\n')

def inventory():
    old = {r[0]: r for r in read()}; rows = []; taken = set(); b = pids.builtins()
    paired = {i for p in PAIRS.values() for i in p}
    for name, (d, l) in PAIRS.items(): taken.add(d); taken.add(l)
    for i, n, sections, text in b:
        if i in paired: continue
        if i in EXISTING: rows.append([EXISTING[i], i, '-', 'existing', 'covered by the existing scheme', origin_of(text)]); continue
        if i in GENERIC: rows.append([kebab(i), i, '-', 'excluded', GENERIC[i], origin_of(text)]); continue
        nm = RENAME.get(i, kebab(i))
        rows.append([nm, i, '-', 'todo', '', origin_of(text)])
    byid = {i: t for i, n, s, t in b}
    for name, (d, l) in PAIRS.items(): rows.append([name, d, l, 'todo', '', origin_of(byid[d])])
    # merge: keep outcomes of earlier builds; existing-scheme rows collapse to one per scheme
    seen = {}
    out = []
    for r in rows:
        if r[3] == 'existing':
            if r[0] in seen: seen[r[0]][1] += ' + ' + r[1]; continue
            seen[r[0]] = r
        if r[0] in old and old[r[0]][3] in ('built', 'excluded') and r[3] == 'todo': r[3], r[4] = old[r[0]][3], old[r[0]][4]
        out.append(r)
    names = [r[0] for r in out]
    dup = {n for n in names if names.count(n) > 1 and n not in EXISTING.values()}
    if dup: sys.exit('name clashes: %s' % sorted(dup))
    write(out); status()

def status():
    c = {}
    for r in read(): c[r[3]] = c.get(r[3], 0) + 1
    print(' '.join('%s=%d' % kv for kv in sorted(c.items())), 'total=%d' % sum(c.values()))

def finalize(path, did, lid, origin):
    t = open(path, encoding='utf-8').read()
    t = re.sub(r'^# TODO.*\n', '', t, flags=re.M)
    t = re.sub(r' *# TODO.*$', '', t, flags=re.M); t = t.replace(' (TODO)', '')
    src = "Ptyxis built-in '%s'" % did + (" and '%s'" % lid if lid else '')
    org = ('origin named in the built-in\'s header: ' + origin) if origin != '-' else 'the built-in\'s header names no origin'
    t = t.replace('credit = "TODO credit line"', 'credit = "%s (colours of the %s; %s)"' % (sfp.title_of(os.path.basename(os.path.dirname(path))), src, org))
    both = 'serves both modes (one section-less built-in)' if not lid else 'dark and light are two built-ins'
    t = re.sub(r'ptyxis_reason = "TODO[^"]*"', 'ptyxis_reason = "the colours ARE the %s (bulk-built by tools/bulk-scheme.py)."' % src, t)
    t = re.sub(r'^# (?:DRAFT|Not finished).*\n', '', t, flags=re.M)
    hdr = ('# SPDX-License-Identifier: MIT\n# Built by tools/bulk-scheme.py from the %s. Orange, the surface ladder, selection, comment and purple are DERIVED (the generated\n'
           '# palette.toml says which); default_accent is the accent with the best contrast on bg_deep. %s.\n') % (src, org[0].upper() + org[1:])
    t = re.sub(r'\A# SPDX-License-Identifier: MIT\n', '', t)
    return hdr + t

def run(cmd, **kw): return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kw)

def build_one(r):
    name, did, lid = r[0], r[1], (r[2] if r[2] != '-' else None)
    d = os.path.join(ROOT, name)
    if os.path.exists(d): return False, 'directory exists'
    text, todo = sfp.build(d, did, lid)
    os.makedirs(d); open(os.path.join(d, 'scheme.toml'), 'w', encoding='utf-8').write(text)
    p = os.path.join(d, 'scheme.toml'); fin = finalize(p, did, lid, r[5]); open(p, 'w', encoding='utf-8').write(fin)
    res = run(['just', 'generate', name])
    if res.returncode: return False, 'generate failed: ' + ' | '.join((res.stdout + res.stderr).strip().splitlines()[-4:])[:300]
    res = run([sys.executable, '-I', 'tools/selftest.py', name], env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
    if res.returncode:
        bad = [l.strip() for l in (res.stdout + res.stderr).splitlines() if 'FAIL' in l and 'Warning' not in l]
        return False, 'selftest: ' + (bad[0] if bad else 'failed')[:200]
    res = run([sys.executable, '-I', 'tools/ptyxis-compare.py', '--check', name])
    if res.returncode: return False, 'ptyxis-compare: ' + ((res.stdout + res.stderr).strip().splitlines() or ['?'])[-1][:200]
    return True, ''

def build(args):
    limit = None; names = []
    i = 0
    while i < len(args):
        if args[i] == '--limit': limit = int(args[i + 1]); i += 2
        else: names.append(args[i]); i += 1
    rows = read(); n = 0
    for r in rows:
        if (names and r[0] not in names) or (not names and r[3] != 'todo') or r[3] in ('existing', 'built'): continue
        if limit is not None and n >= limit: break
        n += 1
        ok, why = build_one(r)
        if ok: r[3], r[4] = 'built', ''
        else:
            if why != 'directory exists': shutil.rmtree(os.path.join(ROOT, r[0]), ignore_errors=True)   # never delete a folder this run did not create
            r[3], r[4] = 'excluded', why
        print('%-32s %s %s' % (r[0], r[3], r[4])); write(rows)
    status()

if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or a[0] in ('-h', '--help'): sys.exit(__doc__)
    {'inventory': inventory, 'status': status}.get(a[0], lambda: build(a[1:]) if a[0] == 'build' else sys.exit(__doc__))()
