# gnome-themes: one directory per colour scheme; each has palette.toml and themes/<Name>/ folders that are
# installed as-is into a themes directory (GTK3, plain GTK4 and GNOME Shell); libadwaita/ is a USER-level file (just install-user).

default:
    @just --list

# List the colour schemes in this repo
list:
    @ls -d */themes | sed 's|/themes||'

# Regenerate the GTK3, GTK4 and GNOME Shell CSS of a scheme from the toolkits' own stock stylesheets (needs python3-gobject, GTK 3, GTK 4 and gnome-shell)
generate theme="gruvbox-material":
    #!/usr/bin/env bash
    set -euo pipefail
    name=$(awk -F'"' '/^gtk_name/ {print $2}' {{theme}}/palette.toml)
    export PYTHONDONTWRITEBYTECODE=1
    python3 -I tools/gtk3-theme-gen.py --palette={{theme}}/palette.toml --out={{theme}}/themes/$name/gtk-3.0
    python3 -I tools/gtk4-theme-gen.py --palette={{theme}}/palette.toml --out={{theme}}/themes/$name/gtk-4.0
    python3 -I tools/shell-theme-gen.py --palette={{theme}}/palette.toml --out={{theme}}/themes

# Install every theme folder of a scheme into a themes directory (system: /usr/share/themes; per user: ~/.themes as real copies, Flatpak cannot follow symlinks)
install theme="gruvbox-material" dest="/usr/share/themes":
    mkdir -p "{{dest}}"
    cp -a {{theme}}/themes/. "{{dest}}/"

# Install the libadwaita named-colour file as ~/.config/gtk-4.0/gtk.css (libadwaita apps ignore the GTK theme and read only this user stylesheet). Never overwrites a different file unless force=force (then keeps a .bak)
install-user theme="gruvbox-material" force="":
    #!/usr/bin/env bash
    set -euo pipefail
    src="{{theme}}/libadwaita/gtk.css"
    dest="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-4.0/gtk.css"
    mkdir -p "$(dirname "$dest")"
    if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then
        if [ "{{force}}" != "force" ]; then
            echo "$dest exists and differs from $src; not overwriting."
            echo "Review: diff $src $dest   -- then: just install-user {{theme}} force"
            exit 1
        fi
        cp -L --backup=numbered "$dest" "$dest.bak" && echo "kept the old file as $dest.bak"
    fi
    cp "$src" "$dest" && echo "installed $dest"
