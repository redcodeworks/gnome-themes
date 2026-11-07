# SPDX-License-Identifier: MIT
# gnome-themes: terminal-inspired GNOME themes (one top-level directory per scheme) and icon sets from an icon repo
# (Papirus by default). Run `just` for the list; every recipe is a thin call into tools/themectl.sh. Needs just, bash, git.

default:
    @just --list --unsorted

# Themes: top-level directories of this repo, installed into ~/.themes (THEMES_DEST)

# List the available themes (✓ = installed)
[group('themes')]
list-themes:
    @tools/themectl.sh themes list

# Install a theme (e.g. gruvbox-material); without a name, pick from a checklist
[group('themes')]
install-themes name="":
    @tools/themectl.sh themes install "{{name}}"

# Refresh every installed theme from this repo (pulls the checkout first when it has a remote)
[group('themes')]
update-themes:
    @tools/themectl.sh themes update

# Remove an installed theme; without a name, pick from a checklist
[group('themes')]
remove-themes name="":
    @tools/themectl.sh themes remove "{{name}}"

# Make a theme the active GTK, Shell and libadwaita theme; without a name, pick one
[group('themes')]
switch-theme name="":
    @tools/themectl.sh themes switch "{{name}}"

# Icons: top-level directories of the icon repo (ICONS_URL, Papirus by default), installed into ~/.local/share/icons (ICONS_DEST)

# List the available icon sets (✓ = installed)
[group('icons')]
list-icons:
    @tools/themectl.sh icons list

# Install an icon set (e.g. Papirus-Dark); without a name, pick from a checklist
[group('icons')]
install-icons name="":
    @tools/themectl.sh icons install "{{name}}"

# Refresh every installed icon set from the icon repo
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

# Development: regenerate the GTK3, GTK4 and GNOME Shell CSS of a scheme from the toolkits' own stock stylesheets (needs python3-gobject, GTK 3, GTK 4 and gnome-shell)
[private]
generate theme="gruvbox-material":
    #!/usr/bin/env bash
    set -euo pipefail
    name=$(awk -F'"' '/^gtk_name/ {print $2}' {{theme}}/palette.toml)
    export PYTHONDONTWRITEBYTECODE=1
    python3 -I tools/gtk3-theme-gen.py --palette={{theme}}/palette.toml --out={{theme}}/themes/$name/gtk-3.0
    python3 -I tools/gtk4-theme-gen.py --palette={{theme}}/palette.toml --out={{theme}}/themes/$name/gtk-4.0
    python3 -I tools/shell-theme-gen.py --palette={{theme}}/palette.toml --out={{theme}}/themes
