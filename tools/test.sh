#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Full test of the COMMITTED state of this repo (a fresh clone of HEAD, temp directories only, a stand-in gsettings,
# a local fake icon repo): lint, hygiene, regeneration, per-scheme selftest, install/switch/update/remove for every
# scheme and accent, and the icon recipes. Exits non-zero on any failure.
#   tools/test.sh [--rebuild] [scheme ...]      # default: every scheme; --rebuild rebuilds the test image
# Inside the container it needs git, just, python3 + python3-gobject, GTK 3, GTK 4, gnome-shell (St typelib) and a display
# (tools/test-packages.txt lists them; it re-executes itself under xvfb-run when there is no display).
# Isolation: the suite only runs inside a throwaway container. Run on a host, this script builds a cached test image from
# tools/test.Containerfile (rebuilt automatically when that file or test-packages.txt changes) and re-runs itself in it with the
# repo mounted read-only (podman or docker; CI already runs inside a container). Nothing on the host is touched.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ] && [ -z "${TEST_IN_CONTAINER:-}" ]; then
    rt=$(command -v podman || command -v docker) || { echo "tools/test.sh runs in a container: install podman or docker"; exit 2; }
    tag=$(cat "$root/tools/test.Containerfile" "$root/tools/test-packages.txt" | sha1sum | cut -c1-8)
    img="gnome-themes-test:45-$tag"
    args=(); for a in "$@"; do if [ "$a" = --rebuild ]; then "$rt" rmi -f "$img" >/dev/null 2>&1 || true; else args+=("$a"); fi; done
    if ! "$rt" image inspect "$img" >/dev/null 2>&1; then
        echo "building $img (first run downloads about 500 MB)"; "$rt" build -q -t "$img" -f "$root/tools/test.Containerfile" "$root/tools" >/dev/null || exit 2
    fi
    exec "$rt" run --rm --security-opt label=disable -e TEST_IN_CONTAINER=1 -v "$root":/src:ro "$img" /src/tools/test.sh "${args[@]}"
fi
if [ -n "${TEST_IN_CONTAINER:-}" ] || [ -f /run/.containerenv ] || [ -f /.dockerenv ]; then git config --global --add safe.directory '*' 2>/dev/null; fi
if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ -z "${TEST_UNDER_XVFB:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
    TEST_UNDER_XVFB=1 exec xvfb-run -a "$0" "$@"
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$1" = ok ]; then pass=$((pass+1)); echo "  PASS $2"; else fail=$((fail+1)); echo "  FAIL $2"; fi; }
git clone -q "$root" "$T/repo" && cd "$T/repo" || { echo "cannot clone $root"; exit 2; }
echo "testing $(git log --oneline -1)"

# ---- stand-ins ------------------------------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/cfg/gtk-3.0" "$T/cfg/gtk-4.0"; LOG="$T/gsettings.log"; : > "$LOG"
cat > "$T/bin/gsettings" <<SH
#!/bin/sh
case "\$1" in
  set) echo "set \$2 \$3 \$4" >> "$LOG" ;;
  get) case "\$3" in color-scheme) echo "'prefer-dark'";; accent-color) echo "'slate'";; gtk-theme) echo "'Adwaita'";; icon-theme) echo "'Adwaita'";; esac ;;
  list-schemas) echo org.gnome.shell.extensions.user-theme ;;
esac
SH
chmod +x "$T/bin/gsettings"
# a stand-in dconf over a plain file (DCONF_DB: lines "key<TAB>value"): read, write, list; every recipe that touches Ptyxis settings uses it
export DCONF_DB="$T/dconf.db"; : > "$DCONF_DB"
cat > "$T/bin/dconf" <<'SH'
#!/bin/sh
db="${DCONF_DB:?}"
case "$1" in
  read) awk -F'\t' -v k="$2" '$1==k {v=$2} END {if (v!="") print v}' "$db" ;;
  write) grep -v "^$2	" "$db" > "$db.new" || true; printf '%s\t%s\n' "$2" "$3" >> "$db.new"; mv "$db.new" "$db" ;;
  list) awk -F'\t' -v d="$2" 'index($1,d)==1 {print $1}' "$db" ;;
esac
SH
chmod +x "$T/bin/dconf"
export PTYXIS_PALETTES="$T/ptyxis-palettes" GTKSOURCEVIEW_STYLES="$T/gsv-styles" FLATPAK_APPS="$T/var-app"
export PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/cfg" XDG_STATE_HOME="$T/state" GNOME_THEMES_CACHE="$T/cache"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# a stand-in flatpak (FLATPAK_DB: the global override's filesystems, one entry per line); only the calls themectl makes. Absent unless a test
# puts $T/fpbin on the PATH, so the other tests behave like a machine without Flatpak
mkdir -p "$T/fpbin"; export FLATPAK_DB="$T/flatpak.db"; : > "$FLATPAK_DB"
cat > "$T/fpbin/flatpak" <<'SH'
#!/bin/sh
db="${FLATPAK_DB:?}"
if [ "$1" = info ]; then case " ${FLATPAK_INFO:-} " in *" $2 "*) exit 0 ;; esac; exit 1; fi
[ "$1" = override ] && [ "$2" = --user ] || exit 2
shift 2
for a in "$@"; do case "$a" in
  --show) printf '[Context]\nfilesystems=%s\n' "$(tr '\n' ';' < "$db")" ;;
  --filesystem=*) v="${a#--filesystem=}"; grep -qxF "$v" "$db" || echo "$v" >> "$db" ;;
  --nofilesystem=*) v="${a#--nofilesystem=}"; awk -v v="$v" '{p=$0; sub(/:[a-z]+$/,"",p)} p!=v' "$db" > "$db.new"; mv "$db.new" "$db" ;;
esac; done
SH
chmod +x "$T/fpbin/flatpak"
# a fake icon repo (two sets, each with an index.theme), so the icon tests need no network
mkdir -p "$T/icons-src" && (cd "$T/icons-src" && git init -q && for n in Fake-Dark Fake-Light; do mkdir -p $n/apps; printf '[Icon Theme]\nName=%s\nDirectories=apps\n' $n > $n/index.theme; echo x > $n/apps/a.svg; done && git add -A && git commit -q -m init)

