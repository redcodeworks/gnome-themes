# gnome-themes: one directory per colour scheme; each has palette.toml and themes/<Name>/ folders that are
# installed as-is into a themes directory (GTK3, plain GTK4 and GNOME Shell); libadwaita/ is a USER-level file (just install-user).
# `just pick` is the easy way: a checklist that copies the themes you choose into ~/.themes. Needs only just and bash.

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

# Pick which themes to install, from a checklist (needs only just and bash). Installs real copies into ~/.themes (override with THEMES_DEST=DIR); give theme names to skip the prompt, e.g. just pick Gruvbox-Material. Flatpak apps see ~/.themes, not /usr/share/themes, and cannot follow symlinks
[positional-arguments]
pick *names:
    #!/usr/bin/env bash
    set -euo pipefail
    dest="${THEMES_DEST:-$HOME/.themes}"
    # Every theme folder of every scheme: <scheme>/themes/<Name>
    names=(); paths=()
    for d in */themes/*/; do names+=("$(basename "$d")"); paths+=("${d%/}"); done
    if [ "${#names[@]}" -eq 0 ]; then echo "No themes found (run this from the repo root)"; exit 1; fi
    on=()
    for i in "${!names[@]}"; do on[i]=0; done
    if [ "$#" -gt 0 ]; then
        for want in "$@"; do
            found=0
            for i in "${!names[@]}"; do if [ "${names[i]}" = "$want" ]; then on[i]=1; found=1; fi; done
            [ "$found" -eq 1 ] || { echo "'$want' is not a theme in this repo (see: just list-themes)"; exit 1; }
        done
    else
        # Preselect what is already in the destination, or the plain GTK theme of each scheme on a first run
        any=0
        for i in "${!names[@]}"; do if [ -e "$dest/${names[i]}" ]; then on[i]=1; any=1; fi; done
        if [ "$any" -eq 0 ]; then
            for i in "${!names[@]}"; do case "${names[i]}" in *-Shell-*) ;; *) on[i]=1 ;; esac; done
        fi
        if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
            pre=""; for i in "${!names[@]}"; do if [ "${on[i]}" -eq 1 ]; then pre="${pre:+$pre,}${names[i]}"; fi; done
            picked=$(gum choose --no-limit --selected="$pre" --header "Themes to copy into $dest (space toggles, enter confirms)" "${names[@]}" || true)
            for i in "${!names[@]}"; do on[i]=0; if printf '%s\n' "$picked" | grep -qx -- "${names[i]}"; then on[i]=1; fi; done
        else
            while true; do
                echo; echo "Themes to copy into $dest:"
                for i in "${!names[@]}"; do
                    mark=" "; if [ "${on[i]}" -eq 1 ]; then mark="x"; fi
                    printf ' %2d) [%s] %s\n' "$((i+1))" "$mark" "${names[i]}"
                done
                read -r -p "Number toggles, a = all, n = none, Enter = install, q = quit: " a || a=q
                case "$a" in
                    "") break ;;
                    q) echo "Nothing installed."; exit 0 ;;
                    a) for i in "${!names[@]}"; do on[i]=1; done ;;
                    n) for i in "${!names[@]}"; do on[i]=0; done ;;
                    *[!0-9]*) echo "Not a number: $a" ;;
                    *) if [ "$a" -ge 1 ] && [ "$a" -le "${#names[@]}" ]; then i=$((a-1)); on[i]=$((1-on[i])); else echo "Out of range: $a"; fi ;;
                esac
            done
        fi
    fi
    mkdir -p "$dest"
    count=0
    for i in "${!names[@]}"; do
        if [ "${on[i]}" -ne 1 ]; then continue; fi
        rm -rf "${dest:?}/${names[i]}"
        cp -a "${paths[i]}" "$dest/${names[i]}"
        echo "Installed ${names[i]} -> $dest/${names[i]}"
        count=$((count+1))
    done
    if [ "$count" -eq 0 ]; then echo "Nothing selected."; else echo "Restart GTK apps (and Flatpaks) to pick up the changes; select a Shell theme with the User Themes extension."; fi

# List the installable theme names
list-themes:
    @for d in */themes/*/; do basename "$d"; done

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
