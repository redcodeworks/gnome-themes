# SPDX-License-Identifier: MIT
# gnome-themes: terminal-inspired GNOME themes (one top-level directory per scheme) and icon sets from several icon repos
# (tools/icon-sources.conf). Run `just` for the list; every recipe is a thin call into tools/themectl.sh. Needs just, bash, git.

default:
    @just --list --unsorted

# Themes: top-level directories of this repo, installed into ~/.themes (THEMES_DEST)

# List the available themes with their variants (✓ = installed, with the active accent)
[group('themes')]
list-themes:
    @tools/themectl.sh themes list

# Install a theme (e.g. gruvbox-material) with its remembered accent; without a name, pick from a checklist
[group('themes')]
install-themes name="":
    @tools/themectl.sh themes install "{{name}}"

# Refresh every installed theme from this repo (pulls the checkout first when it has a remote) and re-apply the remembered accents
[group('themes')]
update-themes:
    @tools/themectl.sh themes update

# Remove an installed theme; without a name, pick from a checklist
[group('themes')]
remove-themes name="":
    @tools/themectl.sh themes remove "{{name}}"

# Make a theme the active GTK, Shell and libadwaita theme; without a name, pick one. The optional accent (one of the scheme's accents: its six terminal colours, plus orange where it has one) skips the accent question
[group('themes')]
switch-theme name="" accent="":
    @tools/themectl.sh themes switch "{{name}}" "{{accent}}"

# Icons: sets of the repos in tools/icon-sources.conf (Papirus, Gruvbox Plus, Zafiro, candy, Tela, Fluent; ICONS_URL replaces the papirus URL), listed from the registry without cloning; the sources of the chosen sets are cloned into ~/.cache/gnome-themes/icons and the sets installed into ~/.local/share/icons (ICONS_DEST)

# List the available icon sets with their source (✓ = installed)
[group('icons')]
list-icons:
    @tools/themectl.sh icons list

# Install an icon set (e.g. Papirus-Dark, Tela-nord) after refreshing its source clone; without a name, pick from a checklist
[group('icons')]
install-icons name="":
    @tools/themectl.sh icons install "{{name}}"

# Refresh the source clones, then replace every installed icon set
[group('icons')]
update-icons:
    @tools/themectl.sh icons update

# Remove an installed icon set; without a name, pick from a checklist
[group('icons')]
remove-icons name="":
    @tools/themectl.sh icons remove "{{name}}"

# Make an icon set the active icon theme; without a name, pick one
[group('icons')]
switch-icons name="":
    @tools/themectl.sh icons switch "{{name}}"

# Development: regenerate one scheme (or all) from its scheme.toml: palette tables, GTK3, GTK4 and GNOME Shell CSS from the toolkits' own stock stylesheets, the libadwaita file, the accent maps the Ptyxis palette and the GtkSourceView style schemes (needs python3-gobject, GTK 3, GTK 4 and gnome-shell)
[private]
generate theme="all":
    #!/usr/bin/env bash
    set -euo pipefail
    export PYTHONDONTWRITEBYTECODE=1
    if [ "{{theme}}" = all ]; then schemes=$(for f in */scheme.toml; do dirname "$f"; done); else schemes="{{theme}}"; fi
    for s in $schemes; do
        echo "== $s"
        python3 -I tools/palette-from-scheme.py "$s"
        name=$(awk -F'"' '/^gtk_name/ {print $2}' "$s/palette.toml"); title=$(awk -F'"' '/^title/ {print $2}' "$s/palette.toml")
        acc=$(mktemp -d)
        python3 -I tools/gtk3-theme-gen.py --palette="$s/palette.toml" --out="$s/themes/$name/gtk-3.0" --accent-dir="$acc"
        python3 -I tools/gtk4-theme-gen.py --palette="$s/palette.toml" --out="$s/themes/$name/gtk-4.0" --accent-dir="$acc"
        python3 -I tools/shell-theme-gen.py --palette="$s/palette.toml" --out="$s/themes" --accent-dir="$acc"
        python3 -I tools/libadwaita-gen.py --palette="$s/palette.toml" --out="$s/libadwaita/gtk.css" --accent-dir="$acc"
        printf '[Desktop Entry]\nType=X-GNOME-Metatheme\nName=%s\nComment=%s recolour of GTK'"'"'s own stock stylesheets (gtk-3.0 from GTK3 Adwaita, gtk-4.0 from GTK4 Default); libadwaita apps use the user-level libadwaita/gtk.css\n' "$name" "$title" > "$s/themes/$name/index.theme"
        for d in "$s"/themes/*/; do [ -f "$d/LICENSE" ] || cp gruvbox-material/themes/Gruvbox-Material/LICENSE "$d/LICENSE"; done
        python3 -I tools/accent-maps-gen.py "$s" "$acc"
        python3 -I tools/ptyxis-gen.py "$s"
        python3 -I tools/gtksourceview-gen.py "$s"
        rm -rf "$acc"
    done

# Development: contrast, structure, parse, accent-map and probe checks of a generated scheme (needs python3-gobject, GTK 3, GTK 4 and gnome-shell)
[private]
test theme="gruvbox-material":
    PYTHONDONTWRITEBYTECODE=1 python3 -I tools/selftest.py {{theme}}

# Development: start a new scheme from a built-in Ptyxis palette (see tools/ptyxis-palette.sh list): writes a DRAFT <scheme-dir>/scheme.toml and prints the decisions left (the build-scheme skill has the whole walk-through)
[private]
new-scheme dir palette light="":
    #!/usr/bin/env bash
    set -euo pipefail
    light="{{light}}"
    python3 -I tools/scheme-from-ptyxis.py "{{dir}}" "{{palette}}" ${light:+"$light"}
    echo
    echo "Next: resolve the TODOs in {{dir}}/scheme.toml, then run:"
    echo "  just generate {{dir}} && just test {{dir}} (optionally tools/test.sh {{dir}}; CI on the pull request is the test)"
    echo "and add the credit to NOTICE and the scheme to the list in README.md (see .claude/skills/build-scheme/SKILL.md)."