# ---- lint and hygiene -----------------------------------------------------------------------------------------
echo "=== lint and hygiene"
for f in tools/*.sh; do bash -n "$f" && chk ok "bash -n $f" || chk fail "bash -n $f"; done
if command -v shellcheck >/dev/null 2>&1; then shellcheck -S warning tools/*.sh >/dev/null 2>&1 && chk ok "shellcheck (warning level)" || { chk fail "shellcheck"; shellcheck -S warning tools/*.sh | head -20; }; else echo "  skip shellcheck (not installed)"; fi
for f in tools/*.py; do python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" && chk ok "parses $f" || chk fail "parses $f"; done
just --dump >/dev/null 2>&1 && chk ok "justfile parses" || chk fail "justfile parses"
want="install-icons install-themes list-icons list-themes remove-icons remove-themes switch-icons switch-theme update-icons update-themes"
got=$(just --summary 2>/dev/null | tr ' ' '\n' | grep -v '^default$' | sort | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$want" ] && chk ok "public recipes are exactly the ten" || chk fail "public recipes differ: $got"
schemes=${*:-$(ls -d */palette.toml | cut -d/ -f1)}
for s in $schemes; do
    for d in $s/themes/*/; do [ -f "$d/LICENSE" ] && chk ok "$d has a LICENSE" || chk fail "$d has no LICENSE"; done
    while IFS= read -r f; do head -12 "$f" | grep -q "Licen[cs]e" && chk ok "licence line in $f" || chk fail "no licence line in header of $f"; done < <(find "$s/themes" -name '*.css' -not -path '*/assets/*' -not -name 'pad-osd.css')
    grep -q -i "$s" NOTICE && chk ok "NOTICE mentions $s" || chk fail "NOTICE does not mention $s"
done
[ -f LICENSE ] && grep -q "MIT License" LICENSE && chk ok "root LICENSE is MIT" || chk fail "root LICENSE"

# ---- per scheme -----------------------------------------------------------------------------------------------
for s in $schemes; do
    echo "=== $s"
    out=$(python3 -I tools/selftest.py "$s" all 2>&1); p=$(printf '%s\n' "$out" | grep -c '^PASS'); f=$(printf '%s\n' "$out" | grep -c '^FAIL')
    pass=$((pass+p)); fail=$((fail+f)); echo "  selftest: $p PASS, $f FAIL"; printf '%s\n' "$out" | grep '^FAIL' | head -5
    just generate "$s" >/dev/null 2>&1; d=$(git status --porcelain -- "$s" | grep -vc pycache)
    if [ "$d" -eq 0 ]; then chk ok "regeneration is byte-identical to the committed files"
    else chk fail "regeneration changed $d files (stock stylesheets drifted or a generated file was edited)"; git status --porcelain -- "$s" | head -3; git checkout -q -- "$s"; fi
    D="$T/themes-$s"; THEMES_DEST=$D just install-themes "$s" >/dev/null 2>&1
    n=$(ls "$D" 2>/dev/null | wc -l); [ "$n" -ge 1 ] && chk ok "install-themes: $n folders" || chk fail "install-themes produced nothing"
    for a in $(grep -v '^#' "$s/accents/list" | awk 'NF {print $1}'); do
        : > "$LOG"; THEMES_DEST=$D just switch-theme "$s" "$a" >/dev/null 2>&1; rc=$?
        [ $rc -eq 0 ] && [ "$(grep -c gtk-theme "$LOG")" -ge 1 ] && chk ok "switch-theme $s $a" || chk fail "switch-theme $s $a (rc=$rc)"
    done
    last=$(grep -v '^#' "$s/accents/list" | awk 'NF {print $1}' | tail -1); st=$(grep "^$s=" "$T/state/gnome-themes/accents" 2>/dev/null | cut -d= -f2)
    [ "$st" = "$last" ] && chk ok "accent remembered ($st)" || chk fail "accent state '$st' != '$last'"
    h1=$(find "$D" -type f -exec sha1sum {} + | sort | sha1sum); THEMES_DEST=$D just update-themes >/dev/null 2>&1; h2=$(find "$D" -type f -exec sha1sum {} + | sort | sha1sum)
    [ "$h1" = "$h2" ] && chk ok "update-themes keeps the remembered accent" || chk fail "update-themes changed the installed tree"
    THEMES_DEST=$D just remove-themes "$s" >/dev/null 2>&1; [ -z "$(ls -A "$D" 2>/dev/null)" ] && chk ok "remove-themes emptied the set" || chk fail "remove-themes left $(ls "$D" | tr '\n' ' ')"
done

# ---- collision guard (themes): unrelated folders with our names are never replaced or removed without asking ---------
echo "=== collision guard"
G="$T/guard-themes"; mkdir -p "$G/Dracula"; echo mine > "$G/Dracula/mine.txt"; printf '[Desktop Entry]\nName=Dracula\n' > "$G/Dracula/index.theme"
out=$(THEMES_DEST=$G just install-themes dracula </dev/null 2>&1); rc=$?
[ -f "$G/Dracula/mine.txt" ] && [ ! -f "$G/Dracula/.gnome-themes" ] && chk ok "install: unrelated folder of the same name left untouched" || chk fail "install replaced an unrelated Dracula"
printf '%s\n' "$out" | grep -q "not installed by gnome-themes" && [ $rc -eq 0 ] && chk ok "install: refusal message, other folders still handled (rc=$rc)" || chk fail "install: no refusal message or rc=$rc"
[ -f "$G/Dracula-Shell-Dark/.gnome-themes" ] && [ "$(cat "$G/Dracula-Shell-Dark/.gnome-themes")" = dracula ] && chk ok "install: the other folders were installed with the marker" || chk fail "install: marker missing on Dracula-Shell-Dark"
THEMES_DEST=$G just update-themes </dev/null >/dev/null 2>&1; [ -f "$G/Dracula/mine.txt" ] && chk ok "update: unrelated folder untouched" || chk fail "update replaced an unrelated Dracula"
THEMES_DEST=$G just remove-themes dracula </dev/null >/dev/null 2>&1
[ -f "$G/Dracula/mine.txt" ] && [ ! -e "$G/Dracula-Shell-Dark" ] && chk ok "remove: unrelated folder untouched, our folders removed" || chk fail "remove: wrong result ($(ls "$G" | tr '\n' ' '))"
FORCE=1 THEMES_DEST=$G just install-themes dracula </dev/null >/dev/null 2>&1
[ ! -e "$G/Dracula/mine.txt" ] && [ -f "$G/Dracula/.gnome-themes" ] && chk ok "FORCE=1 replaces the unrelated folder and marks it" || chk fail "FORCE=1 did not replace"
echo stale > "$G/Dracula/stale.txt"; out=$(THEMES_DEST=$G just install-themes dracula </dev/null 2>&1)
[ ! -e "$G/Dracula/stale.txt" ] && ! printf '%s\n' "$out" | grep -q "not installed by" && chk ok "a marked folder is replaced silently" || chk fail "marked folder not replaced silently"
L="$T/guard-legacy"; mkdir -p "$L"; cp -a dracula/themes/Dracula "$L/Dracula"; echo stale > "$L/Dracula/stale.txt"
out=$(THEMES_DEST=$L just install-themes dracula </dev/null 2>&1)
[ ! -e "$L/Dracula/stale.txt" ] && [ -f "$L/Dracula/.gnome-themes" ] && ! printf '%s\n' "$out" | grep -q "not installed by" && chk ok "a pre-marker installation (identical index.theme) is adopted" || chk fail "legacy installation not adopted"
if command -v script >/dev/null 2>&1; then
    I="$T/guard-ask"; mkdir -p "$I/Dracula"; echo mine > "$I/Dracula/mine.txt"
    printf 'n\n' | script -qec "THEMES_DEST=$I tools/themectl.sh themes install dracula" /dev/null >/dev/null 2>&1
    [ -f "$I/Dracula/mine.txt" ] && chk ok "interactive: answer n keeps the unrelated folder" || chk fail "interactive n replaced the folder"
    printf 'y\n' | script -qec "THEMES_DEST=$I tools/themectl.sh themes install dracula" /dev/null >/dev/null 2>&1
    [ ! -e "$I/Dracula/mine.txt" ] && chk ok "interactive: answer y replaces it" || chk fail "interactive y did not replace"
else echo "  skip interactive guard tests (script not installed)"; fi

# ---- Shell theme without the extension's gsettings schema (it is per user: gsettings does not list it) -----------------------
echo "=== shell theme via dconf"
first=$(echo $schemes | awk '{print $1}')
mkdir -p "$T/bin2"; DLOG="$T/dconf.log"; : > "$DLOG"
printf '#!/bin/sh\ncase "$1" in set) echo "set $2 $3 $4" >> "%s" ;; get) echo "\x27prefer-dark\x27" ;; list-schemas) : ;; esac\n' "$LOG" > "$T/bin2/gsettings"
printf '#!/bin/sh\n[ "$1" = write ] && echo "write $2 $3" >> "%s"\n' "$DLOG" > "$T/bin2/dconf"
chmod +x "$T/bin2/gsettings" "$T/bin2/dconf"
D="$T/themes-dconf"; PATH="$T/bin2:$PATH" THEMES_DEST=$D just install-themes "$first" >/dev/null 2>&1
PATH="$T/bin2:$PATH" THEMES_DEST=$D just switch-theme "$first" >/dev/null 2>&1
grep -q "write /org/gnome/shell/extensions/user-theme/name" "$DLOG" && chk ok "switch-theme writes the user-theme key with dconf when gsettings lacks the schema" || chk fail "switch-theme did not set the Shell theme (no dconf write)"

# ---- libadwaita file: no confirmation for our own files or when the backup of the original already exists ---------------------
echo "=== libadwaita file replacement"
first=$(echo $schemes | awk '{print $1}'); D="$T/themes-la"; CFGLA="$T/cfg-la"; mkdir -p "$CFGLA/gtk-4.0"; accs=$(grep -v '^#' "$first/accents/list" | awk 'NF {print $1}')
a1=$(echo "$accs" | sed -n 1p); a2=$(echo "$accs" | sed -n 2p)
THEMES_DEST=$D just install-themes "$first" >/dev/null 2>&1
sw() { XDG_CONFIG_HOME="$CFGLA" THEMES_DEST=$D just switch-theme "$first" "$1" 2>&1 </dev/null; }
sw "$a1" | grep -q "Installed $CFGLA/gtk-4.0/gtk.css" && chk ok "libadwaita file installed when absent" || chk fail "libadwaita file not installed when absent"
c1=$(sha1sum < "$CFGLA/gtk-4.0/gtk.css"); sw "$a2" | grep -q "Updated $CFGLA/gtk-4.0/gtk.css"; c2=$(sha1sum < "$CFGLA/gtk-4.0/gtk.css")
[ "$c1" != "$c2" ] && chk ok "our own libadwaita file is replaced without a prompt on an accent change" || chk fail "accent change did not replace our own libadwaita file"
echo "/* somebody else's stylesheet */" > "$CFGLA/gtk-4.0/gtk.css"; sw "$a1" | grep -q "left alone" && grep -q "somebody else" "$CFGLA/gtk-4.0/gtk.css" && chk ok "a foreign libadwaita file without a backup is left alone without a terminal" || chk fail "foreign libadwaita file was touched"
echo "/* original */" > "$CFGLA/gtk-4.0/gtk.css.bak"; sw "$a1" >/dev/null; { ! grep -q "somebody else" "$CFGLA/gtk-4.0/gtk.css" && grep -q "original" "$CFGLA/gtk-4.0/gtk.css.bak"; } && chk ok "with a backup present the file is replaced without a prompt and the backup is kept" || chk fail "backup case wrong"

