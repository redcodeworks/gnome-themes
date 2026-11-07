#!/usr/bin/env bash
# Install, list, update, remove and switch themes (this repo) and icon sets (an icon repo, Papirus by
# default) in the user's home. Needs only bash and git; gum is used for the checklists if present.
#   themectl.sh <themes|icons> <install|list|update|remove|switch> [name]
# A theme is a top-level directory of this repo (a scheme, e.g. gruvbox-material); an icon set is a
# top-level directory of the icon repo (e.g. Papirus-Dark). Without a name, install/remove/switch ask.
# Environment: THEMES_DEST (~/.themes), ICONS_DEST (~/.local/share/icons), ICONS_URL (Papirus),
# GNOME_THEMES_CACHE (~/.cache/gnome-themes, holds the icon repo clone).
set -euo pipefail

kind="${1:-}"; action="${2:-}"; want="${3:-}"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cache="${GNOME_THEMES_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/gnome-themes}"
cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
case "$kind" in
    themes) dest="${THEMES_DEST:-$HOME/.themes}"; noun="theme" ;;
    icons)  dest="${ICONS_DEST:-${XDG_DATA_HOME:-$HOME/.local/share}/icons}"; noun="icon set"
            icons_url="${ICONS_URL:-https://github.com/PapirusDevelopmentTeam/papirus-icon-theme.git}"
            src="$cache/icons" ;;
    *) echo "usage: themectl.sh <themes|icons> <install|list|update|remove|switch> [name]"; exit 2 ;;
esac

# ---- sources -------------------------------------------------------------------------------------
sync_icons() {   # clone the icon repo, or refresh the clone when $1 = refresh
    if [ -d "$src/.git" ]; then
        if [ "${1:-}" = refresh ]; then
            git -C "$src" fetch --quiet --depth 1 origin HEAD && git -C "$src" reset --quiet --hard FETCH_HEAD
        fi
    else
        mkdir -p "$cache"; git clone --quiet --depth 1 "$icons_url" "$src"
    fi
}
sync_themes() {  # fast-forward this checkout when it has a remote; harmless otherwise
    if git -C "$root" remote get-url origin >/dev/null 2>&1; then
        git -C "$root" pull --quiet --ff-only 2>/dev/null || echo "(could not update the checkout; using what is here)"
    fi
}

items=(); labels=()
load_items() {
    items=(); labels=()
    if [ "$kind" = themes ]; then
        for p in "$root"/*/palette.toml; do
            sc=$(basename "$(dirname "$p")"); [ -d "$root/$sc/themes" ] || continue
            gtk=""; shell=""
            for d in "$root/$sc"/themes/*/; do
                n=$(basename "$d")
                case "$n" in
                    *-Shell-*) v="${n##*-Shell-}"; shell="${shell:+$shell/}$(printf '%s' "$v" | tr 'A-Z' 'a-z')" ;;
                    *) gtk="GTK 3/4" ;;
                esac
            done
            what="${gtk}${gtk:+${shell:+ + }}${shell:+GNOME Shell $shell}"
            items+=("$sc"); labels+=("$sc  ($what)")
        done
    else
        for d in "$src"/*/; do
            [ -f "$d/index.theme" ] || continue
            items+=("$(basename "$d")"); labels+=("$(basename "$d")")
        done
    fi
}
folders_of() {   # installable folder names of item $1
    if [ "$kind" = themes ]; then for d in "$root/$1"/themes/*/; do basename "$d"; done; else echo "$1"; fi
}
src_of() {       # source path of folder $1 belonging to item $2
    if [ "$kind" = themes ]; then echo "$root/$2/themes/$1"; else echo "$src/$1"; fi
}
is_installed() { local f; while read -r f; do [ -e "$dest/$f" ] && return 0; done < <(folders_of "$1"); return 1; }
index_of() { local i; for i in "${!items[@]}"; do [ "${items[i]}" = "$1" ] && { echo "$i"; return 0; }; done; return 1; }

