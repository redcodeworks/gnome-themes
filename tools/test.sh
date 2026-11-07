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
export PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/cfg" XDG_STATE_HOME="$T/state" GNOME_THEMES_CACHE="$T/cache"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
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
try: os.waitpid(pid, 0)
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
