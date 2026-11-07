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
export PTYXIS_PALETTES="$T/ptyxis-palettes"
export PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/cfg" XDG_STATE_HOME="$T/state" GNOME_THEMES_CACHE="$T/cache"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# a stand-in flatpak (FLATPAK_DB: the global override's filesystems, one entry per line); only the calls themectl makes. Absent unless a test
# puts $T/fpbin on the PATH, so the other tests behave like a machine without Flatpak
mkdir -p "$T/fpbin"; export FLATPAK_DB="$T/flatpak.db"; : > "$FLATPAK_DB"
cat > "$T/fpbin/flatpak" <<'SH'
#!/bin/sh
db="${FLATPAK_DB:?}"; [ "$1" = override ] && [ "$2" = --user ] || exit 2
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
print('\n'.join(bad)); sys.exit(1 if bad else 0)
PY
out=$(python3 -I "$T/ptycheck.py" 2>&1) && chk ok "every palette has Name, [Light] and [Dark] with all 16 colours and the 5 UI colours, Foreground:Background >= 4.5, marker" || { chk fail "palette check"; printf '%s\n' "$out" | head -5; }
# regression: gruvbox-material against the hand-made reference (Kevin's working palette, 2026-11-07)
cat > "$T/gm.ref" <<'REF'
Dark Foreground #D4BE98
Dark Background #282828
Dark TitlebarBackground #45403d
Dark TitlebarForeground #ddc7a1
Dark Cursor #D4BE98
Dark Color0 #3C3836
Dark Color1 #EA6962
Dark Color2 #A9B665
Dark Color3 #D8A657
Dark Color4 #7DAEA3
Dark Color5 #D3869B
Dark Color6 #89B482
Dark Color7 #D4BE98
Dark Color8 #928374
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
diff -q "$T/gm.ref.s2" "$T/gm.got.s" >/dev/null && chk ok "gruvbox-material palette equals the reference (all 40 values; the dark Color8 comment, light background and light Color8 differences from the built-in are in scheme.toml)" || { chk fail "gruvbox-material palette differs from the reference"; diff "$T/gm.ref.s2" "$T/gm.got.s" | head; }
# dconf db: three profiles; the default one (a) has no palette key, b has one, c has none
PD="$T/themes-pty"; : > "$DCONF_DB"
printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa', 'bbb', 'ccc']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" /org/gnome/Ptyxis/Profiles/bbb/palette "'Old'" /org/gnome/Ptyxis/Profiles/ccc/label "'x'" >> "$DCONF_DB"
rm -rf "$PTYXIS_PALETTES"; fname="$PTYXIS_PALETTES/gnome-themes-fairy-floss.palette"
THEMES_DEST=$PD just install-themes fairy-floss </dev/null >/dev/null 2>&1
[ -f "$fname" ] && grep -qx "# gnome-themes: fairy-floss" "$fname" && chk ok "install-themes copies the palette with its marker" || chk fail "install-themes: palette missing"
THEMES_DEST=$PD just switch-theme fairy-floss </dev/null >/dev/null 2>&1
nm=$(sed -n 's/^Name=//p' "$fname")
[ "$(dconf read /org/gnome/Ptyxis/Profiles/aaa/palette)" = "'$nm'" ] && [ "$(dconf read /org/gnome/Ptyxis/Profiles/bbb/palette)" = "'$nm'" ] && [ -z "$(dconf read /org/gnome/Ptyxis/Profiles/ccc/palette)" ] && chk ok "switch-theme: palette set on the default profile and the one that had a palette key, not on the other" || chk fail "profile selection rule ($(grep palette "$DCONF_DB" | tr '\t\n' '= '))"
echo "# stale" >> "$fname"; THEMES_DEST=$PD just update-themes </dev/null >/dev/null 2>&1
grep -q stale "$fname" && chk fail "update-themes did not refresh the palette" || chk ok "update-themes refreshes the palette"
THEMES_DEST=$PD just remove-themes fairy-floss </dev/null >/dev/null 2>&1
[ ! -e "$fname" ] && chk ok "remove-themes removes the palette" || chk fail "remove-themes left the palette"
# collision: an unmarked file of the same name
mkdir -p "$PTYXIS_PALETTES"; echo mine > "$fname"
out=$(THEMES_DEST=$PD just install-themes fairy-floss </dev/null 2>&1)
[ "$(cat "$fname")" = mine ] && printf '%s\n' "$out" | grep -q "not installed by gnome-themes" && chk ok "an unmarked palette of the same name is not replaced (refusal message)" || chk fail "collision: palette replaced"
: > "$DCONF_DB"; printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" >> "$DCONF_DB"
THEMES_DEST=$PD just switch-theme fairy-floss </dev/null 2>&1 | grep -q "is not ours" && [ -z "$(dconf read /org/gnome/Ptyxis/Profiles/aaa/palette)" ] && chk ok "switch-theme does not apply a palette that is not ours" || chk fail "switch applied a foreign palette"
THEMES_DEST=$PD just remove-themes fairy-floss </dev/null >/dev/null 2>&1; [ "$(cat "$fname")" = mine ] && chk ok "remove leaves the unmarked palette" || chk fail "remove deleted the unmarked palette"
FORCE=1 THEMES_DEST=$PD just install-themes fairy-floss </dev/null >/dev/null 2>&1; grep -q "# gnome-themes:" "$fname" && chk ok "FORCE=1 replaces and marks the palette" || chk fail "FORCE=1 palette"
# no Ptyxis profile at all: a clear note, nothing written
: > "$DCONF_DB"; out=$(THEMES_DEST=$PD just switch-theme fairy-floss </dev/null 2>&1)
printf '%s\n' "$out" | grep -q "no Ptyxis profile found" && [ ! -s "$DCONF_DB" ] && chk ok "no Ptyxis settings: note and skip" || chk fail "missing Ptyxis settings not handled"
THEMES_DEST=$PD just remove-themes fairy-floss </dev/null >/dev/null 2>&1; rm -rf "$PTYXIS_PALETTES"

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