# ---- Ptyxis palettes: generated files, install/switch/update/remove, collision guard, profile selection -----------------------
echo "=== ptyxis palettes"
cat > "$T/ptycheck.py" <<'PY'
import sys, re, glob, os
sys.path.insert(0, 'tools'); import schemeroles as sr
bad = []
for f in sorted(glob.glob('*/ptyxis/*.palette')):
    sec = {}; cur = None
    for l in open(f):
        l = l.strip()
        if not l or l.startswith('#'): continue
        m = re.match(r'\[(\w+)\]$', l)
        if m: cur = sec.setdefault(m[1], {}); continue
        k, v = l.split('=', 1); cur[k] = v
    if sec.get('Palette', {}).get('Name', '') == '': bad.append(f + ': no Name')
    for s in ('Light', 'Dark'):
        d = sec.get(s)
        if not d: bad.append('%s: no [%s]' % (f, s)); continue
        for k in ['Foreground', 'Background', 'TitlebarBackground', 'TitlebarForeground', 'Cursor'] + ['Color%d' % i for i in range(16)]:
            if not re.fullmatch(r'#[0-9A-Fa-f]{6}', d.get(k, '')): bad.append('%s [%s] %s=%r' % (f, s, k, d.get(k)))
        if d.get('Foreground') and d.get('Background') and sr.contrast(d['Foreground'], d['Background']) < 4.5: bad.append('%s [%s] contrast %.2f' % (f, s, sr.contrast(d['Foreground'], d['Background'])))
    if not open(f).read().rstrip().endswith('# gnome-themes: ' + f.split('/')[0]): bad.append(f + ': marker missing')
# every scheme declares `ptyxis` (+ reason); a generated palette file exists exactly for the schemes that declare `generated`
for p in sorted(glob.glob('*/scheme.toml')):
    d = os.path.dirname(p); S, _, _ = sr.load(d); choice = sr.ptyxis_choice(S)
    has = os.path.isfile('%s/ptyxis/gnome-themes-%s.palette' % (d, d))
    if not S.get('ptyxis_reason', '').strip(): bad.append(d + ': ptyxis_reason missing')
    if choice is None and not has: bad.append(d + ': declared generated but no palette file')
    if choice is not None and has: bad.append('%s: uses the built-in "%s" but a generated palette file is committed' % (d, choice))
print('\n'.join(bad)); sys.exit(1 if bad else 0)
PY
out=$(python3 -I "$T/ptycheck.py" 2>&1) && chk ok "every generated palette has Name, [Light] and [Dark] with all 16 colours and the 5 UI colours, Foreground:Background >= 4.5, marker; every scheme declares ptyxis with a reason and a palette file exists exactly for the generated ones" || { chk fail "palette check"; printf '%s\n' "$out" | head -5; }
if [ -r "${PTYXIS_BIN:-/usr/bin/ptyxis}" ]; then
    out=$(python3 -I tools/ptyxis-compare.py --check 2>&1) && chk ok "ptyxis-compare --check: the ptyxis declarations agree with the built-in palettes" || { chk fail "ptyxis declarations vs built-ins"; printf '%s\n' "$out" | head -5; }
