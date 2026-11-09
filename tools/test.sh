#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Full test of the COMMITTED state of this repo (a fresh clone of HEAD, temp directories only, a stand-in gsettings,
# a local fake icon repo): lint, hygiene, regeneration, per-scheme selftest, install/switch/update/remove for every
# scheme and accent, and the icon recipes. Exits non-zero on any failure.
#   tools/test.sh [--rebuild] [--all] [--sample N] [scheme ...]
#     Hygiene, inventory and the scenario tests run for every scheme. Regeneration, selftest and the install/switch/update/remove loop (every accent)
#     run for the featured schemes (FEATURED_THEMES in tools/themectl.sh), the schemes that differ from origin/main (TEST_BASE overrides; capped at 15)
#     and N more (default 10) chosen from the commit hash, so every scheme is covered over time. --all runs everything for every scheme (CI: manual
#     dispatch only). Named schemes: everything for those only.
#     --rebuild rebuilds the test image.
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
want="install-icon install-theme list-icons list-themes remove-icon remove-theme switch-icon switch-theme update-icon update-theme"
got=$(just --summary 2>/dev/null | tr ' ' '\n' | grep -v '^default$' | sort | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$want" ] && chk ok "public recipes are exactly the ten" || chk fail "public recipes differ: $got"
full=0; nsample=10; named=()
while [ $# -gt 0 ]; do case "$1" in --all) full=1 ;; --sample) shift; nsample=${1:?--sample needs a number} ;; *) named+=("$1") ;; esac; shift; done
if [ "${TEST_ALL:-}" = 1 ]; then full=1; fi
# Coverage (CLAUDE.md, "CI time"): hygiene, inventory, scenario tests and ptyxis-compare always run for every scheme. Regeneration, selftest and the
# install/switch/update/remove loop with every accent run for ONE set: the featured schemes + the schemes changed against the base (origin/main;
# TEST_BASE overrides), capped at 15 (a deterministic hash sample above that) + a rotating slice (--sample N, default 10) chosen by hashing the
# commit SHA, so every scheme is covered over time. --all or TEST_ALL=1 (manual CI dispatch) runs everything for every scheme.
if [ ${#named[@]} -gt 0 ]; then schemes="${named[*]}"; loop_schemes="$schemes"; cheap_schemes="$schemes"
else
    schemes=$(ls -d */palette.toml | cut -d/ -f1)
    if [ "$full" -eq 1 ]; then loop_schemes="$schemes"; cheap_schemes="$schemes"; echo "coverage: every scheme (--all)"
    else
        feat=$(sed -n 's/^FEATURED_THEMES="${FEATURED_THEMES-\(.*\)}"$/\1/p' tools/themectl.sh)
        changed=$(git -C "$root" diff --name-only "${TEST_BASE:-origin/main}" HEAD 2>/dev/null | cut -d/ -f1 | sort -u | while read -r x; do [ -f "$x/palette.toml" ] && echo "$x"; done)
        sha=$(git rev-parse HEAD)
        pick() { for x in $schemes; do case " $feat " in *" $x "*) continue ;; esac; printf '%s %s\n' "$(printf '%s%s%s' "$1" "$sha" "$x" | sha1sum | cut -c1-12)" "$x"; done | sort | head -n "$2" | awk '{print $2}'; }
        nchg=$(echo $changed | wc -w)
        if [ "$nchg" -gt 15 ]; then changed=$(for x in $changed; do printf '%s %s\n' "$(printf 'chg%s%s' "$sha" "$x" | sha1sum | cut -c1-12)" "$x"; done | sort | head -n 15 | awk '{print $2}'); capped=" (a sample of 15 of $nchg changed schemes)"; else capped=""; fi
        cheap_schemes=$(for x in $feat $changed $(pick loop "$nsample"); do [ -f "$x/palette.toml" ] && echo "$x"; done | awk '!seen[$0]++')
        loop_schemes="$cheap_schemes"
        echo "coverage: featured + changed$capped + rotating slice of $nsample; every scheme with --all or the manual full CI run"
    fi
fi
echo "regeneration, selftest and the install/switch/update/remove loop run for $(echo $loop_schemes | wc -w) of $(echo $schemes | wc -w) schemes: $(echo $loop_schemes)"
for s in $schemes; do
    for d in $s/themes/*/; do [ -f "$d/LICENSE" ] && chk ok "$d has a LICENSE" || chk fail "$d has no LICENSE"; done
    while IFS= read -r f; do head -12 "$f" | grep -q "Licen[cs]e" && chk ok "licence line in $f" || chk fail "no licence line in header of $f"; done < <(find "$s/themes" -name '*.css' -not -path '*/assets/*' -not -name 'pad-osd.css')
    if grep -q -i "$s" NOTICE || { grep -q "^$s	" tools/ptyxis-schemes.tsv && grep -q "tools/ptyxis-schemes.tsv" NOTICE; }; then chk ok "NOTICE covers $s"; else chk fail "NOTICE does not cover $s"; fi
done
[ -f LICENSE ] && grep -q "MIT License" LICENSE && chk ok "root LICENSE is MIT" || chk fail "root LICENSE"

# ---- per scheme -----------------------------------------------------------------------------------------------
# selftest and regeneration of every scheme, in parallel (each scheme only touches its own folder); results are collected per scheme
cheap_one() {
    local s=$1 out p f d
    out=$(python3 -I tools/selftest.py "$s" all 2>&1); p=$(printf '%s\n' "$out" | grep -c '^PASS'); f=$(printf '%s\n' "$out" | grep -c '^FAIL')
    { echo "=== $s"; echo "  selftest: $p PASS, $f FAIL"; printf '%s\n' "$out" | grep '^FAIL' | head -5
      echo "COUNT $p $f"
      just generate "$s" >/dev/null 2>&1; d=$(git status --porcelain -- "$s" | grep -vc pycache)
      if [ "$d" -eq 0 ]; then echo "  PASS regeneration is byte-identical to the committed files ($s)"; echo "COUNT 1 0"
      else echo "  FAIL regeneration changed $d files of $s (stock stylesheets drifted or a generated file was edited)"; git status --porcelain -- "$s" | head -3; git checkout -q -- "$s"; echo "COUNT 0 1"; fi; } > "$T/cheap-$s.out"
}
export -f cheap_one; export T LOG GNOME_THEMES_SKIP_ASSETS=1   # assets are checked once below, not per scheme
mkdir -p "$T/cheap"
printf '%s\n' $cheap_schemes | xargs -P "${TEST_JOBS:-$(nproc)}" -I{} bash -c 'cheap_one {}'
for s in $cheap_schemes; do
    cat "$T/cheap-$s.out" | grep -v '^COUNT'
    while read -r _ p f; do pass=$((pass+p)); fail=$((fail+f)); done < <(grep '^COUNT' "$T/cheap-$s.out")
done
LT=$(mktemp -d -p /dev/shm 2>/dev/null) || LT="$T"   # installed copies of the loop live in memory when possible (hundreds of small files per install)
for s in $loop_schemes; do
    echo "=== loop $s"
    D="$LT/themes-$s"; THEMES_DEST=$D just install-theme "$s" >/dev/null 2>&1
    n=$(ls "$D" 2>/dev/null | wc -l); [ "$n" -ge 1 ] && chk ok "install-theme: $n folders" || chk fail "install-theme produced nothing"
    gt=$(awk -F'"' '/^gtk_name/ {print $2}' "$s/palette.toml")
    [ -f "$D/$gt/gtk-3.0/assets/check-symbolic.svg" ] && [ -f "$D/$gt/gtk-4.0/assets/check-symbolic.svg" ] && [ ! -L "$D/$gt/gtk-3.0/assets" ] && chk ok "installed theme is complete: real assets directories in gtk-3.0 and gtk-4.0" || chk fail "installed $gt lacks its assets"
    for a in $(grep -v '^#' "$s/accents/list" | awk 'NF {print $1}'); do
        : > "$LOG"; THEMES_DEST=$D just switch-theme "$s" "$a" >/dev/null 2>&1; rc=$?
        [ $rc -eq 0 ] && [ "$(grep -c gtk-theme "$LOG")" -ge 1 ] && chk ok "switch-theme $s $a" || chk fail "switch-theme $s $a (rc=$rc)"
    done
    last=$(grep -v '^#' "$s/accents/list" | awk 'NF {print $1}' | tail -1); st=$(grep "^$s=" "$T/state/gnome-themes/accents" 2>/dev/null | cut -d= -f2)
    [ "$st" = "$last" ] && chk ok "accent remembered ($st)" || chk fail "accent state '$st' != '$last'"
    h1=$(find "$D" -type f -exec sha1sum {} + | sort | sha1sum); THEMES_DEST=$D just update-theme >/dev/null 2>&1; h2=$(find "$D" -type f -exec sha1sum {} + | sort | sha1sum)
    [ "$h1" = "$h2" ] && chk ok "update-theme keeps the remembered accent" || chk fail "update-theme changed the installed tree"
    THEMES_DEST=$D just remove-theme "$s" >/dev/null 2>&1; [ -z "$(ls -A "$D" 2>/dev/null)" ] && chk ok "remove-theme emptied the set" || chk fail "remove-theme left $(ls "$D" | tr '\n' ' ')"
done
[ "$LT" != "$T" ] && rm -rf "${LT:?}"

# ---- shared assets: the repo stores GTK's stock assets once (assets/gtk-3.0, assets/gtk-4.0); installs copy them into each theme ---------
echo "=== shared assets"
python3 -I tools/assets-gen.py --check >/dev/null 2>&1 && chk ok "assets/ match the installed GTK's stock assets" || chk fail "assets/ differ from GTK's stock assets (run just generate)"
[ -z "$(ls -d */themes/*/gtk-*/assets 2>/dev/null)" ] && chk ok "no scheme carries its own copy of the assets" || chk fail "per-scheme assets directories exist"

# ---- every scheme: Ptyxis declarations and the inventory (tools/ptyxis-schemes.tsv) ----------------------------------------
echo "=== ptyxis-compare and inventory"
if [ ! -r "${PTYXIS_BIN:-/usr/bin/ptyxis}" ]; then echo "  SKIP ptyxis-compare --check (no Ptyxis binary here; run it locally)"
elif python3 -I tools/ptyxis-compare.py --check $schemes >/dev/null 2>&1; then chk ok "ptyxis-compare --check passes for every scheme"
else chk fail "ptyxis-compare --check failed ($(python3 -I tools/ptyxis-compare.py --check $schemes 2>&1 | grep -iv '^info' | head -3 | tr '\n' ' '))"
fi
inv=$(python3 -I - <<'PY'
import os, csv
rows = list(csv.reader(open('tools/ptyxis-schemes.tsv', encoding='utf-8'), delimiter='\t'))[1:]
have = {d for d in os.listdir('.') if os.path.exists(d + '/scheme.toml')}
ok = {r[0] for r in rows if r[3] in ('built', 'existing')}
bad = [d + ' not in the inventory as built/existing' for d in sorted(have - ok)] + [r[0] + ' listed built/existing but has no folder' for r in rows if r[3] in ('built', 'existing') and r[0] not in have] + [r[0] + ' excluded but has a folder' for r in rows if r[3] == 'excluded' and r[0] in have]
print('; '.join(bad))
PY
)
[ -z "$inv" ] && chk ok "tools/ptyxis-schemes.tsv matches the scheme folders" || chk fail "inventory: $inv"

# ---- featured themes come first in list-theme and the checklists ------------------------------------------------------------
echo "=== featured themes"
fl=$(THEMES_DEST="$T/feat" FEATURED_THEMES="dracula nordic nosuch" tools/themectl.sh themes list | head -2 | awk '{print $2}' | tr '\n' ' ')
[ "$fl" = "dracula nordic " ] && chk ok "FEATURED_THEMES order is the list order (a missing scheme is skipped)" || chk fail "featured order: $fl"
rest=$(THEMES_DEST="$T/feat" FEATURED_THEMES="dracula nordic" tools/themectl.sh themes list | sed 1,2d | awk '{print $1}' | grep -vc '★')
[ "$rest" -ge 1 ] && [ "$(THEMES_DEST="$T/feat" FEATURED_THEMES="dracula nordic" tools/themectl.sh themes list | sed 1,2d | awk '{print $1}' | LC_ALL=C sort -c 2>&1 | wc -l)" -eq 0 ] && chk ok "the other schemes follow alphabetically" || chk fail "rest not alphabetical"

# ---- light-only scheme (bluloco-light): gtk.css only, Shell-Light only, switch works under a dark desktop ----------------------------
echo "=== light-only scheme"
if [ -d bluloco-light ]; then
    LO="$T/themes-lo"; THEMES_DEST=$LO just install-theme bluloco-light >/dev/null 2>&1
    [ -f "$LO/Bluloco-Light/gtk-3.0/gtk.css" ] && [ ! -e "$LO/Bluloco-Light/gtk-3.0/gtk-dark.css" ] && [ -d "$LO/Bluloco-Light-Shell-Light" ] && [ ! -e "$LO/Bluloco-Light-Shell-Dark" ] && chk ok "a light-only scheme ships gtk.css and the Light Shell theme only" || chk fail "light-only layout ($(ls "$LO" | tr '\n' ' '))"
    : > "$LOG"; THEMES_DEST=$LO just switch-theme bluloco-light red >/dev/null 2>&1
    grep -q "Bluloco-Light-Shell-Light" "$LOG" "$DCONF_DB" 2>/dev/null && grep -q "gtk-theme Bluloco-Light" "$LOG" && chk ok "switch-theme sets the light-only Shell theme even when the desktop is dark" || chk fail "light-only switch ($(cat "$LOG" | tr '\n' ';'))"
    THEMES_DEST=$LO just remove-theme bluloco-light >/dev/null 2>&1
fi

# ---- built-in picker: scrolling in a small terminal (pty with a terminal emulator) ----------------------------------------------------
echo "=== picker scrolling"
SCROLL_THEMES="$T/scroll-themes"; mkdir -p "$SCROLL_THEMES"
THEMES_DEST=$SCROLL_THEMES python3 -I tools/pty-scroll-test.py 10 24 > "$T/scroll.out" 2>&1 && chk ok "built-in picker: the cursor row stays on screen and the window scrolls by at most one row per key (10 and 24 rows, filter, resize, Home/End/PgUp/PgDn)" || { chk fail "pty scroll test"; grep -B1 -A12 FAIL "$T/scroll.out" | head -30; }

# ---- collision guard (themes): unrelated folders with our names are never replaced or removed without asking ---------
echo "=== collision guard"
G="$T/guard-themes"; mkdir -p "$G/Dracula"; echo mine > "$G/Dracula/mine.txt"; printf '[Desktop Entry]\nName=Dracula\n' > "$G/Dracula/index.theme"
out=$(THEMES_DEST=$G just install-theme dracula </dev/null 2>&1); rc=$?
[ -f "$G/Dracula/mine.txt" ] && [ ! -f "$G/Dracula/.gnome-themes" ] && chk ok "install: unrelated folder of the same name left untouched" || chk fail "install replaced an unrelated Dracula"
printf '%s\n' "$out" | grep -q "not installed by gnome-themes" && [ $rc -eq 0 ] && chk ok "install: refusal message, other folders still handled (rc=$rc)" || chk fail "install: no refusal message or rc=$rc"
[ -f "$G/Dracula-Shell-Dark/.gnome-themes" ] && [ "$(cat "$G/Dracula-Shell-Dark/.gnome-themes")" = dracula ] && chk ok "install: the other folders were installed with the marker" || chk fail "install: marker missing on Dracula-Shell-Dark"
THEMES_DEST=$G just update-theme </dev/null >/dev/null 2>&1; [ -f "$G/Dracula/mine.txt" ] && chk ok "update: unrelated folder untouched" || chk fail "update replaced an unrelated Dracula"
THEMES_DEST=$G just remove-theme dracula </dev/null >/dev/null 2>&1
[ -f "$G/Dracula/mine.txt" ] && [ ! -e "$G/Dracula-Shell-Dark" ] && chk ok "remove: unrelated folder untouched, our folders removed" || chk fail "remove: wrong result ($(ls "$G" | tr '\n' ' '))"
FORCE=1 THEMES_DEST=$G just install-theme dracula </dev/null >/dev/null 2>&1
[ ! -e "$G/Dracula/mine.txt" ] && [ -f "$G/Dracula/.gnome-themes" ] && chk ok "FORCE=1 replaces the unrelated folder and marks it" || chk fail "FORCE=1 did not replace"
echo stale > "$G/Dracula/stale.txt"; out=$(THEMES_DEST=$G just install-theme dracula </dev/null 2>&1)
[ ! -e "$G/Dracula/stale.txt" ] && ! printf '%s\n' "$out" | grep -q "not installed by" && chk ok "a marked folder is replaced silently" || chk fail "marked folder not replaced silently"
L="$T/guard-legacy"; mkdir -p "$L"; cp -a dracula/themes/Dracula "$L/Dracula"; echo stale > "$L/Dracula/stale.txt"
out=$(THEMES_DEST=$L just install-theme dracula </dev/null 2>&1)
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
D="$T/themes-dconf"; PATH="$T/bin2:$PATH" THEMES_DEST=$D just install-theme "$first" >/dev/null 2>&1
PATH="$T/bin2:$PATH" THEMES_DEST=$D just switch-theme "$first" >/dev/null 2>&1
grep -q "write /org/gnome/shell/extensions/user-theme/name" "$DLOG" && chk ok "switch-theme writes the user-theme key with dconf when gsettings lacks the schema" || chk fail "switch-theme did not set the Shell theme (no dconf write)"

# ---- libadwaita file: no confirmation for our own files or when the backup of the original already exists ---------------------
echo "=== libadwaita file replacement"
first=$(echo $schemes | awk '{print $1}'); D="$T/themes-la"; CFGLA="$T/cfg-la"; mkdir -p "$CFGLA/gtk-4.0"; accs=$(grep -v '^#' "$first/accents/list" | awk 'NF {print $1}')
a1=$(echo "$accs" | sed -n 1p); a2=$(echo "$accs" | sed -n 2p)
THEMES_DEST=$D just install-theme "$first" >/dev/null 2>&1
sw() { XDG_CONFIG_HOME="$CFGLA" THEMES_DEST=$D just switch-theme "$first" "$1" 2>&1 </dev/null; }
sw "$a1" | grep -q "Installed $CFGLA/gtk-4.0/gtk.css" && chk ok "libadwaita file installed when absent" || chk fail "libadwaita file not installed when absent"
c1=$(sha1sum < "$CFGLA/gtk-4.0/gtk.css"); sw "$a2" | grep -q "Updated $CFGLA/gtk-4.0/gtk.css"; c2=$(sha1sum < "$CFGLA/gtk-4.0/gtk.css")
[ "$c1" != "$c2" ] && chk ok "our own libadwaita file is replaced without a prompt on an accent change" || chk fail "accent change did not replace our own libadwaita file"
echo "/* somebody else's stylesheet */" > "$CFGLA/gtk-4.0/gtk.css"; sw "$a1" | grep -q "left alone" && grep -q "somebody else" "$CFGLA/gtk-4.0/gtk.css" && chk ok "a foreign libadwaita file without a backup is left alone without a terminal" || chk fail "foreign libadwaita file was touched"
echo "/* original */" > "$CFGLA/gtk-4.0/gtk.css.bak"; sw "$a1" >/dev/null; { ! grep -q "somebody else" "$CFGLA/gtk-4.0/gtk.css" && grep -q "original" "$CFGLA/gtk-4.0/gtk.css.bak"; } && chk ok "with a backup present the file is replaced without a prompt and the backup is kept" || chk fail "backup case wrong"

# ---- Ptyxis palettes: ids only (no generated palettes), switch-theme writes the id, cleanup of old marked files -----------------
echo "=== ptyxis palette ids"
[ -z "$(ls -d */ptyxis 2>/dev/null)" ] && ! grep -rlq 'ptyxis = "generated"' --include=scheme.toml . && [ ! -e tools/ptyxis-gen.py ] && chk ok "no generated Ptyxis palettes are left (no */ptyxis directories, no generator, no scheme declares generated)" || chk fail "generated palette leftovers"
if [ -r "${PTYXIS_BIN:-/usr/bin/ptyxis}" ]; then
    out=$(python3 -I tools/ptyxis-compare.py --check 2>/dev/null) && chk ok "ptyxis-compare --check: every declared id exists in the Ptyxis binary and the source declarations hold" || { chk fail "ptyxis ids vs built-ins"; printf '%s\n' "$out" | head -5; }
else echo "  SKIP ptyxis-compare --check on the real built-ins (no Ptyxis binary here; the fixture tests below cover the rules)"; fi
# fixture built-ins (a directory of <id>.palette files is accepted as PTYXIS_BIN): ids differ from names and in case
FIX="$T/pty-ids"; mkdir -p "$FIX"
for i in nord "Everforest" "Catppuccin Mocha" "Catppuccin Latte"; do printf '[Palette]\nName=Name of %s\n' "$i" > "$FIX/$i.palette"; done
# dconf db: three profiles; the default one (a) has no palette key, b has one, c has none
PD="$T/themes-pty"; : > "$DCONF_DB"
printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa', 'bbb', 'ccc']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" /org/gnome/Ptyxis/Profiles/bbb/palette "'Old'" /org/gnome/Ptyxis/Profiles/ccc/label "'x'" >> "$DCONF_DB"
# old generated files carry our marker; Kevin's own palette does not (it even mentions gnome-themes in a comment)
rm -rf "$PTYXIS_PALETTES"; mkdir -p "$PTYXIS_PALETTES"
mkold() { printf '[Palette]\nName=Old (GNOME Themes)\n# gnome-themes: rose-pine\n' > "$PTYXIS_PALETTES/gnome-themes-rose-pine.palette"; printf '[Palette]\nName=Old\n# gnome-themes: sweet\n' > "$PTYXIS_PALETTES/gnome-themes-sweet.palette"; }
printf '[Palette]\nName=mine\n# see gnome-themes for the idea\n' > "$PTYXIS_PALETTES/catppuccin-dynamic.palette"
for verb in install-theme update-theme switch-theme remove-theme; do
    THEMES_DEST=$PD PTYXIS_BIN="$FIX" just install-theme everforest </dev/null >/dev/null 2>&1; mkold
    vargs=(); [ "$verb" = update-theme ] || vargs=(everforest)
    out=$(THEMES_DEST=$PD PTYXIS_BIN="$FIX" just "$verb" "${vargs[@]}" </dev/null 2>&1)
    n=$(printf '%s\n' "$out" | grep -c 'Removed old generated Ptyxis palette')
    [ ! -e "$PTYXIS_PALETTES/gnome-themes-rose-pine.palette" ] && [ ! -e "$PTYXIS_PALETTES/gnome-themes-sweet.palette" ] && [ "$n" = 2 ] && [ -f "$PTYXIS_PALETTES/catppuccin-dynamic.palette" ] && grep -q mine "$PTYXIS_PALETTES/catppuccin-dynamic.palette" && chk ok "$verb deletes the old marked palette files (one line each) and keeps the unmarked one" || chk fail "$verb palette cleanup ($n lines; $(ls "$PTYXIS_PALETTES" | tr '\n' ' '))"
done
THEMES_DEST=$PD just remove-theme everforest </dev/null >/dev/null 2>&1; rm -rf "$PTYXIS_PALETTES"
THEMES_DEST=$PD PTYXIS_BIN="$FIX" just install-theme everforest </dev/null >/dev/null 2>&1; ls "$PTYXIS_PALETTES" >/dev/null 2>&1 && [ -z "$(ls "$PTYXIS_PALETTES")" ] && chk fail "install created palette dir content" || chk ok "install-theme copies no palette file"
# switch-theme writes the ID (not the Name) on the default profile and the one that had a key, reads it back, and finds it among the built-ins
out=$(THEMES_DEST=$PD PTYXIS_BIN="$FIX" just switch-theme everforest </dev/null 2>&1)
[ "$(dconf read /org/gnome/Ptyxis/Profiles/aaa/palette)" = "'Everforest'" ] && [ "$(dconf read /org/gnome/Ptyxis/Profiles/bbb/palette)" = "'Everforest'" ] && [ -z "$(dconf read /org/gnome/Ptyxis/Profiles/ccc/palette)" ] && printf '%s\n' "$out" | grep -q "Ptyxis palette key reads 'Everforest'" && ! printf '%s\n' "$out" | grep -q WARNING && chk ok "switch-theme writes the id on the default and the palette-keyed profile, reads the key back and prints it, no warning" || chk fail "id switch ($(grep palette "$DCONF_DB" | tr '\t\n' '= '))"
# a lower-case id (nord): the id, never the Name 'Nord'
: > "$DCONF_DB"; printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" >> "$DCONF_DB"
THEMES_DEST=$PD just install-theme nordic </dev/null >/dev/null 2>&1; THEMES_DEST=$PD just install-theme catppuccin </dev/null >/dev/null 2>&1; THEMES_DEST=$PD PTYXIS_BIN="$FIX" just switch-theme nordic </dev/null >/dev/null 2>&1
[ "$(dconf read /org/gnome/Ptyxis/Profiles/aaa/palette)" = "'nord'" ] && chk ok "nordic writes the id 'nord' (lower case), not the Name" || chk fail "nordic id ($(grep palette "$DCONF_DB" | tr '\t\n' '= '))"
# an id that the installed Ptyxis does not have: warning
mkdir -p "$T/pty-ids-short"; cp "$FIX/nord.palette" "$T/pty-ids-short/"
out=$(THEMES_DEST=$PD PTYXIS_BIN="$T/pty-ids-short" just switch-theme everforest </dev/null 2>&1)
printf '%s\n' "$out" | grep -q "WARNING: 'Everforest' is not a built-in palette id" && chk ok "an id missing from the installed Ptyxis is reported (it would fall back to the default palette)" || chk fail "no warning for an unknown id"
# light/dark: catppuccin has ptyxis (Mocha) and ptyxis_light (Latte); the system colour scheme decides at switch time
gs() { mkdir -p "$T/gs-$1"; printf '#!/bin/sh\ncase "$1" in set) : ;; get) case "$3" in color-scheme) echo "\x27%s\x27";; gtk-theme) echo "\x27%s\x27";; *) echo "\x27x\x27";; esac ;; list-schemas) echo org.gnome.shell.extensions.user-theme ;; esac\n' "$2" "$3" > "$T/gs-$1/gsettings"; chmod +x "$T/gs-$1/gsettings"; }
cat_id() { : > "$DCONF_DB"; printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" >> "$DCONF_DB"; PATH="$T/gs-$1:$PATH" THEMES_DEST=$PD PTYXIS_BIN="$FIX" just switch-theme catppuccin </dev/null > "$T/cat.out" 2>&1; dconf read /org/gnome/Ptyxis/Profiles/aaa/palette; }
gs dark prefer-dark Adwaita; gs light prefer-light Adwaita; gs defl default Adwaita; gs defd default Gruvbox-dark
[ "$(cat_id dark)" = "'Catppuccin Mocha'" ] && chk ok "prefer-dark: Catppuccin gets its dark id" || chk fail "prefer-dark id"
[ "$(cat_id light)" = "'Catppuccin Latte'" ] && grep -q 'again after changing between light and dark' "$T/cat.out" && chk ok "prefer-light: the light id, and the output says to run switch-theme again after changing light/dark" || chk fail "prefer-light id"
[ "$(cat_id defl)" = "'Catppuccin Latte'" ] && chk ok "default with a light GTK theme: the light id" || chk fail "default/light id"
[ "$(cat_id defd)" = "'Catppuccin Mocha'" ] && chk ok "default with a dark GTK theme: the dark id" || chk fail "default/dark id"
# no Ptyxis profile at all: a clear note, nothing written
: > "$DCONF_DB"; out=$(THEMES_DEST=$PD PTYXIS_BIN="$FIX" just switch-theme everforest </dev/null 2>&1)
printf '%s\n' "$out" | grep -q "no Ptyxis profile found" && ! grep -q Ptyxis "$DCONF_DB" && chk ok "no Ptyxis settings: note and skip" || chk fail "missing Ptyxis settings not handled"
for s in everforest nordic catppuccin; do THEMES_DEST=$PD just remove-theme $s </dev/null >/dev/null 2>&1; done; rm -rf "$PTYXIS_PALETTES"

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
out=$(FLATPAK_INFO="org.gnome.Builder" PATH="$T/fpbin:$PATH" THEMES_DEST=$PD just install-theme gruvbox-material </dev/null 2>&1)
ids="gnome-themes-gruvbox-material-dark.xml gnome-themes-gruvbox-material-light.xml"; ok=1
for d in "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS/org.gnome.TextEditor/data/gtksourceview-5/styles" "$FLATPAK_APPS/org.gnome.Builder/data/gtksourceview-5/styles"; do for f in $ids; do [ -f "$d/$f" ] || ok=0; done; done
[ $ok = 1 ] && chk ok "install-theme copies the style schemes into the user dir and into the Flatpak editors' data dirs (Text Editor by dir, Builder via flatpak info)" || chk fail "gsv install ($(ls "$GTKSOURCEVIEW_STYLES" 2>&1 | tr '\n' ' '))"
out=$(FLATPAK_INFO="org.gnome.Builder" PATH="$T/fpbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1)
[ "$(dconf read /org/gnome/TextEditor/style-scheme)" = "'gnome-themes-gruvbox-material-dark'" ] && [ "$(dconf read /org/gnome/builder/editor/style-scheme-name)" = "'gnome-themes-gruvbox-material-dark'" ] && chk ok "switch-theme sets Text Editor and (Builder present) Builder to the -dark id while the desktop is dark" || chk fail "gsv switch dark ($(grep -E 'TextEditor|builder' "$DCONF_DB" | tr '\t\n' '= '))"
lbin="$T/bin-light"; mkdir -p "$lbin"; printf '#!/bin/sh\ncase "$1" in set) : ;; get) case "$3" in color-scheme) echo "\x27default\x27";; *) echo "\x27x\x27";; esac ;; list-schemas) echo org.gnome.shell.extensions.user-theme ;; esac\n' > "$lbin/gsettings"; chmod +x "$lbin/gsettings"
PATH="$lbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null >/dev/null 2>&1
[ "$(dconf read /org/gnome/TextEditor/style-scheme)" = "'gnome-themes-gruvbox-material-light'" ] && [ "$(dconf read /org/gnome/builder/editor/style-scheme-name)" = "'gnome-themes-gruvbox-material-dark'" ] && chk ok "light desktop: the -light id for Text Editor; Builder untouched when it is not installed" || chk fail "gsv switch light"
PATH="$lbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1 | grep -q "Builder not found" && chk ok "without Builder the skip is announced" || chk fail "no Builder note"
echo "<!-- stale -->" >> "$GTKSOURCEVIEW_STYLES/gnome-themes-gruvbox-material-dark.xml"; THEMES_DEST=$PD just update-theme </dev/null >/dev/null 2>&1
grep -q stale "$GTKSOURCEVIEW_STYLES/gnome-themes-gruvbox-material-dark.xml" && chk fail "update did not refresh the style scheme" || chk ok "update-theme refreshes the style schemes"
THEMES_DEST=$PD just remove-theme gruvbox-material </dev/null >/dev/null 2>&1
[ -z "$(find "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS/org.gnome.TextEditor" -type f 2>/dev/null)" ] && chk ok "remove-theme removes the style schemes everywhere" || chk fail "remove left style schemes: $(find "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS" -type f 2>&1 | tr "\n" " ")"
# collision: an unmarked file with our id is kept; dark-only scheme has only the dark id
mkdir -p "$GTKSOURCEVIEW_STYLES"; echo mine > "$GTKSOURCEVIEW_STYLES/gnome-themes-fairy-floss-dark.xml"
out=$(THEMES_DEST=$PD just install-theme fairy-floss </dev/null 2>&1)
[ "$(cat "$GTKSOURCEVIEW_STYLES/gnome-themes-fairy-floss-dark.xml")" = mine ] && printf '%s\n' "$out" | grep -q "not installed by gnome-themes" && chk ok "an unmarked style scheme file is not replaced" || chk fail "gsv collision"
rm -f "$GTKSOURCEVIEW_STYLES/gnome-themes-fairy-floss-dark.xml"; THEMES_DEST=$PD just install-theme fairy-floss </dev/null >/dev/null 2>&1
[ -f "$GTKSOURCEVIEW_STYLES/gnome-themes-fairy-floss-dark.xml" ] && [ ! -e "$GTKSOURCEVIEW_STYLES/gnome-themes-fairy-floss-light.xml" ] && chk ok "a dark-only scheme installs only its -dark style scheme" || chk fail "dark-only gsv"
THEMES_DEST=$PD just remove-theme fairy-floss </dev/null >/dev/null 2>&1; THEMES_DEST=$PD just remove-theme gruvbox-material </dev/null >/dev/null 2>&1; rm -rf "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS" "$PTYXIS_PALETTES"

# ---- new-scheme helpers: Ptyxis built-in reader (by id) and the draft scheme.toml writer (fixture built-ins, no real Ptyxis needed) ----
echo "=== new scheme from a Ptyxis palette"
col() { printf 'Background=%s\nForeground=%s\nCursor=%s\n' "$1" "$2" "$3"; for i in $(seq 0 15); do printf 'Color%d=#%02x%02x%02x\n' "$i" $((i*9+40)) $((255-i*8)) $((i*5+90)); done; }
FAKE="$T/fake-ids"; mkdir -p "$FAKE"
{ printf '[Palette]\nName=Fake Night\n'; col '#101820' '#e0e0e0' '#ffffff'; } > "$FAKE/Fake Night.palette"
{ printf '[Palette]\nName=Fake Duo\nPrimary=true\n[Light]\n'; col '#fafafa' '#202020' '#202020'; printf '[Dark]\n'; col '#202030' '#d0d0e0' '#d0d0e0'; } > "$FAKE/Fake Duo.palette"
{ printf '[Palette]\nName=Ros\xc3\xa9 Fake\n'; col '#191724' '#e0def4' '#e0def4'; } > "$FAKE/Rosé Fake.palette"
{ printf '[Palette]\nName=Fake Duo Lower\n'; col '#000000' '#ffffff' '#ffffff'; } > "$FAKE/fake duo.palette"
export PTYXIS_BIN="$FAKE"
[ "$(tools/ptyxis-palette.sh list | tr '\t\n' '= ')" = "Fake Duo=Fake Duo=Light,Dark Fake Night=Fake Night=flat Rosé Fake=Rosé Fake=flat fake duo=Fake Duo Lower=flat " ] && chk ok "ptyxis-palette.sh list: id, Name and sections, including a non-ASCII id and ids that differ only in case" || chk fail "ptyxis-palette.sh list: $(tools/ptyxis-palette.sh list | tr '\t\n' '= ')"
tools/ptyxis-palette.sh show "Rosé Fake" | grep -qx 'Name=Rosé Fake' && python3 -I tools/scheme-from-ptyxis.py zz-rose "Rosé Fake" >/dev/null 2>&1 && grep -q '^bg_deep = "#191724"' zz-rose/scheme.toml && grep -qx 'ptyxis = "Rosé Fake"' zz-rose/scheme.toml && chk ok "non-ASCII ids work in ptyxis-palette.sh show and scheme-from-ptyxis (the draft declares the id)" || chk fail "non-ASCII palette id (Rosé)"
rm -rf zz-rose
tools/ptyxis-palette.sh show "Fake Duo" | grep -q '^\[Dark\]' && tools/ptyxis-palette.sh show "Fake Night" | grep -q '^Color15=' && ! tools/ptyxis-palette.sh show "Fake Night" | grep -q Duo && tools/ptyxis-palette.sh show "fake duo" | grep -q 'Fake Duo Lower' && chk ok "ptyxis-palette.sh show: the id is exact and case-sensitive, one palette, verbatim" || chk fail "ptyxis-palette.sh show"
tools/ptyxis-palette.sh show nothing >/dev/null 2>&1 && chk fail "show of an unknown id succeeded" || chk ok "ptyxis-palette.sh show: unknown id fails"
tools/ptyxis-palette.sh show "FAKE NIGHT" >/dev/null 2>&1 && chk fail "show matched an id case-insensitively" || chk ok "ptyxis-palette.sh show: a Name-style spelling of the wrong case is not an id"
rm -rf zz-fake zz-duo zz-two
out=$(python3 -I tools/scheme-from-ptyxis.py zz-duo "Fake Duo" 2>&1)
python3 -I - <<'PY' && chk ok "scheme-from-ptyxis: a sectioned palette gives dark and light draft variants with the accents, bg_deep, fg, the id, and the TODO list" || chk fail "draft scheme.toml wrong"
import tomllib
S = tomllib.load(open('zz-duo/scheme.toml', 'rb'))
assert S['title'] == 'Zz Duo' and S['gtk_name'] == 'Zz-Duo' and S['shell_name'] == 'Zz-Duo-Shell'
assert S['ptyxis'] == 'Fake Duo' and 'ptyxis_light' not in S and S['dark']['terminal']['source'] == 'Fake Duo'
assert S['dark']['bg_deep'] == '#202030' and S['light']['bg_deep'] == '#fafafa' and S['dark']['fg'] == '#d0d0e0'
assert set(S['dark']['ansi']) == {'red', 'green', 'yellow', 'blue', 'magenta', 'cyan'}
assert S['dark']['ansi']['green'] == '#%02x%02x%02x' % (2 * 9 + 40, 255 - 16, 2 * 5 + 90)
assert 'terminal' in S['dark'] and S['dark']['terminal']['black'] == '#%02x%02x%02x' % (40, 255, 90)
assert open('zz-duo/scheme.toml').read().count('# TODO') >= 6
PY
printf '%s\n' "$out" | grep -q "default_accent: proposed" && chk ok "the TODO list is printed (default_accent proposal with its reason)" || chk fail "TODO list not printed"
python3 -I tools/palette-from-scheme.py zz-duo --check >/dev/null 2>&1 && chk ok "the draft derives a palette.toml (the pipeline accepts it)" || chk fail "palette-from-scheme.py rejects the draft"
out=$(python3 -I tools/scheme-from-ptyxis.py zz-duo "Fake Duo" 2>&1); rc=$?
[ $rc -ne 0 ] && printf '%s\n' "$out" | grep -q "refusing to overwrite" && chk ok "scheme-from-ptyxis refuses to overwrite an existing scheme" || chk fail "overwrite not refused"
python3 -I tools/scheme-from-ptyxis.py zz-fake "Fake Night" >/dev/null 2>&1; grep -q '^\[dark\]' zz-fake/scheme.toml && ! grep -q '^\[light\]' zz-fake/scheme.toml && grep -q "dark only" zz-fake/scheme.toml && chk ok "a flat dark palette gives a dark-only draft" || chk fail "flat palette draft"
python3 -I tools/scheme-from-ptyxis.py zz-two "Fake Night" "Fake Duo" >/dev/null 2>&1; grep -q '^bg_deep = "#fafafa"' zz-two/scheme.toml && grep -q '^bg_deep = "#101820"' zz-two/scheme.toml && grep -qx 'ptyxis = "Fake Night"' zz-two/scheme.toml && grep -qx 'ptyxis_light = "Fake Duo"' zz-two/scheme.toml && chk ok "a second id gives the light variant and ptyxis_light" || chk fail "light palette argument"
rm -rf zz-fake zz-duo zz-two; unset PTYXIS_BIN
# ptyxis-compare: a copy of everforest declares a built-in id; fixture built-ins are made from the scheme's own colours (a directory of <id>.palette files)
mkdir zz-ef && cp everforest/scheme.toml zz-ef/
EVER="$T/fix-ever"; mkdir -p "$EVER"
python3 -I - "$EVER" <<'PY'
import sys; sys.path.insert(0, 'tools'); import schemeroles as sr
S, roles, slots = sr.load('zz-ef')
out = ['[Palette]', 'Name=Everforest Display Name', 'Primary=true']
for slot, variant in slots:
    c = sr.slot_colors(S, roles, variant); out.append('[%s]' % slot.capitalize())
    out += ['%s=%s' % (k, c[k]) for k in ['Foreground', 'Background', 'Cursor'] + ['Color%d' % i for i in range(16)]]
open(sys.argv[1] + '/Everforest.palette', 'w').write('\n'.join(out) + '\n')
PY
cchk() { PTYXIS_BIN="$EVER" python3 -I tools/ptyxis-compare.py --check zz-ef 2>/dev/null; }
out=$(cchk); [ -z "$out" ] && chk ok "ptyxis-compare --check: a declared id that exists passes" || chk fail "ptyxis-compare: valid id rejected ($out)"
PTYXIS_BIN="$EVER" python3 -I tools/ptyxis-compare.py --check zz-ef 2>&1 >/dev/null | grep -q 'built-in id "Everforest" (Light,Dark): roles max dE 0.00' && chk ok "ptyxis-compare --check reports the delta E of each declared id as information" || chk fail "ptyxis-compare: no delta E info"
sed -i 's/^ptyxis = .*/ptyxis = "Everforestt"/' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'is not a Ptyxis built-in id' && chk ok "ptyxis-compare --check: a declared id that is not in the binary is flagged" || chk fail "ptyxis-compare: unknown id accepted ($out)"
sed -i 's/^ptyxis = .*/ptyxis = "everforest"/' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'did you mean "Everforest"' && chk ok "ptyxis-compare --check: a wrong-case id is flagged with the right one (ids are case-sensitive)" || chk fail "ptyxis-compare: wrong case accepted ($out)"
cp everforest/scheme.toml zz-ef/scheme.toml; sed -i 's/^ptyxis = .*/&\nptyxis_light = "Everforest"/' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'covers both modes' && chk ok "ptyxis-compare --check: ptyxis_light next to a sectioned built-in is flagged" || chk fail "ptyxis-compare: ptyxis_light on a sectioned built-in accepted ($out)"
cp everforest/scheme.toml zz-ef/scheme.toml; sed -i '/^ptyxis_reason/d' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'ptyxis_reason missing' && chk ok "ptyxis-compare --check: a missing ptyxis_reason is flagged" || chk fail "ptyxis-compare: missing reason accepted"
# two flat built-ins (catppuccin): ptyxis + ptyxis_light
mkdir zz-cat && cp catppuccin/scheme.toml zz-cat/; CAT="$T/fix-cat"; mkdir -p "$CAT"
python3 -I - "$CAT" <<'PY'
import sys; sys.path.insert(0, 'tools'); import schemeroles as sr
S, roles, slots = sr.load('zz-cat')
for variant, pid in (('dark', 'Catppuccin Mocha'), ('light', 'Catppuccin Latte')):
    c = sr.slot_colors(S, roles, variant)
    open('%s/%s.palette' % (sys.argv[1], pid), 'w').write('[Palette]\nName=%s\n' % pid + ''.join('%s=%s\n' % (k, c[k]) for k in ['Foreground', 'Background', 'Cursor'] + ['Color%d' % i for i in range(16)]))
PY
out=$(PTYXIS_BIN="$CAT" python3 -I tools/ptyxis-compare.py --check zz-cat 2>/dev/null); [ -z "$out" ] && chk ok "ptyxis-compare --check: ptyxis + ptyxis_light on two flat built-ins pass" || chk fail "ptyxis-compare: flat pair rejected ($out)"
sed -i 's/^ptyxis_light = .*/ptyxis_light = "Catppuccin Latté"/' zz-cat/scheme.toml
out=$(PTYXIS_BIN="$CAT" python3 -I tools/ptyxis-compare.py --check zz-cat 2>/dev/null); printf '%s\n' "$out" | grep -q 'ptyxis_light = "Catppuccin Latté" is not' && chk ok "ptyxis-compare --check: a bad ptyxis_light id is flagged (UTF-8 output)" || chk fail "ptyxis-compare: bad ptyxis_light accepted ($out)"
rm -rf zz-cat
# ptyxis-compare --check, the source rules: every variant names its source; a listed nudge must be true; a difference from the built-in is information only
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
nud '#d6c9ad' ''
out=$(cchk); printf '%s\n' "$out" | grep -q 'not listed in \[dark.nudge\]' && chk ok "ptyxis-compare --check: a colour that differs from the built-in and is not listed as a nudge is flagged" || chk fail "ptyxis-compare: unlisted difference not flagged ($out)"
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
# a sectioned built-in for a dark-only scheme needs the acceptance flag (Nordic with Nord)
if [ -r "/usr/bin/ptyxis" ] && tools/ptyxis-palette.sh show nord >/dev/null 2>&1; then
    python3 -I tools/ptyxis-compare.py --check nordic >/dev/null 2>&1 && chk ok "ptyxis-compare --check: Nordic on the sectioned nord built-in passes (accepted light section)" || chk fail "ptyxis-compare: nordic"
    mkdir zz-nd && sed '/^ptyxis_light_section_accepted/d' nordic/scheme.toml > zz-nd/scheme.toml
    out=$(python3 -I tools/ptyxis-compare.py --check zz-nd 2>/dev/null); printf '%s\n' "$out" | grep -q 'ptyxis_light_section_accepted' && chk ok "ptyxis-compare --check: a sectioned built-in for a dark-only scheme is refused without the acceptance flag" || chk fail "ptyxis-compare: sectioned built-in accepted for dark-only ($out)"
    rm -rf zz-nd
else echo "  SKIP Nordic/nord checks (no Ptyxis binary here)"; fi
# the built-in is the only source: an "official:" source, builtin_differs and a source that is not the declared id are flagged
cp everforest/scheme.toml zz-ef/scheme.toml; sed -i '0,/^source = .*/s//source = "official: fixture\/repo, verified 2026-11-07"/' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'not the id declared for this variant' && chk ok "ptyxis-compare --check: an official-style source (not the declared built-in id) is flagged" || chk fail "ptyxis-compare: official source accepted ($out)"
cp everforest/scheme.toml zz-ef/scheme.toml; sed -i '0,/^source = .*/s//&\nbuiltin_differs = { name = "Everforest", de = 9.9, note = "fixture: official wins" }/' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'builtin_differs is gone' && chk ok "ptyxis-compare --check: builtin_differs is flagged (the mechanism is gone)" || chk fail "ptyxis-compare: builtin_differs accepted ($out)"
rm -rf zz-ef
just --summary 2>/dev/null | grep -q new-scheme && chk fail "new-scheme became a public recipe" || chk ok "new-scheme is private (public set unchanged)"
just --justfile justfile --working-directory . new-scheme 2>&1 | grep -qi "usage\|palette" && chk ok "the private recipe runs by name (the passthrough path)" || chk fail "private recipe not runnable by name"

# ---- icons (fake icon repo) -----------------------------------------------------------------------------------
echo "=== icons"
# a second fixture source and a git wrapper that logs every clone, to prove what is cloned and when
mkdir -p "$T/icons-src2" && (cd "$T/icons-src2" && git init -q && mkdir Other-One && printf '[Icon Theme]\nName=Other-One\nDirectories=\n' > Other-One/index.theme && git add -A && git commit -q -m init)
printf 'fake|file://%s/icons-src|top|Fake-Dark Fake-Light\nother|file://%s/icons-src2|top|Other-One\nbroken|file://%s/nonexistent|top|Broken-One\n' "$T" "$T" "$T" > "$T/sources.conf"
export ICON_SOURCES="$T/sources.conf" ICONS_DEST="$T/icons"
REAL_GIT=$(command -v git); GITLOG="$T/git.log"; mkdir -p "$T/gitw"
printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$GITLOG" "$REAL_GIT" > "$T/gitw/git"; chmod +x "$T/gitw/git"
rm -rf "$T/cache/icons"; : > "$GITLOG"
out=$(PATH="$T/gitw:$PATH" just list-icons 2>&1)
[ ! -e "$T/cache/icons" ] && ! grep -q . "$GITLOG" && printf '%s\n' "$out" | grep -q Fake-Dark && printf '%s\n' "$out" | grep -q Other-One && chk ok "list-icons works offline: no clone, no cache directory" || chk fail "list-icons cloned or lacked sets"
# no name: the checklist is built from the registry (cache empty, no clone before the choice); q cancels
out=$(printf 'q\n' | PATH="$T/gitw:$PATH" just install-icon 2>&1)
[ ! -e "$T/cache/icons" ] && ! grep -q . "$GITLOG" && printf '%s\n' "$out" | grep -q "Fake-Light" && printf '%s\n' "$out" | grep -q "Other-One" && chk ok "install-icon: checklist shown with an empty cache and no clone before the choice" || chk fail "install-icon cloned before the choice"
# choose set 1 only: just its source is cloned (the checklist lists fake's two sets first)
printf '1\n\n' | PATH="$T/gitw:$PATH" just install-icon >/dev/null 2>&1
[ -d "$ICONS_DEST/Fake-Dark" ] && grep -q "icons-src " "$GITLOG" && ! grep -q "icons-src2\|nonexistent" "$GITLOG" && [ ! -e "$T/cache/icons/other" ] && chk ok "install-icon: only the source of the chosen set was cloned" || chk fail "install-icon cloned unchosen sources"
just remove-icon Fake-Dark >/dev/null 2>&1; rm -rf "$T/cache/icons"; : > "$GITLOG"
# with names: only those sources; a failing source is skipped, the others install
out=$(PATH="$T/gitw:$PATH" just install-icon Other-One 2>&1)
[ -d "$ICONS_DEST/Other-One" ] && ! grep -q "icons-src " "$GITLOG" && ! grep -q nonexistent "$GITLOG" && chk ok "install-icon NAME: only that source cloned" || chk fail "install-icon NAME cloned more"
out=$(PATH="$T/gitw:$PATH" just install-icon Broken-One 2>&1); printf '%s\n' "$out" | grep -q "could not clone broken" && [ ! -e "$ICONS_DEST/Broken-One" ] && chk ok "a failing clone is skipped with a message" || chk fail "failing clone not handled"
printf '1\n4\n\n' | just install-icon >/dev/null 2>&1   # Fake-Dark and Broken-One in one run; the broken one must not stop the other
[ -d "$ICONS_DEST/Fake-Dark" ] && [ ! -e "$ICONS_DEST/Broken-One" ] && chk ok "a failing source does not stop the other chosen sets" || chk fail "failing source blocked the run"
# list, switch and remove never clone (cache wiped, installed sets stay)
rm -rf "$T/cache/icons"; : > "$GITLOG"
PATH="$T/gitw:$PATH" just list-icons >/dev/null 2>&1
printf '1\n' | PATH="$T/gitw:$PATH" just switch-icon >/dev/null 2>&1; PATH="$T/gitw:$PATH" just switch-icon Fake-Dark >/dev/null 2>&1
printf 'q\n' | PATH="$T/gitw:$PATH" just remove-icon >/dev/null 2>&1
[ ! -e "$T/cache/icons" ] && ! grep -q . "$GITLOG" && chk ok "list, switch and remove-icon do not clone" || chk fail "list/switch/remove cloned ($(cat "$GITLOG"))"
for n in Fake-Dark Other-One Fake-Light; do just remove-icon $n >/dev/null 2>&1; done; rm -rf "$T/cache/icons"
# registry versus upstream: one warning per mismatch, install still succeeds
mkdir -p "$T/icons-src3" && (cd "$T/icons-src3" && git init -q && for n in Real-One Extra-One; do mkdir $n; printf '[Icon Theme]\nName=%s\nDirectories=\n' $n > $n/index.theme; done && git add -A && git commit -q -m init)
printf 'drift|file://%s/icons-src3|top|Real-One Ghost-One\n' "$T" > "$T/drift.conf"
out=$(ICON_SOURCES="$T/drift.conf" just install-icon Real-One 2>&1)
printf '%s\n' "$out" | grep -qF "registry says Ghost-One, upstream has no Ghost-One" && printf '%s\n' "$out" | grep -qF "upstream has Extra-One not in the registry" && [ -d "$ICONS_DEST/Real-One" ] && [ "$(printf '%s\n' "$out" | grep -c '^warning:')" = 2 ] && chk ok "registry mismatches: one warning line each, install carries on" || chk fail "registry mismatch warnings"
ICON_SOURCES="$T/drift.conf" just remove-icon Real-One >/dev/null 2>&1; rm -rf "$T/cache/icons"
printf 'fake|file://%s/icons-src|top|Fake-Dark Fake-Light\n' "$T" > "$T/sources.conf"
just list-icons 2>&1 | grep -q Fake-Dark && chk ok "list-icons shows the sets" || chk fail "list-icons"
just install-icon Fake-Dark >/dev/null 2>&1; [ -d "$ICONS_DEST/Fake-Dark" ] && chk ok "install-icon" || chk fail "install-icon"
: > "$LOG"; just switch-icon Fake-Dark >/dev/null 2>&1; grep -q "icon-theme Fake-Dark" "$LOG" && chk ok "switch-icon" || chk fail "switch-icon"
(cd "$T/icons-src" && echo y > Fake-Dark/apps/b.svg && git add -A && git commit -q -m more)
just update-icon >/dev/null 2>&1; [ -f "$ICONS_DEST/Fake-Dark/apps/b.svg" ] && chk ok "update-icon picks up the new upstream commit" || chk fail "update-icon"
just remove-icon Fake-Dark >/dev/null 2>&1; [ ! -d "$ICONS_DEST/Fake-Dark" ] && chk ok "remove-icon" || chk fail "remove-icon"

# collision guard (icons): an unrelated Fake-Light is left alone, a pre-marker copy of Fake-Dark is adopted
mkdir -p "$ICONS_DEST/Fake-Light"; echo mine > "$ICONS_DEST/Fake-Light/mine.txt"
just install-icon Fake-Light </dev/null >/dev/null 2>&1; just update-icon </dev/null >/dev/null 2>&1; just remove-icon Fake-Light </dev/null >/dev/null 2>&1
[ -f "$ICONS_DEST/Fake-Light/mine.txt" ] && chk ok "icons: unrelated folder untouched by install, update and remove" || chk fail "icons: unrelated Fake-Light was touched"
FORCE=1 just install-icon Fake-Light </dev/null >/dev/null 2>&1; [ ! -e "$ICONS_DEST/Fake-Light/mine.txt" ] && [ -f "$ICONS_DEST/Fake-Light/.gnome-themes" ] && chk ok "icons: FORCE=1 replaces and marks" || chk fail "icons: FORCE=1"
cp -a "$T/icons-src/Fake-Dark" "$ICONS_DEST/Fake-Dark"; rm -rf "$ICONS_DEST/Fake-Dark/.git"; echo stale > "$ICONS_DEST/Fake-Dark/stale.txt"
just install-icon Fake-Dark </dev/null >/dev/null 2>&1; [ ! -e "$ICONS_DEST/Fake-Dark/stale.txt" ] && [ -f "$ICONS_DEST/Fake-Dark/.gnome-themes" ] && chk ok "icons: a pre-marker installation is adopted" || chk fail "icons: legacy not adopted"
just remove-icon Fake-Dark </dev/null >/dev/null 2>&1; just remove-icon Fake-Light </dev/null >/dev/null 2>&1

# ---- Flatpak access: grant after a y, record only what was added, undo only that ------------------------------------------------
echo "=== flatpak access"
FS="$T/themes-fp"; FI="$T/icons-fp"; fpst="$XDG_STATE_HOME/gnome-themes/flatpak-overrides"; rm -f "$fpst"
export FP_PATH="$T/fpbin:$PATH"
fpshow() { sort "$FLATPAK_DB" | tr '\n' ' '; }
# without a terminal: nothing changes, the exact command is printed
: > "$FLATPAK_DB"
out=$(PATH="$FP_PATH" THEMES_DEST=$FS just install-theme fairy-floss </dev/null 2>&1; PATH="$FP_PATH" THEMES_DEST=$FS just switch-theme fairy-floss </dev/null 2>&1)
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
    PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS just install-icon Fake-Dark </dev/null >/dev/null 2>&1
    printf 'y\n' | PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS script -qec "tools/themectl.sh themes remove fairy-floss" /dev/null > "$T/fp.out" 2>&1
    [ -s "$fpst" ] && ! grep -q "Remove the Flatpak read access" "$T/fp.out" && chk ok "removing the last theme while an icon set remains does not ask" || chk fail "undo asked too early"
    printf 'n\n' | PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS script -qec "tools/themectl.sh icons remove Fake-Dark" /dev/null > "$T/fp.out" 2>&1
    grep -q "Remove the Flatpak read access that gnome-themes added" "$T/fp.out" && [ -s "$fpst" ] && [ "$(fpshow)" = "xdg-config/gtk-3.0:ro xdg-config/gtk-4.0:ro xdg-data/icons:ro ~/.themes:ro " ] && chk ok "removing the last set asks; n keeps access and record" || chk fail "undo n case"
    PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS just install-icon Fake-Dark </dev/null >/dev/null 2>&1
    out=$(PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS just remove-icon Fake-Dark </dev/null 2>&1)
    printf '%s\n' "$out" | grep -qF "flatpak override --user --nofilesystem=xdg-config/gtk-3.0 --nofilesystem=xdg-data/icons --nofilesystem=~/.themes" && ! printf '%s\n' "$out" | grep -q "nofilesystem=xdg-config/gtk-4.0" && [ -s "$fpst" ] && chk ok "no terminal: the undo commands for exactly the recorded entries are printed, nothing removed" || chk fail "undo no-terminal case"
    PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS just install-icon Fake-Dark </dev/null >/dev/null 2>&1
    printf 'y\n' | PATH="$FP_PATH" ICONS_DEST=$FI THEMES_DEST=$FS script -qec "tools/themectl.sh icons remove Fake-Dark" /dev/null >/dev/null 2>&1
    [ "$(fpshow)" = "xdg-config/gtk-4.0:ro " ] && [ ! -e "$fpst" ] && chk ok "answer y: exactly the recorded entries are removed (the pre-existing one stays), record cleared" || chk fail "undo y case ($(fpshow))"
else echo "  skip flatpak prompt tests (script not installed)"; fi
rm -rf "$FS" "$FI" "$fpst"; : > "$FLATPAK_DB"

# ---- checklist UI (pty): SPACE toggles, ENTER confirms, q cancels, preselection shown ---------------------------
echo "=== checklist (pty)"
cat > "$T/ptyrun.py" <<'PY'
import os, pty, select, sys, time, fcntl, termios, struct, re
keys = {'down': b'\x1b[B', 'up': b'\x1b[A', 'space': b' ', 'enter': b'\r', 'esc': b'\x1b', 'slash': b'/', 'bs': b'\x7f'}
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
        os.write(fd, keys.get(seq[i], seq[i].encode())); i += 1; last = time.time()
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
echo "$out" | grep -q '\[ \]' && ! echo "$out" | grep -q '\[x\]' && chk ok "themes checklist starts with every box off" || chk fail "themes checklist has a preselected box"
echo "$out" | grep -q 'SPACE toggles' && chk ok "checklist hint says SPACE toggles" || chk fail "checklist hint"
[ "$(n_inst "$PD")" -eq 0 ] && echo "$out" | grep -q Cancelled && chk ok "q cancels, nothing installed" || chk fail "q did not cancel"
THEMES_DEST=$PD pty n,down,space,enter tools/themectl.sh themes install >/dev/null
first_sc=$(sed -n 's/^FEATURED_THEMES="${FEATURED_THEMES-\(.*\)}"$/\1/p' tools/themectl.sh | awk '{print $2}'); gname=$(awk -F'"' '/^gtk_name/ {print $2}' "$first_sc/palette.toml")
[ -d "$PD/$gname" ] && chk ok "none, down, SPACE ticks one entry, ENTER installs it ($first_sc)" || chk fail "space did not tick the second entry"
PF="$T/pty-filter"; mkdir -p "$PF"
THEMES_DEST=$PF pty slash,D,R,A,C,enter,space,enter tools/themectl.sh themes install >/dev/null
[ -d "$PF/Dracula" ] && [ -z "$(find "$PF" -mindepth 1 -maxdepth 1 -not -name 'Dracula*')" ] && chk ok "checklist filter: / then DRAC (any case) narrows the list, SPACE ticks the shown entry, only dracula installed" || chk fail "filter install: $(ls "$PF" | tr '\n' ' ')"
rm -rf "$PF"; mkdir -p "$PF"
THEMES_DEST=$PF pty space,slash,d,r,a,c,enter,space,slash,esc,enter tools/themectl.sh themes install >/dev/null
[ -d "$PF/Dracula" ] && [ -d "$PF/Nordic-Nord" ] && chk ok "filter: a tick made before filtering survives it, and Esc shows the full list again" || chk fail "filter keeps ticks: $(ls "$PF" | tr '\n' ' ')"
out=$(THEMES_DEST=$PF pty slash,z,z,z,q tools/themectl.sh themes install); echo "$out" | grep -q 'filter: zzz' && chk ok "a filter without a match shows an empty list" || chk fail "no-match filter"
PD2="$T/pty-themes2"; mkdir -p "$PD2"; out=$(THEMES_DEST=$PD2 pty enter tools/themectl.sh themes install)
[ "$(n_inst "$PD2")" -eq 0 ] && echo "$out" | grep -q 'Nothing selected' && chk ok "ENTER alone (empty selection) installs nothing and says so" || chk fail "enter alone installed $(n_inst "$PD2")"
THEMES_DEST=$PD2 tools/themectl.sh themes install "$first_sc" >/dev/null 2>&1
[ "$(n_inst "$PD2")" -ge 1 ] && chk ok "a named scheme installs without the checklist" || chk fail "named install failed"
out=$(THEMES_DEST=$PD pty down,enter tools/themectl.sh themes switch "$first_sc")
echo "$out" | grep -q 'current' && chk ok "accent submenu marks the current accent" || chk fail "accent submenu: no (current) mark"
grep -q "^$first_sc=" "$XDG_STATE_HOME/gnome-themes/accents" && chk ok "accent chosen in the submenu is remembered" || chk fail "accent not remembered"

echo; echo "TOTAL: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
