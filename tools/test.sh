#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Full test of the COMMITTED state of this repo (a fresh clone of HEAD, temp directories only, a stand-in gsettings,
# a local fake icon repo): lint, hygiene, regeneration, per-scheme selftest, install/switch/update/remove for every
# scheme and accent, and the icon recipes. Exits non-zero on any failure.
#   tools/test.sh [scheme ...]      # default: every scheme
# Needs: git, just, python3 + python3-gobject, GTK 3, GTK 4, gnome-shell (St typelib); shellcheck if present;
# a display (re-executes itself under xvfb-run when there is none).
# Runs with HOME pointed at a temp dir and checks at the end that the real ~/.themes, ~/.local/share/icons and ~/.config/gtk-4.0 are unchanged.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ -z "${TEST_UNDER_XVFB:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
    TEST_UNDER_XVFB=1 exec xvfb-run -a "$0" "$@"
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# The suite runs with a throwaway HOME, so a code path that ignores XDG_*/THEMES_DEST/ICONS_DEST can only write there; a canary
# listing of the real ~/.themes, icons and ~/.config/gtk-4.0 is compared at the end.
REAL_HOME="$HOME"; export HOME="$T/home"; mkdir -p "$HOME"
canary() { local p; for p in "$REAL_HOME/.themes" "$REAL_HOME/.local/share/icons" "$REAL_HOME/.config/gtk-4.0"; do [ -e "$p" ] && find "$p" -printf '%p %s %T@\n'; done | sort | sha1sum; }
canary0=$(canary)
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

[ "$(canary)" = "$canary0" ] && chk ok "real home untouched (.themes, icons, gtk-4.0)" || chk fail "real home untouched (.themes, icons, gtk-4.0)"

echo; echo "TOTAL: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