else echo "  SKIP ptyxis-compare --check on the real built-ins (no Ptyxis binary here; the fixture test below covers the rules)"; fi
# regression: gruvbox-material against the hand-made reference (Kevin's working palette, 2026-11-07)
cat > "$T/gm.ref" <<'REF'
Dark Foreground #D4BE98
Dark Background #282828
Dark TitlebarBackground #45403d
Dark TitlebarForeground #D4BE98
Dark Cursor #D4BE98
Dark Color0 #3C3836
Dark Color1 #EA6962
Dark Color2 #A9B665
Dark Color3 #D8A657
Dark Color4 #7DAEA3
Dark Color5 #D3869B
Dark Color6 #89B482
Dark Color7 #D4BE98
Dark Color8 #3C3836
Dark Color9 #EA6962
Dark Color10 #A9B665
Dark Color11 #D8A657
Dark Color12 #7DAEA3
Dark Color13 #D3869B
Dark Color14 #89B482
Dark Color15 #D4BE98
Light Foreground #654735
Light Background #f5edca
Light TitlebarBackground #f9f5d7
Light TitlebarForeground #4f3829
Light Cursor #654735
Light Color0 #f2e5bc
Light Color1 #c14a4a
Light Color2 #6c782e
Light Color3 #b47109
Light Color4 #45707a
Light Color5 #945e80
Light Color6 #4c7a5d
Light Color7 #654735
Light Color8 #f2e5bc
Light Color9 #c14a4a
Light Color10 #6c782e
Light Color11 #b47109
Light Color12 #45707a
Light Color13 #945e80
Light Color14 #4c7a5d
Light Color15 #654735
REF
awk '/^\[/ {s=substr($0,2,length($0)-2); next} /=/ && s!="Palette" {split($0,a,"="); print s, a[1], a[2]}' gruvbox-material/ptyxis/gnome-themes-gruvbox-material.palette | sort > "$T/gm.got"
sort "$T/gm.ref" | tr 'A-F' 'a-f' | sed 's/^\(.\)/\1/' > "$T/gm.ref.s"; tr 'A-F' 'a-f' < "$T/gm.got" | sort > "$T/gm.got.s"
# lowercase only the hex values: keys and section names are compared after the same transformation on both sides
tr 'A-F' 'a-f' < "$T/gm.ref.s" | sort > "$T/gm.ref.s2"
diff -q "$T/gm.ref.s2" "$T/gm.got.s" >/dev/null && chk ok "gruvbox-material palette equals the reference (all 40 values: dark = the built-in Gruvbox Material, light has no built-in and keeps its own reference values listed in scheme.toml)" || { chk fail "gruvbox-material palette differs from the reference"; diff "$T/gm.ref.s2" "$T/gm.got.s" | head; }
# dconf db: three profiles; the default one (a) has no palette key, b has one, c has none
PD="$T/themes-pty"; : > "$DCONF_DB"
printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa', 'bbb', 'ccc']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" /org/gnome/Ptyxis/Profiles/bbb/palette "'Old'" /org/gnome/Ptyxis/Profiles/ccc/label "'x'" >> "$DCONF_DB"
rm -rf "$PTYXIS_PALETTES"; fname="$PTYXIS_PALETTES/gnome-themes-rose-pine.palette"
THEMES_DEST=$PD just install-themes rose-pine </dev/null >/dev/null 2>&1
[ -f "$fname" ] && grep -qx "# gnome-themes: rose-pine" "$fname" && chk ok "install-themes copies the palette with its marker" || chk fail "install-themes: palette missing"
THEMES_DEST=$PD just switch-theme rose-pine </dev/null >/dev/null 2>&1
nm=$(sed -n 's/^Name=//p' "$fname")
[ "$(dconf read /org/gnome/Ptyxis/Profiles/aaa/palette)" = "'$nm'" ] && [ "$(dconf read /org/gnome/Ptyxis/Profiles/bbb/palette)" = "'$nm'" ] && [ -z "$(dconf read /org/gnome/Ptyxis/Profiles/ccc/palette)" ] && chk ok "switch-theme: palette set on the default profile and the one that had a palette key, not on the other" || chk fail "profile selection rule ($(grep palette "$DCONF_DB" | tr '\t\n' '= '))"
echo "# stale" >> "$fname"; THEMES_DEST=$PD just update-themes </dev/null >/dev/null 2>&1
grep -q stale "$fname" && chk fail "update-themes did not refresh the palette" || chk ok "update-themes refreshes the palette"
THEMES_DEST=$PD just remove-themes rose-pine </dev/null >/dev/null 2>&1
[ ! -e "$fname" ] && chk ok "remove-themes removes the palette" || chk fail "remove-themes left the palette"
# collision: an unmarked file of the same name
mkdir -p "$PTYXIS_PALETTES"; echo mine > "$fname"
out=$(THEMES_DEST=$PD just install-themes rose-pine </dev/null 2>&1)
[ "$(cat "$fname")" = mine ] && printf '%s\n' "$out" | grep -q "not installed by gnome-themes" && chk ok "an unmarked palette of the same name is not replaced (refusal message)" || chk fail "collision: palette replaced"
: > "$DCONF_DB"; printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" >> "$DCONF_DB"
THEMES_DEST=$PD just switch-theme rose-pine </dev/null 2>&1 | grep -q "is not ours" && [ -z "$(dconf read /org/gnome/Ptyxis/Profiles/aaa/palette)" ] && chk ok "switch-theme does not apply a palette that is not ours" || chk fail "switch applied a foreign palette"
THEMES_DEST=$PD just remove-themes rose-pine </dev/null >/dev/null 2>&1; [ "$(cat "$fname")" = mine ] && chk ok "remove leaves the unmarked palette" || chk fail "remove deleted the unmarked palette"
FORCE=1 THEMES_DEST=$PD just install-themes rose-pine </dev/null >/dev/null 2>&1; grep -q "# gnome-themes:" "$fname" && chk ok "FORCE=1 replaces and marks the palette" || chk fail "FORCE=1 palette"
# no Ptyxis profile at all: a clear note, nothing written
: > "$DCONF_DB"; out=$(THEMES_DEST=$PD just switch-theme rose-pine </dev/null 2>&1)
printf '%s\n' "$out" | grep -q "no Ptyxis profile found" && ! grep -q Ptyxis "$DCONF_DB" && chk ok "no Ptyxis settings: note and skip" || chk fail "missing Ptyxis settings not handled"
THEMES_DEST=$PD just remove-themes rose-pine </dev/null >/dev/null 2>&1; rm -rf "$PTYXIS_PALETTES"
# a scheme that declares a Ptyxis built-in (everforest): install copies no palette file, switch-theme sets the built-in's NAME on the same profiles and says so,
# remove-themes leaves the palettes directory alone
mkdir -p "$PTYXIS_PALETTES"; echo other > "$PTYXIS_PALETTES/other.palette"
: > "$DCONF_DB"; printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa', 'bbb', 'ccc']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" /org/gnome/Ptyxis/Profiles/bbb/palette "'Old'" /org/gnome/Ptyxis/Profiles/ccc/label "'x'" >> "$DCONF_DB"
out=$(THEMES_DEST=$PD just install-themes everforest </dev/null 2>&1)
[ ! -e "$PTYXIS_PALETTES/gnome-themes-everforest.palette" ] && printf '%s\n' "$out" | grep -q 'built-in palette "Everforest"' && chk ok "install-themes copies no palette for a scheme that uses a Ptyxis built-in" || chk fail "built-in scheme: a palette file was installed or no note"
out=$(THEMES_DEST=$PD just switch-theme everforest </dev/null 2>&1)
[ "$(dconf read /org/gnome/Ptyxis/Profiles/aaa/palette)" = "'Everforest'" ] && [ "$(dconf read /org/gnome/Ptyxis/Profiles/bbb/palette)" = "'Everforest'" ] && [ -z "$(dconf read /org/gnome/Ptyxis/Profiles/ccc/palette)" ] && printf '%s\n' "$out" | grep -q 'Ptyxis palette is now "Everforest" (Ptyxis built-in' && chk ok "switch-theme sets the built-in's name on the default and the palette-keyed profile and prints it" || chk fail "built-in switch ($(grep palette "$DCONF_DB" | tr '\t\n' '= '))"
THEMES_DEST=$PD just remove-themes everforest </dev/null >/dev/null 2>&1
[ "$(cat "$PTYXIS_PALETTES/other.palette")" = other ] && [ "$(ls "$PTYXIS_PALETTES" | wc -l)" = 1 ] && chk ok "remove-themes does not touch the palettes directory for a built-in scheme" || chk fail "remove-themes touched palettes of a built-in scheme"
rm -rf "$PTYXIS_PALETTES"

# ---- GtkSourceView style schemes: generated files, install/switch/update/remove, Flatpak editors, collision guard ------------------
echo "=== gtksourceview styles"
cat > "$T/gsvcheck.py" <<'PY'
import sys, re, glob, os, xml.etree.ElementTree as ET
sys.path.insert(0, 'tools'); import schemeroles as sr
bad = []
for f in sorted(glob.glob('*/gtksourceview/*.xml')):
    scheme = f.split('/')[0]
    try: root = ET.parse(f).getroot()
    except ET.ParseError as e: bad.append('%s: %s' % (f, e)); continue
    sid = root.get('id'); name = root.get('_name') or root.get('name')
    if sid != os.path.basename(f)[:-4] or not re.fullmatch(r'([a-zA-Z0-9_]|-)+', sid) or not name: bad.append(f + ': id/name')
    if 'gnome-themes: ' + scheme not in open(f).read(): bad.append(f + ': marker')
    cols = {c.get('name'): c.get('value') for c in root.iter('color')}
    meta = {p.get('name'): p.text for p in root.iter('property')}
    if meta.get('variant') not in ('dark', 'light'): bad.append(f + ': variant')
    for k in ('light-variant', 'dark-variant'):
        if k in meta and not os.path.exists('%s/gtksourceview/%s.xml' % (scheme, meta[k])): bad.append('%s: %s %s does not resolve' % (f, k, meta[k]))
    def val(v): return cols.get(v) if not v.startswith('#') else v
    B, CL = val('bg-deep'), val('bg')
    for s in root.iter('style'):
        for a in ('foreground', 'background', 'line-background'):
            v = s.get(a)
            if v is not None and val(v) is None: bad.append('%s: style %s %s=%s does not resolve' % (f, s.get('name'), a, v))
        fg = s.get('foreground')
        if fg is None or s.get('name') in ('selection',): continue
        need = 3.0 if s.get('name') in ('def:comment', 'def:shebang') else 4.5
        bgs = [val(s.get('background'))] if s.get('background') and s.get('name') not in ('current-line-number',) else [B, CL]
        if s.get('name') in ('search-match', 'bracket-match', 'bracket-mismatch'): bgs = [val(s.get('background'))]
        for b in bgs:
            if sr.contrast(val(fg), b) < need - 0.01: bad.append('%s: %s %.2f < %.1f on %s' % (f, s.get('name'), sr.contrast(val(fg), b), need, b))
    if sr.contrast(cols['fg'], cols['selection']) < 4.5: bad.append(f + ': fg on selection')
