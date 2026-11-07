# gnome-themes: one directory per colour scheme; each has palette.toml and themes/<Name>/ folders that are
# installed as-is into a themes directory (GTK3, plain GTK4 and GNOME Shell); libadwaita/ is a USER-level file (just install-libadwaita).
# `just install` is the easy way: a checklist that copies the themes you choose into ~/.themes. Needs only just and bash.

default:
    @just --list

# Regenerate the GTK3, GTK4 and GNOME Shell CSS of a scheme from the toolkits' own stock stylesheets (needs python3-gobject, GTK 3, GTK 4 and gnome-shell)
[group('develop')]
generate theme="gruvbox-material":
    #!/usr/bin/env bash
    set -euo pipefail
    name=$(awk -F'"' '/^gtk_name/ {print $2}' {{theme}}/palette.toml)
    export PYTHONDONTWRITEBYTECODE=1
    python3 -I tools/gtk3-theme-gen.py --palette={{theme}}/palette.toml --out={{theme}}/themes/$name/gtk-3.0
    python3 -I tools/gtk4-theme-gen.py --palette={{theme}}/palette.toml --out={{theme}}/themes/$name/gtk-4.0
    python3 -I tools/shell-theme-gen.py --palette={{theme}}/palette.toml --out={{theme}}/themes

# Install every theme folder of a scheme into a themes directory (system: /usr/share/themes; per user: ~/.themes as real copies, Flatpak cannot follow symlinks)
[group('install')]
install-system theme="gruvbox-material" dest="/usr/share/themes":
    mkdir -p "{{dest}}"
    cp -a {{theme}}/themes/. "{{dest}}/"

# Install themes from a checklist, one entry per colour scheme (needs only just and bash). Copies every theme folder of the chosen schemes into ~/.themes as real files (override with THEMES_DEST=DIR). Give scheme names (gruvbox-material) or single folder names (Gruvbox-Material-Shell-Dark) to skip the prompt. Flatpak apps see ~/.themes, not /usr/share/themes, and cannot follow symlinks
[group('install')]
[positional-arguments]
install *names:
    #!/usr/bin/env bash
    set -euo pipefail
    dest="${THEMES_DEST:-$HOME/.themes}"
    # One entry per scheme (a directory with a palette.toml and a themes/ folder), described by what it contains
    schemes=(); labels=()
    for p in */palette.toml; do
        sc="${p%%/*}"
        [ -d "$sc/themes" ] || continue
        gtk=""; shell=""
        for d in "$sc"/themes/*/; do
            n=$(basename "$d")
            case "$n" in
                *-Shell-*) v="${n##*-Shell-}"; shell="${shell:+$shell/}$(printf '%s' "$v" | tr 'A-Z' 'a-z')" ;;
                *) gtk="GTK 3/4" ;;
            esac
        done
        what="${gtk}${gtk:+${shell:+ + }}${shell:+GNOME Shell $shell}"
        schemes+=("$sc"); labels+=("$sc  ($what)")
    done
    if [ "${#schemes[@]}" -eq 0 ]; then echo "No schemes found (run this from the repo root)"; exit 1; fi
    folders_of() { for d in "$1"/themes/*/; do basename "$d"; done; }
    on=()
    for i in "${!schemes[@]}"; do on[i]=0; done
    if [ "$#" -gt 0 ]; then
        singles=()
        for want in "$@"; do
            found=0
            for i in "${!schemes[@]}"; do
                if [ "${schemes[i]}" = "$want" ]; then on[i]=1; found=1; fi
                if [ "$found" -eq 0 ] && [ -d "${schemes[i]}/themes/$want" ]; then singles+=("${schemes[i]}/themes/$want"); found=1; fi
            done
            [ "$found" -eq 1 ] || { echo "'$want' is neither a scheme nor a theme folder here (see: just list)"; exit 1; }
        done
    else
        singles=()
        # Preselect schemes that are already in the destination, or every scheme on a first run
        any=0
        for i in "${!schemes[@]}"; do
            while read -r f; do if [ -e "$dest/$f" ]; then on[i]=1; any=1; fi; done < <(folders_of "${schemes[i]}")
        done
        if [ "$any" -eq 0 ]; then for i in "${!schemes[@]}"; do on[i]=1; done; fi
        if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
            pre=""; for i in "${!schemes[@]}"; do if [ "${on[i]}" -eq 1 ]; then pre="${pre:+$pre,}${labels[i]}"; fi; done
            picked=$(gum choose --no-limit --selected="$pre" --header "Themes to copy into $dest (x toggles, enter installs)" "${labels[@]}" || true)
            for i in "${!schemes[@]}"; do on[i]=0; if printf '%s\n' "$picked" | grep -qxF -- "${labels[i]}"; then on[i]=1; fi; done
        else
            while true; do
                echo; echo "Themes to copy into $dest:"
                for i in "${!schemes[@]}"; do
                    mark=" "; if [ "${on[i]}" -eq 1 ]; then mark="x"; fi
                    printf ' %2d) [%s] %s\n' "$((i+1))" "$mark" "${labels[i]}"
                done
                read -r -p "Number toggles, a = all, n = none, Enter = install, q = quit: " a || a=q
                case "$a" in
                    "") break ;;
                    q) echo "Nothing installed."; exit 0 ;;
                    a) for i in "${!schemes[@]}"; do on[i]=1; done ;;
                    n) for i in "${!schemes[@]}"; do on[i]=0; done ;;
                    *[!0-9]*) echo "Not a number: $a" ;;
                    *) if [ "$a" -ge 1 ] && [ "$a" -le "${#schemes[@]}" ]; then i=$((a-1)); on[i]=$((1-on[i])); else echo "Out of range: $a"; fi ;;
                esac
            done
        fi
    fi
    mkdir -p "$dest"
    count=0
    copy() { rm -rf "${dest:?}/$(basename "$1")"; cp -a "$1" "$dest/$(basename "$1")"; echo "Installed $(basename "$1") -> $dest/$(basename "$1")"; count=$((count+1)); }
    for i in "${!schemes[@]}"; do
        if [ "${on[i]}" -ne 1 ]; then continue; fi
        for d in "${schemes[i]}"/themes/*/; do copy "${d%/}"; done
    done
    for d in "${singles[@]}"; do copy "$d"; done
    if [ "$count" -eq 0 ]; then echo "Nothing selected (in the checklist, x ticks an entry and enter installs the ticked ones)."; else echo "Restart GTK apps (and Flatpaks) to pick up the changes; select a Shell theme with the User Themes extension."; fi

[group('install')]
list:
    @for d in */themes/*/; do basename "$d"; done

# Install the libadwaita named-colour file as ~/.config/gtk-4.0/gtk.css (libadwaita apps ignore the GTK theme and read only this user stylesheet). Never overwrites a different file unless force=force (then keeps a .bak)
[group('install')]
install-libadwaita theme="gruvbox-material" force="":
    #!/usr/bin/env bash
    set -euo pipefail
    src="{{theme}}/libadwaita/gtk.css"
    dest="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-4.0/gtk.css"
    mkdir -p "$(dirname "$dest")"
    if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then
        if [ "{{force}}" != "force" ]; then
            echo "$dest exists and differs from $src; not overwriting."
            echo "Review: diff $src $dest   -- then: just install-libadwaita {{theme}} force"
            exit 1
        fi
        cp -L --backup=numbered "$dest" "$dest.bak" && echo "kept the old file as $dest.bak"
    fi
    cp "$src" "$dest" && echo "installed $dest"