# ---- prompts -------------------------------------------------------------------------------------
have_gum() { command -v gum >/dev/null 2>&1 && [ -t 0 ]; }
# choose_many HEADER IDX... : tick entries from the candidate indexes; sets chosen=(indexes). Preselected = on[]
chosen=(); on=()
choose_many() {
    local header="$1"; shift; local cand=("$@") i a pre="" picked mark
    chosen=()
    if have_gum; then
        for i in "${cand[@]}"; do if [ "${on[i]:-0}" -eq 1 ]; then pre="${pre:+$pre,}${labels[i]}"; fi; done
        local ls=(); for i in "${cand[@]}"; do ls+=("${labels[i]}"); done
        picked=$(gum choose --no-limit --selected="$pre" --header "$header (x toggles, enter confirms)" "${ls[@]}" || true)
        for i in "${cand[@]}"; do if printf '%s\n' "$picked" | grep -qxF -- "${labels[i]}"; then chosen+=("$i"); fi; done
    else
        while true; do
            echo; echo "$header:"
            for i in "${!cand[@]}"; do
                mark=" "; if [ "${on[${cand[i]}]:-0}" -eq 1 ]; then mark="x"; fi
                printf ' %2d) [%s] %s\n' "$((i+1))" "$mark" "${labels[${cand[i]}]}"
            done
            read -r -p "Number toggles, a = all, n = none, Enter = confirm, q = quit: " a || a=q
            case "$a" in
                "") break ;;
                q) echo "Cancelled."; exit 0 ;;
                a) for i in "${cand[@]}"; do on[i]=1; done ;;
                n) for i in "${cand[@]}"; do on[i]=0; done ;;
                *[!0-9]*) echo "Not a number: $a" ;;
                *) if [ "$a" -ge 1 ] && [ "$a" -le "${#cand[@]}" ]; then i=${cand[$((a-1))]}; on[i]=$((1-${on[i]:-0})); else echo "Out of range: $a"; fi ;;
            esac
        done
        for i in "${cand[@]}"; do if [ "${on[i]:-0}" -eq 1 ]; then chosen+=("$i"); fi; done
    fi
}
# choose_one HEADER IDX... : pick exactly one; sets pick=index (empty when cancelled)
pick=""
choose_one() {
    local header="$1"; shift; local cand=("$@") i a picked
    pick=""
    if have_gum; then
        local ls=(); for i in "${cand[@]}"; do ls+=("${labels[i]}"); done
        picked=$(gum choose --header "$header" "${ls[@]}" || true)
        for i in "${cand[@]}"; do if [ "${labels[i]}" = "$picked" ]; then pick="$i"; fi; done
    else
        echo; echo "$header:"
        for i in "${!cand[@]}"; do printf ' %2d) %s\n' "$((i+1))" "${labels[${cand[i]}]}"; done
        read -r -p "Number (Enter cancels): " a || a=""
        if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#cand[@]}" ]; then pick="${cand[$((a-1))]}"; fi
    fi
}

# ---- actions -------------------------------------------------------------------------------------
copy_folder() {  # copy folder $1 of item $2 into dest
    local f="$1" it="$2"
    mkdir -p "$dest"; rm -rf "${dest:?}/$f"; cp -a "$(src_of "$f" "$it")" "$dest/$f"
    if [ "$kind" = icons ]; then gtk-update-icon-cache -q -f -t "$dest/$f" 2>/dev/null || true; fi
    echo "Installed $f -> $dest/$f"
}
current_value() {  # the value the desktop currently uses (theme or icon set)
    if [ "$kind" = themes ]; then gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'" || true
    else gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'" || true; fi
}
# resolve $want to an index, or explain
resolve() { index_of "$want" || { echo "'$want' is not a $noun here. Available: ${items[*]}" >&2; exit 1; }; }