print('\n'.join(bad[:15])); sys.exit(1 if bad else 0)
PY
out=$(python3 -I "$T/gsvcheck.py" 2>&1) && chk ok "style schemes: XML parses, id = file name, markers, metadata and every colour reference resolve, syntax colours >= 4.5:1 (comments 3:1) on the editor background and current line, text on selection >= 4.5" || { chk fail "gtksourceview check"; printf '%s\n' "$out" | head -8; }
if python3 -c "import gi; gi.require_version('GtkSource','5')" 2>/dev/null; then
    out=$(python3 -I - <<'PY' 2>&1
import gi, glob, os; gi.require_version('GtkSource', '5'); from gi.repository import GtkSource
m = GtkSource.StyleSchemeManager.new(); m.set_search_path([os.path.abspath(d) for d in glob.glob('*/gtksourceview')])
miss = [os.path.basename(f)[:-4] for f in glob.glob('*/gtksourceview/*.xml') if not m.get_scheme(os.path.basename(f)[:-4])]
print(miss); raise SystemExit(1 if miss else 0)
PY
) && chk ok "GtkSourceView itself loads every generated style scheme" || { chk fail "GtkSourceView could not load: $out"; }
else echo "  skip GtkSourceView load test (typelib not installed)"; fi
rm -rf "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS"; PD="$T/themes-gsv"; : > "$DCONF_DB"; : > "$FLATPAK_DB"
printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa']" >> "$DCONF_DB"
mkdir -p "$FLATPAK_APPS/org.gnome.TextEditor"    # Text Editor: data dir exists; Builder: only known to flatpak
out=$(FLATPAK_INFO="org.gnome.Builder" PATH="$T/fpbin:$PATH" THEMES_DEST=$PD just install-themes gruvbox-material </dev/null 2>&1)
ids="gnome-themes-gruvbox-material-dark.xml gnome-themes-gruvbox-material-light.xml"; ok=1
for d in "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS/org.gnome.TextEditor/data/gtksourceview-5/styles" "$FLATPAK_APPS/org.gnome.Builder/data/gtksourceview-5/styles"; do for f in $ids; do [ -f "$d/$f" ] || ok=0; done; done
[ $ok = 1 ] && chk ok "install-themes copies the style schemes into the user dir and into the Flatpak editors' data dirs (Text Editor by dir, Builder via flatpak info)" || chk fail "gsv install ($(ls "$GTKSOURCEVIEW_STYLES" 2>&1 | tr '\n' ' '))"
out=$(FLATPAK_INFO="org.gnome.Builder" PATH="$T/fpbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1)
[ "$(dconf read /org/gnome/TextEditor/style-scheme)" = "'gnome-themes-gruvbox-material-dark'" ] && [ "$(dconf read /org/gnome/builder/editor/style-scheme-name)" = "'gnome-themes-gruvbox-material-dark'" ] && chk ok "switch-theme sets Text Editor and (Builder present) Builder to the -dark id while the desktop is dark" || chk fail "gsv switch dark ($(grep -E 'TextEditor|builder' "$DCONF_DB" | tr '\t\n' '= '))"
lbin="$T/bin-light"; mkdir -p "$lbin"; printf '#!/bin/sh\ncase "$1" in set) : ;; get) case "$3" in color-scheme) echo "\x27default\x27";; *) echo "\x27x\x27";; esac ;; list-schemas) echo org.gnome.shell.extensions.user-theme ;; esac\n' > "$lbin/gsettings"; chmod +x "$lbin/gsettings"
PATH="$lbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null >/dev/null 2>&1
[ "$(dconf read /org/gnome/TextEditor/style-scheme)" = "'gnome-themes-gruvbox-material-light'" ] && [ "$(dconf read /org/gnome/builder/editor/style-scheme-name)" = "'gnome-themes-gruvbox-material-dark'" ] && chk ok "light desktop: the -light id for Text Editor; Builder untouched when it is not installed" || chk fail "gsv switch light"
PATH="$lbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1 | grep -q "Builder not found" && chk ok "without Builder the skip is announced" || chk fail "no Builder note"
echo "<!-- stale -->" >> "$GTKSOURCEVIEW_STYLES/gnome-themes-gruvbox-material-dark.xml"; THEMES_DEST=$PD just update-themes </dev/null >/dev/null 2>&1
grep -q stale "$GTKSOURCEVIEW_STYLES/gnome-themes-gruvbox-material-dark.xml" && chk fail "update did not refresh the style scheme" || chk ok "update-themes refreshes the style schemes"
THEMES_DEST=$PD just remove-themes gruvbox-material </dev/null >/dev/null 2>&1
[ -z "$(find "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS/org.gnome.TextEditor" -type f 2>/dev/null)" ] && chk ok "remove-themes removes the style schemes everywhere" || chk fail "remove left style schemes: $(find "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS" -type f 2>&1 | tr "\n" " ")"
# collision: an unmarked file with our id is kept; dark-only scheme has only the dark id
mkdir -p "$GTKSOURCEVIEW_STYLES"; echo mine > "$GTKSOURCEVIEW_STYLES/gnome-themes-fairy-floss-dark.xml"
out=$(THEMES_DEST=$PD just install-themes fairy-floss </dev/null 2>&1)
[ "$(cat "$GTKSOURCEVIEW_STYLES/gnome-themes-fairy-floss-dark.xml")" = mine ] && printf '%s\n' "$out" | grep -q "not installed by gnome-themes" && chk ok "an unmarked style scheme file is not replaced" || chk fail "gsv collision"
rm -f "$GTKSOURCEVIEW_STYLES/gnome-themes-fairy-floss-dark.xml"; THEMES_DEST=$PD just install-themes fairy-floss </dev/null >/dev/null 2>&1
[ -f "$GTKSOURCEVIEW_STYLES/gnome-themes-fairy-floss-dark.xml" ] && [ ! -e "$GTKSOURCEVIEW_STYLES/gnome-themes-fairy-floss-light.xml" ] && chk ok "a dark-only scheme installs only its -dark style scheme" || chk fail "dark-only gsv"
THEMES_DEST=$PD just remove-themes fairy-floss </dev/null >/dev/null 2>&1; THEMES_DEST=$PD just remove-themes gruvbox-material </dev/null >/dev/null 2>&1; rm -rf "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS" "$PTYXIS_PALETTES"

# ---- new-scheme helpers: Ptyxis built-in reader and the draft scheme.toml writer (fixture binary, no real Ptyxis needed) ----------------
echo "=== new scheme from a Ptyxis palette"
col() { printf 'Background=%s\nForeground=%s\nCursor=%s\n' "$1" "$2" "$3"; for i in $(seq 0 15); do printf 'Color%d=#%02x%02x%02x\n' "$i" $((i*9+40)) $((255-i*8)) $((i*5+90)); done; }
{ printf 'junk\n(uuay)Fake Night.palette\n[Palette]\nName=Fake Night\n'; col '#101820' '#e0e0e0' '#ffffff'; printf '# generated\n(uuay)Fake Duo.palette\n[Palette]\nName=Fake Duo\nPrimary=true\n[Light]\n'; col '#fafafa' '#202020' '#202020'; printf '[Dark]\n'; col '#202030' '#d0d0e0' '#d0d0e0'; printf 'tail\n(uuay)Ros\xc3\xa9 Fake.palette\n[Palette]\nName=Ros\xc3\xa9 Fake\n'; col '#191724' '#e0def4' '#e0def4'; printf 'tail\n'; } > "$T/fake-ptyxis"
export PTYXIS_BIN="$T/fake-ptyxis"
[ "$(tools/ptyxis-palette.sh list | tr '\t\n' '= ')" = "Fake Night=flat Fake Duo=Light,Dark Rosé Fake=flat " ] && chk ok "ptyxis-palette.sh list: names and sections, including a non-ASCII name" || chk fail "ptyxis-palette.sh list: $(tools/ptyxis-palette.sh list | tr '\t\n' '= ')"
tools/ptyxis-palette.sh show "rosé fake" | grep -qx 'Name=Rosé Fake' && python3 -I tools/scheme-from-ptyxis.py zz-rose "Rosé Fake" >/dev/null 2>&1 && grep -q '^bg_deep = "#191724"' zz-rose/scheme.toml && chk ok "non-ASCII palette names work in ptyxis-palette.sh show and scheme-from-ptyxis" || chk fail "non-ASCII palette name (Rosé)"
rm -rf zz-rose
tools/ptyxis-palette.sh show "fake duo" | grep -q '^\[Dark\]' && tools/ptyxis-palette.sh show "Fake Night" | grep -q '^Color15=' && ! tools/ptyxis-palette.sh show "Fake Night" | grep -q Duo && chk ok "ptyxis-palette.sh show: case-insensitive, one palette, verbatim" || chk fail "ptyxis-palette.sh show"
tools/ptyxis-palette.sh show nothing >/dev/null 2>&1 && chk fail "show of an unknown name succeeded" || chk ok "ptyxis-palette.sh show: unknown name fails"
rm -rf zz-fake zz-duo zz-two
out=$(python3 -I tools/scheme-from-ptyxis.py zz-duo "Fake Duo" 2>&1)
python3 -I - <<'PY' && chk ok "scheme-from-ptyxis: a sectioned palette gives dark and light draft variants with the accents, bg_deep, fg, and the TODO list" || chk fail "draft scheme.toml wrong"
import tomllib
S = tomllib.load(open('zz-duo/scheme.toml', 'rb'))
assert S['title'] == 'Zz Duo' and S['gtk_name'] == 'Zz-Duo' and S['shell_name'] == 'Zz-Duo-Shell'
assert S['dark']['bg_deep'] == '#202030' and S['light']['bg_deep'] == '#fafafa' and S['dark']['fg'] == '#d0d0e0'
assert set(S['dark']['ansi']) == {'red', 'green', 'yellow', 'blue', 'magenta', 'cyan'}
assert S['dark']['ansi']['green'] == '#%02x%02x%02x' % (2 * 9 + 40, 255 - 16, 2 * 5 + 90)
assert 'terminal' in S['dark'] and S['dark']['terminal']['black'] == '#%02x%02x%02x' % (40, 255, 90)
assert open('zz-duo/scheme.toml').read().count('# TODO') >= 8
PY
printf '%s\n' "$out" | grep -q "default_accent: proposed" && chk ok "the TODO list is printed (default_accent proposal with its reason)" || chk fail "TODO list not printed"
python3 -I tools/palette-from-scheme.py zz-duo --check >/dev/null 2>&1 && chk ok "the draft derives a palette.toml (the pipeline accepts it)" || chk fail "palette-from-scheme.py rejects the draft"
out=$(python3 -I tools/scheme-from-ptyxis.py zz-duo "Fake Duo" 2>&1); rc=$?
[ $rc -ne 0 ] && printf '%s\n' "$out" | grep -q "refusing to overwrite" && chk ok "scheme-from-ptyxis refuses to overwrite an existing scheme" || chk fail "overwrite not refused"
python3 -I tools/scheme-from-ptyxis.py zz-fake "Fake Night" >/dev/null 2>&1; grep -q '^\[dark\]' zz-fake/scheme.toml && ! grep -q '^\[light\]' zz-fake/scheme.toml && grep -q "dark only" zz-fake/scheme.toml && chk ok "a flat dark palette gives a dark-only draft" || chk fail "flat palette draft"
python3 -I tools/scheme-from-ptyxis.py zz-two "Fake Night" "Fake Duo" >/dev/null 2>&1; grep -q '^bg_deep = "#fafafa"' zz-two/scheme.toml && grep -q '^bg_deep = "#101820"' zz-two/scheme.toml && chk ok "a second palette gives the light variant" || chk fail "light palette argument"
rm -rf zz-fake zz-duo zz-two; unset PTYXIS_BIN
# ptyxis-compare: a copy of everforest that declares a built-in qualifies only when the built-in (a fixture made from the scheme's own colours,
# with [Light] and [Dark] sections) matches within the threshold; a changed accent, or a flat fixture, makes the declaration false
mkdir zz-ef && cp everforest/scheme.toml zz-ef/
python3 -I - > "$T/fake-ever" <<'PY'
import sys, importlib.util; sys.path.insert(0, 'tools'); import schemeroles as sr
spec = importlib.util.spec_from_file_location('pg', 'tools/ptyxis-gen.py'); pg = importlib.util.module_from_spec(spec); spec.loader.exec_module(pg)
S, roles, slots = sr.load('zz-ef')
print('(uuay)x\n[Palette]\nName=Everforest\nPrimary=true')
for slot, variant in slots:
    c = pg.slot_colors(S, roles, variant); print('[%s]' % slot.capitalize())
    for k in pg.ORDER: print('%s=%s' % (k, c[k]))
PY
PTYXIS_BIN="$T/fake-ever" python3 -I tools/ptyxis-compare.py --check zz-ef >/dev/null 2>&1 && chk ok "ptyxis-compare --check: a declared built-in that matches (sectioned fixture) passes" || chk fail "ptyxis-compare: matching built-in rejected"
sed '0,/^Color1=/s/^Color1=.*/Color1=#00FF00/' "$T/fake-ever" > "$T/fake-ever-off"
out=$(PTYXIS_BIN="$T/fake-ever-off" python3 -I tools/ptyxis-compare.py --check zz-ef 2>&1); rc=$?
[ $rc -ne 0 ] && printf '%s\n' "$out" | grep -q 'does not qualify' && chk ok "ptyxis-compare --check: a built-in whose red differs is not accepted" || chk fail "ptyxis-compare: off built-in accepted"
sed -i 's/^ptyxis = .*/ptyxis = "generated"/' zz-ef/scheme.toml
out=$(PTYXIS_BIN="$T/fake-ever" python3 -I tools/ptyxis-compare.py --check zz-ef 2>&1); rc=$?
[ $rc -ne 0 ] && printf '%s\n' "$out" | grep -q 'declared generated but' && chk ok "ptyxis-compare --check: declaring generated while a built-in matches is flagged" || chk fail "ptyxis-compare: unneeded generated not flagged"
sed -i 's/^ptyxis = .*/ptyxis = "Everforest"/' zz-ef/scheme.toml
awk '/^\[Light\]$/ {skip=1; next} /^\[Dark\]$/ {skip=0; next} !skip {print}' "$T/fake-ever" > "$T/fake-ever-flat"   # only the dark colours, as a flat palette
out=$(PTYXIS_BIN="$T/fake-ever-flat" python3 -I tools/ptyxis-compare.py --check zz-ef 2>&1); rc=$?
[ $rc -ne 0 ] && printf '%s\n' "$out" | grep -q 'does not qualify' && chk ok "ptyxis-compare --check: a flat built-in does not qualify for a scheme with light and dark variants" || chk fail "ptyxis-compare: flat built-in accepted for a two-variant scheme"
# ptyxis-compare --check, the source rules: every variant names its source, and a colour may differ from it only as a listed, bounded nudge
cp everforest/scheme.toml zz-ef/scheme.toml
nud() {   # nud <fg hex> <extra nudge lines>: zz-ef/scheme.toml from everforest with the dark fg changed, then a [dark.nudge] table
    cp everforest/scheme.toml zz-ef/scheme.toml
    python3 -I - "$1" "$2" <<'PY'
import sys, re
t = open('zz-ef/scheme.toml', encoding='utf-8').read()
i = t.index('[dark]'); j = t.index('fg = ', i); k = t.index('\n', j)
t = t[:j] + 'fg = "%s"' % sys.argv[1] + t[k:]
if sys.argv[2]: t += '\n[dark.nudge]\n' + sys.argv[2] + '\n'
open('zz-ef/scheme.toml', 'w', encoding='utf-8').write(t)
PY
}
cchk() { PTYXIS_BIN="$T/fake-ever" python3 -I tools/ptyxis-compare.py --check zz-ef 2>&1; }
nud '#d6c9ad' ''
out=$(cchk); [ -n "$out" ] && printf '%s\n' "$out" | grep -q 'not listed in \[dark.nudge\]' && chk ok "ptyxis-compare --check: a colour that differs from its source and is not listed is flagged" || chk fail "ptyxis-compare: unlisted difference not flagged ($out)"
de=$(python3 -I - <<'PY'
import sys, importlib.util; sys.path.insert(0, 'tools')
spec = importlib.util.spec_from_file_location('pc', 'tools/ptyxis-compare.py'); pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)
print('%.2f' % pc.de('#d6c9ad', '#d3c6aa'))
PY
)
nud '#d6c9ad' "Foreground = { from = \"#d3c6aa\", to = \"#d6c9ad\", de = $de, why = \"fixture: contrast on the window\" }"
out=$(cchk); [ -z "$out" ] && chk ok "ptyxis-compare --check: a listed nudge (right from, to and delta E, with a reason) passes" || chk fail "ptyxis-compare: listed nudge rejected ($out)"
nud '#d6c9ad' "Foreground = { from = \"#d3c6aa\", to = \"#d6c9ad\", de = $de, why = \"x\" }"
out=$(cchk); printf '%s\n' "$out" | grep -q 'has no reason' && chk ok "ptyxis-compare --check: a nudge without a reason is flagged" || chk fail "ptyxis-compare: reasonless nudge accepted"
nud '#ffffff' "Foreground = { from = \"#d3c6aa\", to = \"#ffffff\", de = 21.0, why = \"fixture: far too big\" }"
out=$(cchk); printf '%s\n' "$out" | grep -q 'NUDGE_MAX' && chk ok "ptyxis-compare --check: a nudge above NUDGE_MAX is flagged" || chk fail "ptyxis-compare: oversized nudge accepted ($out)"
nud '#d3c6aa' "Foreground = { from = \"#d3c6aa\", to = \"#d3c6aa\", de = 0.0, why = \"fixture: stale entry\" }"
out=$(cchk); printf '%s\n' "$out" | grep -q 'stale' && chk ok "ptyxis-compare --check: a listed nudge for a colour that no longer differs is flagged (stale)" || chk fail "ptyxis-compare: stale nudge accepted ($out)"
cp everforest/scheme.toml zz-ef/scheme.toml; sed -i '/^source = /d' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'exactly one of source' && chk ok "ptyxis-compare --check: a variant without source or no_builtin is flagged" || chk fail "ptyxis-compare: missing source accepted ($out)"
cp everforest/scheme.toml zz-ef/scheme.toml
python3 -I - <<'PY' && chk ok "ptyxis-gen: a scheme that uses a built-in writes no file and removes a stale generated one" || chk fail "ptyxis-gen with a built-in"
import subprocess, os
d = 'zz-ef'; os.makedirs(d + '/ptyxis', exist_ok=True); f = d + '/ptyxis/gnome-themes-zz-ef.palette'
open(f, 'w').write('[Palette]\nName=x\n# gnome-themes: zz-ef\n')
r = subprocess.run(['python3', '-I', 'tools/ptyxis-gen.py', d], capture_output=True, text=True)
raise SystemExit(0 if r.returncode == 0 and not os.path.exists(f) and 'built-in palette "Everforest"' in r.stdout else 1)
PY
rm -rf zz-ef
just --summary 2>/dev/null | grep -q new-scheme && chk fail "new-scheme became a public recipe" || chk ok "new-scheme is private (public set unchanged)"
just --justfile justfile --working-directory . new-scheme 2>&1 | grep -qi "usage\|palette" && chk ok "the private recipe runs by name (the passthrough path)" || chk fail "private recipe not runnable by name"

# ---- icons (fake icon repo) -----------------------------------------------------------------------------------
echo "=== icons"
printf 'fake|file://%s/icons-src|top|\n' "$T" > "$T/sources.conf"
export ICON_SOURCES="$T/sources.conf" ICONS_DEST="$T/icons"
just list-icons 2>&1 | grep -q Fake-Dark && chk ok "list-icons shows the sets" || chk fail "list-icons"
just install-icons Fake-Dark >/dev/null 2>&1; [ -d "$ICONS_DEST/Fake-Dark" ] && chk ok "install-icons" || chk fail "install-icons"
: > "$LOG"; just switch-icons Fake-Dark >/dev/null 2>&1; grep -q "icon-theme Fake-Dark" "$LOG" && chk ok "switch-icons" || chk fail "switch-icons"
(cd "$T/icons-src" && echo y > Fake-Dark/apps/b.svg && git add -A && git commit -q -m more)
just update-icons >/dev/null 2>&1; [ -f "$ICONS_DEST/Fake-Dark/apps/b.svg" ] && chk ok "update-icons picks up the new upstream commit" || chk fail "update-icons"
just remove-icons Fake-Dark >/dev/null 2>&1; [ ! -d "$ICONS_DEST/Fake-Dark" ] && chk ok "remove-icons" || chk fail "remove-icons"