case "$action" in
    list)
        if [ "$kind" = icons ]; then sync_icons; fi
        load_items
        for i in "${!items[@]}"; do
            if is_installed "${items[i]}"; then echo "✓ ${labels[i]}"; else echo "  ${labels[i]}"; fi
        done ;;

    install)
        if [ "$kind" = icons ]; then sync_icons; fi
        load_items
        [ "${#items[@]}" -gt 0 ] || { echo "No ${noun}s found"; exit 1; }
        if [ -n "$want" ]; then
            i=$(resolve); chosen=("$i")
        else
            any=0; for i in "${!items[@]}"; do on[i]=0; if is_installed "${items[i]}"; then on[i]=1; any=1; fi; done
            if [ "$any" -eq 0 ]; then
                for i in "${!items[@]}"; do
                    if [ "$kind" = themes ]; then on[i]=1; else case "${items[i]}" in Papirus|Papirus-Dark) on[i]=1 ;; esac; fi
                done
            fi
            choose_many "${noun^}s to install into $dest" "${!items[@]}"
        fi
        [ "${#chosen[@]}" -gt 0 ] || { echo "Nothing selected (in the checklist, x ticks an entry and enter installs the ticked ones)."; exit 0; }
        for i in "${chosen[@]}"; do while read -r f; do copy_folder "$f" "${items[i]}"; done < <(folders_of "${items[i]}"); done
        if [ "$kind" = themes ]; then echo "Next: run switch-theme to use it."; else echo "Next: run switch-icons to use it."; fi ;;

    update)
        if [ "$kind" = icons ]; then sync_icons refresh; else sync_themes; fi
        load_items; n=0
        for i in "${!items[@]}"; do
            while read -r f; do if [ -e "$dest/$f" ]; then copy_folder "$f" "${items[i]}"; n=$((n+1)); fi; done < <(folders_of "${items[i]}")
        done
        [ "$n" -gt 0 ] || echo "None of the ${noun}s from this source is installed in $dest." ;;

    remove)
        if [ "$kind" = icons ]; then sync_icons; fi
        load_items; inst=()
        for i in "${!items[@]}"; do if is_installed "${items[i]}"; then inst+=("$i"); fi; done
        [ "${#inst[@]}" -gt 0 ] || { echo "No ${noun}s from this source are installed in $dest."; exit 0; }
        if [ -n "$want" ]; then
            i=$(resolve); is_installed "${items[i]}" || { echo "'$want' is not installed."; exit 1; }
            chosen=("$i")
        else
            for i in "${!items[@]}"; do on[i]=0; done
            choose_many "${noun^}s to remove from $dest" "${inst[@]}"
        fi
        [ "${#chosen[@]}" -gt 0 ] || { echo "Nothing selected."; exit 0; }
        cur=$(current_value)
        for i in "${chosen[@]}"; do
            while read -r f; do
                if [ -e "$dest/$f" ] || [ -L "$dest/$f" ]; then
                    rm -rf "${dest:?}/$f"; echo "Removed $dest/$f"
                    if [ "$f" = "$cur" ]; then echo "  note: $f is the one currently in use; run switch to choose another."; fi
                fi
            done < <(folders_of "${items[i]}")
        done ;;

    switch)
        if [ "$kind" = icons ]; then sync_icons; fi
        load_items; inst=()
        for i in "${!items[@]}"; do if is_installed "${items[i]}"; then inst+=("$i"); fi; done
        [ "${#inst[@]}" -gt 0 ] || { echo "No ${noun}s from this source are installed; install one first."; exit 1; }
        if [ -n "$want" ]; then
            i=$(resolve); is_installed "${items[i]}" || { echo "'$want' is not installed; install it first."; exit 1; }
        else
            choose_one "Switch to which $noun?" "${inst[@]}"; i="$pick"
            [ -n "$i" ] || { echo "Cancelled."; exit 0; }
        fi
        set_ini() {  # set_ini KEY VALUE: rewrite the key in the GTK settings.ini files that already have it
            local f; for f in "$cfg/gtk-3.0/settings.ini" "$cfg/gtk-4.0/settings.ini"; do
                if [ -f "$f" ] && grep -q "^$1=" "$f"; then sed -i "s|^$1=.*|$1=$2|" "$f"; fi
            done
        }
        if [ "$kind" = icons ]; then
            gsettings set org.gnome.desktop.interface icon-theme "${items[i]}"
            set_ini gtk-icon-theme-name "${items[i]}"
            echo "Icon theme is now ${items[i]}."
        else
            sc="${items[i]}"; gtk=""; shell_d=""; shell_l=""
            while read -r f; do
                case "$f" in
                    *-Shell-Dark) shell_d="$f" ;;
                    *-Shell-Light) shell_l="$f" ;;
                    *-Shell-*) ;;
                    *) [ -n "$gtk" ] || gtk="$f" ;;
                esac
            done < <(folders_of "$sc")
            if [ -n "$gtk" ]; then
                gsettings set org.gnome.desktop.interface gtk-theme "$gtk"; set_ini gtk-theme-name "$gtk"
                echo "GTK theme is now $gtk."
            fi
            shell="$shell_d"
            if ! gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | grep -qi dark; then shell="${shell_l:-$shell_d}"; fi
            if [ -n "$shell" ] && gsettings list-schemas 2>/dev/null | grep -qx org.gnome.shell.extensions.user-theme; then
                gsettings set org.gnome.shell.extensions.user-theme name "$shell"
                echo "Shell theme is now $shell (reload it by logging out and in, or toggling the User Themes extension)."
            fi
            # libadwaita apps ignore the GTK theme and read only the user stylesheet
            la="$root/$sc/libadwaita/gtk.css"; target="$cfg/gtk-4.0/gtk.css"
            if [ -f "$la" ]; then
                mkdir -p "$(dirname "$target")"
                if [ ! -e "$target" ]; then cp "$la" "$target"; echo "Installed $target (libadwaita apps)."
                elif cmp -s "$la" "$target"; then echo "$target is already current."
                elif [ -t 0 ]; then
                    read -r -p "$target differs from the scheme's libadwaita file. Replace it (the old one is kept as .bak)? [y/N] " a || a=n
                    case "$a" in [yY]*) cp -L --backup=numbered "$target" "$target.bak"; cp "$la" "$target"; echo "Replaced $target (old one: $target.bak)." ;; *) echo "Left $target alone." ;; esac
                else echo "$target differs from the scheme's libadwaita file; left alone (run in a terminal to replace it)."
                fi
            fi
            echo "Restart GTK apps to pick up the new theme."
        fi ;;

    *) echo "usage: themectl.sh <themes|icons> <install|list|update|remove|switch> [name]"; exit 2 ;;
esac