# collision guard (icons): an unrelated Fake-Light is left alone, a pre-marker copy of Fake-Dark is adopted
mkdir -p "$ICONS_DEST/Fake-Light"; echo mine > "$ICONS_DEST/Fake-Light/mine.txt"
just install-icons Fake-Light </dev/null >/dev/null 2>&1; just update-icons </dev/null >/dev/null 2>&1; just remove-icons Fake-Light </dev/null >/dev/null 2>&1
[ -f "$ICONS_DEST/Fake-Light/mine.txt" ] && chk ok "icons: unrelated folder untouched by install, update and remove" || chk fail "icons: unrelated Fake-Light was touched"
FORCE=1 just install-icons Fake-Light </dev/null >/dev/null 2>&1; [ ! -e "$ICONS_DEST/Fake-Light/mine.txt" ] && [ -f "$ICONS_DEST/Fake-Light/.gnome-themes" ] && chk ok "icons: FORCE=1 replaces and marks" || chk fail "icons: FORCE=1"
cp -a "$T/icons-src/Fake-Dark" "$ICONS_DEST/Fake-Dark"; rm -rf "$ICONS_DEST/Fake-Dark/.git"; echo stale > "$ICONS_DEST/Fake-Dark/stale.txt"
just install-icons Fake-Dark </dev/null >/dev/null 2>&1; [ ! -e "$ICONS_DEST/Fake-Dark/stale.txt" ] && [ -f "$ICONS_DEST/Fake-Dark/.gnome-themes" ] && chk ok "icons: a pre-marker installation is adopted" || chk fail "icons: legacy not adopted"
just remove-icons Fake-Dark </dev/null >/dev/null 2>&1; just remove-icons Fake-Light </dev/null >/dev/null 2>&1

# ---- Flatpak access: grant after a y, record only what was added, undo only that ------------------------------------------------
echo "=== flatpak access"
FS="$T/themes-fp"; FI="$T/icons-fp"; fpst="$XDG_STATE_HOME/gnome-themes/flatpak-overrides"; rm -f "$fpst"
export FP_PATH="$T/fpbin:$PATH"
fpshow() { sort "$FLATPAK_DB" | tr '\n' ' '; }
# without a terminal: nothing changes, the exact command is printed
: > "$FLATPAK_DB"
out=$(PATH="$FP_PATH" THEMES_DEST=$FS just install-themes fairy-floss </dev/null 2>&1; PATH="$FP_PATH" THEMES_DEST=$FS just switch-theme fairy-floss </dev/null 2>&1)
[ ! -s "$FLATPAK_DB" ] && [ ! -e "$fpst" ] && printf '%s\n' "$out" | grep -qF "flatpak override --user --filesystem=xdg-config/gtk-3.0:ro --filesystem=xdg-config/gtk-4.0:ro --filesystem=xdg-data/icons:ro --filesystem=~/.themes:ro" && chk ok "no terminal: sandbox untouched, exact command printed" || chk fail "no-terminal flatpak case"
if command -v script >/dev/null 2>&1; then
    # a pre-existing entry; answer n, then y
    : > "$FLATPAK_DB"; echo "xdg-config/gtk-4.0:ro" > "$FLATPAK_DB"
    printf 'n\n' | PATH="$FP_PATH" THEMES_DEST=$FS script -qec "tools/themectl.sh themes switch fairy-floss magenta" /dev/null > "$T/fp.out" 2>&1
    [ "$(fpshow)" = "xdg-config/gtk-4.0:ro " ] && [ ! -e "$fpst" ] && grep -q "Allow read-only access to these folders for all Flatpaks" "$T/fp.out" && chk ok "answer n: nothing granted or recorded; the prompt text" || chk fail "flatpak n case ($(fpshow))"
    printf 'y\n' | PATH="$FP_PATH" THEMES_DEST=$FS script -qec "tools/themectl.sh themes switch fairy-floss magenta" /dev/null >/dev/null 2>&1
    [ "$(fpshow)" = "xdg-config/gtk-3.0:ro xdg-config/gtk-4.0:ro xdg-data/icons:ro ~/.themes:ro " ] && chk ok "answer y: the missing entries were granted" || chk fail "flatpak y grant ($(fpshow))"
    [ "$(sort "$fpst" | tr '\n' ' ')" = "xdg-config/gtk-3.0:ro xdg-data/icons:ro ~/.themes:ro " ] && chk ok "only the entries gnome-themes added are recorded (the pre-existing one is not)" || chk fail "record: $(cat "$fpst" 2>/dev/null | tr '\n' ' ')"
    # a second switch finds nothing missing: no prompt
    printf 'y\n' | PATH="$FP_PATH" THEMES_DEST=$FS script -qec "tools/themectl.sh themes switch fairy-floss magenta" /dev/null > "$T/fp.out" 2>&1
    grep -q "Allow read-only access" "$T/fp.out" && chk fail "prompted although everything is granted" || chk ok "nothing missing: no prompt"
    # undo: install an icon set too; removing the themes alone keeps the record, removing the last set asks
    PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS just install-icons Fake-Dark </dev/null >/dev/null 2>&1
    printf 'y\n' | PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS script -qec "tools/themectl.sh themes remove fairy-floss" /dev/null > "$T/fp.out" 2>&1
    [ -s "$fpst" ] && ! grep -q "Remove the Flatpak read access" "$T/fp.out" && chk ok "removing the last theme while an icon set remains does not ask" || chk fail "undo asked too early"
    printf 'n\n' | PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS script -qec "tools/themectl.sh icons remove Fake-Dark" /dev/null > "$T/fp.out" 2>&1
    grep -q "Remove the Flatpak read access that gnome-themes added" "$T/fp.out" && [ -s "$fpst" ] && [ "$(fpshow)" = "xdg-config/gtk-3.0:ro xdg-config/gtk-4.0:ro xdg-data/icons:ro ~/.themes:ro " ] && chk ok "removing the last set asks; n keeps access and record" || chk fail "undo n case"
    PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS just install-icons Fake-Dark </dev/null >/dev/null 2>&1
    out=$(PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS just remove-icons Fake-Dark </dev/null 2>&1)
    printf '%s\n' "$out" | grep -qF "flatpak override --user --nofilesystem=xdg-config/gtk-3.0 --nofilesystem=xdg-data/icons --nofilesystem=~/.themes" && ! printf '%s\n' "$out" | grep -q "nofilesystem=xdg-config/gtk-4.0" && [ -s "$fpst" ] && chk ok "no terminal: the undo commands for exactly the recorded entries are printed, nothing removed" || chk fail "undo no-terminal case"
    PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS just install-icons Fake-Dark </dev/null >/dev/null 2>&1
    printf 'y\n' | PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS script -qec "tools/themectl.sh icons remove Fake-Dark" /dev/null >/dev/null 2>&1
    [ "$(fpshow)" = "xdg-config/gtk-4.0:ro " ] && [ ! -e "$fpst" ] && chk ok "answer y: exactly the recorded entries are removed (the pre-existing one stays), record cleared" || chk fail "undo y case ($(fpshow))"
else echo "  skip flatpak prompt tests (script not installed)"; fi
rm -rf "$FS" "$FI" "$fpst"; : > "$FLATPAK_DB"

# ---- checklist UI (pty): SPACE toggles, ENTER confirms, q cancels, preselection shown ---------------------------
echo "=== checklist (pty)"
cat > "$T/ptyrun.py" <<'PY'
import os, pty, select, sys, time, fcntl, termios, struct, re
keys = {'down': b'\x1b[B', 'up': b'\x1b[A', 'space': b' ', 'enter': b'\r', 'q': b'q', 'n': b'n', 'a': b'a', 'j': b'j'}
seq = sys.argv[1].split(','); cmd = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0: os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 140, 0, 0))
out = b''; i = 0; last = time.time(); t0 = last
while time.time() - t0 < 30:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: d = os.read(fd, 8192)
        except OSError: break
        if not d: break
        out += d; last = time.time()
    elif i < len(seq) and time.time() - last > 0.3:
        os.write(fd, keys[seq[i]]); i += 1; last = time.time()
    elif i >= len(seq) and time.time() - last > 5: break
# never wait forever for a child that is still reading the terminal: give it a moment, then kill it
import signal
try:
    done, _ = os.waitpid(pid, os.WNOHANG)
    if not done:
        time.sleep(1.0); done, _ = os.waitpid(pid, os.WNOHANG)
    if not done:
        os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
except ChildProcessError: pass
sys.stdout.write(re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', out.decode(errors='replace')))
PY
pty() { python3 -I "$T/ptyrun.py" "$@"; }
n_inst() { ls -d "$1"/*/ 2>/dev/null | wc -l; }
PD="$T/pty-themes"; mkdir -p "$PD"
out=$(THEMES_DEST=$PD pty q tools/themectl.sh themes install)
echo "$out" | grep -q '\[x\]' && chk ok "checklist shows the preselection" || chk fail "checklist preselection not shown"
echo "$out" | grep -q 'SPACE toggles' && chk ok "checklist hint says SPACE toggles" || chk fail "checklist hint"
[ "$(n_inst "$PD")" -eq 0 ] && echo "$out" | grep -q Cancelled && chk ok "q cancels, nothing installed" || chk fail "q did not cancel"
THEMES_DEST=$PD pty n,down,space,enter tools/themectl.sh themes install >/dev/null
first_sc=$(ls -d */palette.toml | sed -n 2p | cut -d/ -f1); gname=$(awk -F'"' '/^gtk_name/ {print $2}' "$first_sc/palette.toml")
[ -d "$PD/$gname" ] && chk ok "none, down, SPACE ticks one entry, ENTER installs it ($first_sc)" || chk fail "space did not tick the second entry"
PD2="$T/pty-themes2"; mkdir -p "$PD2"; THEMES_DEST=$PD2 pty enter tools/themectl.sh themes install >/dev/null
[ "$(n_inst "$PD2")" -gt 4 ] && chk ok "ENTER alone installs the preselected set (first run: every scheme)" || chk fail "enter alone installed $(n_inst "$PD2")"
out=$(THEMES_DEST=$PD pty down,enter tools/themectl.sh themes switch "$first_sc")
echo "$out" | grep -q 'current' && chk ok "accent submenu marks the current accent" || chk fail "accent submenu: no (current) mark"
grep -q "^$first_sc=" "$XDG_STATE_HOME/gnome-themes/accents" && chk ok "accent chosen in the submenu is remembered" || chk fail "accent not remembered"

echo; echo "TOTAL: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
