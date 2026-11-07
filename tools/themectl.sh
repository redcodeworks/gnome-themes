#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Install, list, update, remove and switch themes (this repo) and icon sets (several icon repos, see
# tools/icon-sources.conf) in the user's home. Needs only bash and git; gum is used for the checklists if present.
#   themectl.sh <themes|icons> <install|list|update|remove|switch> [name] [accent]
# A theme is a top-level directory of this repo (a scheme, e.g. gruvbox-material); an icon set belongs to a source of
# tools/icon-sources.conf (e.g. Papirus-Dark from papirus, Tela-nord from tela). Without a name, install/remove/switch ask.
# Workflow: install-themes copies from this checkout; update-themes does git fetch + pull --ff-only first. Icons: clone the
# source into the cache when missing, else bring it to the latest upstream (install and update both), then replace each
# set's folder in the destination (remove it, copy the fresh one; unrelated folders there are never touched).
# Themes have a per-scheme accent (one of the six terminal colours listed in <scheme>/accents/list): switch asks for it
# (or takes it as the 4th argument), remembers it in $XDG_STATE_HOME/gnome-themes/accents (lines scheme=accent), and
# install/update re-apply the remembered one by running the scheme's sed token map over the installed copies.
# Environment: THEMES_DEST (~/.themes), ICONS_DEST (~/.local/share/icons), ICONS_URL (replaces the papirus source's URL),
# ICON_SOURCES (another registry file), GNOME_THEMES_CACHE (~/.cache/gnome-themes; icon clones in icons/<source>).
set -euo pipefail

kind="${1:-}"; action="${2:-}"; want="${3:-}"; accent_arg="${4:-}"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cache="${GNOME_THEMES_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/gnome-themes}"
cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
state="${XDG_STATE_HOME:-$HOME/.local/state}/gnome-themes"
case "$kind" in
    themes) dest="${THEMES_DEST:-$HOME/.themes}"; noun="theme" ;;
    icons)  dest="${ICONS_DEST:-${XDG_DATA_HOME:-$HOME/.local/share}/icons}"; noun="icon set" ;;
    *) echo "usage: themectl.sh <themes|icons> <install|list|update|remove|switch> [name] [accent]"; exit 2 ;;
esac

# ---- accents (themes only) -----------------------------------------------------------------------------------
# state file lines: key=value
state_get() { [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | head -n1 || true; }
state_set() { mkdir -p "$(dirname "$1")"; { [ -f "$1" ] && grep -v "^$2=" "$1" || true; echo "$2=$3"; } > "$1.new"; mv "$1.new" "$1"; }
state_del() { [ -f "$1" ] || return 0; { grep -v "^$2=" "$1" || true; } > "$1.new"; mv "$1.new" "$1"; }
acc_names=(); acc_dark=(); acc_light=(); acc_default=""
load_accents() {   # accents of scheme $1 from <scheme>/accents/list (name dark light|- [default])
    acc_names=(); acc_dark=(); acc_light=(); acc_default=""
    local n d l f
    [ -f "$root/$1/accents/list" ] || return 0
    while read -r n d l f; do
        case "$n" in ""|"#"*) continue ;; esac
        acc_names+=("$n"); acc_dark+=("$d"); acc_light+=("$l"); if [ "$f" = default ]; then acc_default="$n"; fi
    done < "$root/$1/accents/list"
}
current_accent() { local a; a=$(state_get "$state/accents" "$1"); load_accents "$1"; [ -n "$a" ] && printf '%s\n' "${acc_names[@]}" | grep -qx "$a" && echo "$a" || echo "$acc_default"; }
accent_maps() {    # sets map_dark, map_light for scheme $1 accent $2 (light falls back to dark for dark-only schemes)
    map_dark="$root/$1/accents/$2.dark.sed"; map_light="$root/$1/accents/$2.light.sed"
    [ -f "$map_light" ] || map_light="$map_dark"
}
apply_accent() {   # apply_accent SCHEME ACCENT [FOLDER]: run the token maps over the installed copies of SCHEME
    local sc="$1" a="$2" f d
    load_accents "$sc"; [ -n "$a" ] && [ "$a" != "$acc_default" ] || return 0
    accent_maps "$sc" "$a"
    [ -f "$map_dark" ] || { echo "No accent map for $sc/$a" >&2; return 1; }
    while read -r f; do
        d="$dest/$f"
        case "$f" in
            *-Shell-Dark)  sed -i -f "$map_dark" "$d/gnome-shell/gnome-shell.css" ;;
            *-Shell-Light) sed -i -f "$map_light" "$d/gnome-shell/gnome-shell.css" ;;
            *-Shell-*) ;;
            *) for v in gtk-3.0 gtk-4.0; do
                   [ -f "$d/$v/gtk.css" ] && sed -i -f "$map_light" "$d/$v/gtk.css"
                   [ -f "$d/$v/gtk-dark.css" ] && sed -i -f "$map_dark" "$d/$v/gtk-dark.css"
               done ;;
        esac
    done < <(if [ -n "${3:-}" ]; then echo "$3"; else folders_of "$sc"; fi)
}
accent_label() {   # label of accent index $1: name, hex (dark / light)
    local l="${acc_names[$1]}  ${acc_dark[$1]}"; [ "${acc_light[$1]}" != "-" ] && l="$l / ${acc_light[$1]}"; echo "$l"
}
# choose_accent SCHEME: sets accent_pick (the name) from the six accents; Enter/cancel keeps the current one
accent_pick=""
choose_accent() {
    local sc="$1" cur i a picked ls=() curlabel=""
    cur=$(current_accent "$sc"); accent_pick="$cur"; load_accents "$sc"
    [ "${#acc_names[@]}" -gt 0 ] || { accent_pick=""; return 0; }
    for i in "${!acc_names[@]}"; do
        l=$(accent_label "$i"); if [ "${acc_names[i]}" = "$cur" ]; then l="$l  (current)"; curlabel="$l"; fi; ls+=("$l")
    done
    if have_gum; then
        picked=$(gum choose --header "Accent colour for $sc" --selected="$curlabel" "${ls[@]}" || true)
        for i in "${!acc_names[@]}"; do if [ "${ls[i]}" = "$picked" ]; then accent_pick="${acc_names[i]}"; fi; done
    else
        echo; echo "Accent colour for $sc (the scheme's six terminal colours):"
        for i in "${!ls[@]}"; do printf ' %2d) %s\n' "$((i+1))" "${ls[i]}"; done
        read -r -p "Number (Enter keeps $cur): " a || a=""
        if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#acc_names[@]}" ]; then accent_pick="${acc_names[$((a-1))]}"; fi
    fi
}

# ---- sources -------------------------------------------------------------------------------------
# Themes are copied straight from the checkout this script lives in (no cache, no network on install).
# Icon sets come from the external repos listed in tools/icon-sources.conf (name|url|layout|extra), each with a
# shallow clone under $cache/icons/<source>. Layouts: top (every top-level dir with index.theme is a set), root (the
# repo root is the set), script (sets are built by the upstream install.sh, one variant per set, in a temp dir).
conf="${ICON_SOURCES:-$root/tools/icon-sources.conf}"
src_names=(); declare -A src_url src_layout src_extra
load_sources() {
    local n u l e
    while IFS='|' read -r n u l e; do
        case "$n" in ""|"#"*) continue ;; esac
        src_names+=("$n"); src_url[$n]="$u"; src_layout[$n]="$l"; src_extra[$n]="$e"
    done < "$conf"
    if [ -n "${ICONS_URL:-}" ]; then   # override (testing): replaces the papirus source's URL, adding the source if needed
        if [ -z "${src_url[papirus]:-}" ]; then src_names+=(papirus); src_layout[papirus]=top; src_extra[papirus]=""; fi
        src_url[papirus]="$ICONS_URL"
    fi
}
clone_of() { echo "$cache/icons/$1"; }
migrate_cache() {  # before 2026-11-07 the single Papirus clone lived at $cache/icons itself
    if [ -d "$cache/icons/.git" ]; then mv "$cache/icons" "$cache/icons.legacy" && mkdir -p "$cache/icons" && mv "$cache/icons.legacy" "$cache/icons/papirus"; fi
}
ensure_clone() {   # clone source $1 when its cache dir is missing
    local d; d=$(clone_of "$1"); [ -d "$d/.git" ] && return 0
    mkdir -p "$cache/icons"; echo "Cloning $1 ..."
    git clone --quiet --depth 1 "${src_url[$1]}" "$d" 2>/dev/null || { rm -rf "${d:?}"; echo "(could not clone $1; skipping it)" >&2; return 1; }
}
refresh_source() { # bring the shallow clone of source $1 to the latest upstream; offline: keep the cache and say so
    local d; d=$(clone_of "$1")
    if [ -d "$d/.git" ]; then
        git -C "$d" fetch --quiet --depth 1 origin HEAD 2>/dev/null && git -C "$d" reset --quiet --hard FETCH_HEAD || echo "(could not refresh $1; using the cached copy)"
    else ensure_clone "$1" || true; fi
}
sync_icons() { local n; for n in "${src_names[@]}"; do ensure_clone "$n" || true; done; }
sync_themes() {    # git fetch + pull --ff-only in this checkout; quiet on a detached HEAD or a branch without upstream
    git -C "$root" remote get-url origin >/dev/null 2>&1 || return 0
    git -C "$root" fetch --quiet 2>/dev/null || { echo "(could not fetch; using the checkout as it is)"; return 0; }
    if git -C "$root" symbolic-ref -q HEAD >/dev/null && git -C "$root" rev-parse '@{u}' >/dev/null 2>&1; then
        git -C "$root" pull --quiet --ff-only 2>/dev/null || echo "(could not fast-forward the checkout; using it as it is)"
    fi
}
if [ "$kind" = icons ]; then load_sources; migrate_cache; fi

items=(); labels=(); declare -A i_src i_dir i_var
set_name() {       # set name of an icon dir $1: its index.theme Name= when that is a plain id, else $2
    local nm; nm=$(sed -n 's/^Name=//p' "$1/index.theme" 2>/dev/null | head -n1 | tr -d '\r')
    case "$nm" in ""|*[[:space:]/]*) echo "$2" ;; *) echo "$nm" ;; esac
}
add_item() { items+=("$1"); labels+=("$1  ($2)"); i_src[$1]="$2"; i_dir[$1]="$3"; i_var[$1]="$4"; }
load_items() {
    items=(); labels=(); i_src=(); i_dir=(); i_var=()
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
        local n d dd b v base
        for n in "${src_names[@]}"; do
            d=$(clone_of "$n"); [ -d "$d/.git" ] || continue
            case "${src_layout[$n]}" in
                top) for dd in "$d"/*/; do
                         [ -f "$dd/index.theme" ] || continue; b=$(basename "$dd"); add_item "$(set_name "$dd" "$b")" "$n" "$b" ""
                     done ;;
                root) add_item "$(set_name "$d" "${src_extra[$n]}")" "$n" "" "" ;;
                script) base="${n^}"
                        for v in ${src_extra[$n]}; do
                            if [ "$v" = standard ]; then add_item "$base" "$n" "" "$v"; else add_item "$base-$v" "$n" "" "$v"; fi
                        done ;;
                *) echo "icon-sources.conf: unknown layout '${src_layout[$n]}' for $n" >&2 ;;
            esac
        done
    fi
}
folders_of() {   # installable folder names of item $1 (exactly these: never a glob, so removing Tela keeps Tela-blue)
    if [ "$kind" = themes ]; then for d in "$root/$1"/themes/*/; do basename "$d"; done
    elif [ "${src_layout[${i_src[$1]}]}" = script ]; then echo "$1"; echo "$1-dark"; echo "$1-light"
    else echo "$1"; fi
}
build_dir=""
prepare_item() { # icons, script layout: run the upstream install.sh for the variant into a temp dir (never the real destination)
    [ "$kind" = icons ] || return 0
    [ "${src_layout[${i_src[$1]}]}" = script ] || return 0
    local d f; d=$(clone_of "${i_src[$1]}"); build_dir=$(mktemp -d)
    echo "Building $1 with the upstream install.sh (variant ${i_var[$1]}) ..."
    (cd "$d" && ./install.sh -d "$build_dir" "${i_var[$1]}" >/dev/null 2>&1) || { echo "install.sh failed for $1" >&2; return 1; }
    while read -r f; do [ -d "$build_dir/$f" ] || { echo "install.sh did not produce $f" >&2; return 1; }; done < <(folders_of "$1")
}
shared_bases() {  # hidden base dirs (e.g. .Fluent-base) that the installed folders of item $1 link into
    local f
    while read -r f; do [ -d "$dest/$f" ] && find "$dest/$f" -type l -printf '%l\n' 2>/dev/null; done < <(folders_of "$1") \
        | sed -n 's|^\(\.\./\)\{1,\}\(\.[^/][^/]*\)/.*|\2|p' | sort -u || true
}
finish_item() { if [ -n "$build_dir" ]; then rm -rf "${build_dir:?}"; build_dir=""; fi; }
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
copy_folder() {  # replace folder $1 of item $2 in dest: remove the set's folder, then copy the fresh one (never merge)
    local f="$1" it="$2" c
    mkdir -p "$dest"; rm -rf "${dest:?}/$f"
    if [ "$kind" = themes ]; then cp -a "$root/$it/themes/$f" "$dest/$f"
    else
        c=$(clone_of "${i_src[$it]}")
        case "${src_layout[${i_src[$it]}]}" in
            top) cp -a "$c/${i_dir[$it]}" "$dest/$f" ;;
            root) mkdir -p "$dest/$f"; (cd "$c" && tar cf - --exclude=./.git --exclude=./.github --exclude=./preview --exclude='./README*' --exclude='./LICENSE*' .) | tar xf - -C "$dest/$f" ;;
            script) cp -a "$build_dir/$f" "$dest/$f" ;;
        esac
        gtk-update-icon-cache -q -f -t "$dest/$f" 2>/dev/null || true
    fi
    if [ "$kind" = themes ]; then apply_accent "$it" "$(current_accent "$it")" "$f"; fi
    echo "Installed $f -> $dest/$f"
}
copy_item() {
    local f h
    prepare_item "$1" || return 1
    while read -r f; do copy_folder "$f" "$1"; done < <(folders_of "$1")
    if [ -n "$build_dir" ]; then   # hidden shared bases the build produced (Fluent's .Fluent-base ...): replaced too
        for h in "$build_dir"/.[!.]*; do
            [ -d "$h" ] || continue; rm -rf "${dest:?}/$(basename "$h")"; cp -a "$h" "$dest/$(basename "$h")"; echo "Installed $(basename "$h") (shared base)"
        done
    fi
    finish_item
}
refresh_for() {  # icons: refresh the clones of the sources of the named sets ($@)
    local n seen=" "
    for n in "$@"; do case "$seen" in *" ${i_src[$n]} "*) ;; *) seen="$seen${i_src[$n]} "; refresh_source "${i_src[$n]}" ;; esac; done
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
            ac=""; if [ "$kind" = themes ]; then ac="  [accent: $(current_accent "${items[i]}")]"; fi
            if is_installed "${items[i]}"; then echo "✓ ${labels[i]}$ac"; else echo "  ${labels[i]}"; fi
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
        names=(); for i in "${chosen[@]}"; do names+=("${items[i]}"); done
        if [ "$kind" = icons ]; then refresh_for "${names[@]}"; load_items; fi   # icons: always refresh the clones first
        for nm in "${names[@]}"; do copy_item "$nm"; done
        if [ "$kind" = themes ]; then echo "Next: run switch-theme to use it."; else echo "Next: run switch-icons to use it."; fi ;;

    update)
        # themes: git fetch + pull --ff-only in this checkout; icons: refresh the clones of the installed sets' sources.
        # Then every installed set's folders are removed and copied fresh (the remembered accent is re-applied).
        if [ "$kind" = icons ]; then sync_icons; fi
        load_items; n=0; inst=()
        for i in "${!items[@]}"; do if is_installed "${items[i]}"; then inst+=("${items[i]}"); fi; done
        if [ "$kind" = icons ]; then refresh_for "${inst[@]}"; load_items; else sync_themes; fi
        for nm in "${inst[@]}"; do
            if [ "$kind" = icons ]; then copy_item "$nm"; n=$((n+1))
            else while read -r f; do if [ -e "$dest/$f" ]; then copy_folder "$f" "$nm"; n=$((n+1)); fi; done < <(folders_of "$nm"); fi
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
        cur=$(current_value); bases=""
        if [ "$kind" = icons ]; then for i in "${chosen[@]}"; do bases+=$'\n'"$(shared_bases "${items[i]}")"; done; fi
        for i in "${chosen[@]}"; do
            while read -r f; do
                if [ -e "$dest/$f" ] || [ -L "$dest/$f" ]; then
                    rm -rf "${dest:?}/$f"; echo "Removed $dest/$f"
                    if [ "$f" = "$cur" ]; then echo "  note: $f is the one currently in use; run switch to choose another."; fi
                fi
            done < <(folders_of "${items[i]}")
            if [ "$kind" = themes ]; then state_del "$state/accents" "${items[i]}"; fi
        done
        # shared hidden base dirs (Fluent): remove one only when no remaining installed set links into it
        if [ "$kind" = icons ]; then
            still=""; for i in "${!items[@]}"; do if is_installed "${items[i]}"; then still+=$'\n'"$(shared_bases "${items[i]}")"; fi; done
            for b in $bases; do
                if ! printf '%s\n' "$still" | grep -qxF -- "$b" && [ -d "$dest/$b" ]; then rm -rf "${dest:?}/$b"; echo "Removed $dest/$b (shared base, no longer used)"; fi
            done
        fi ;;

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
        if [ "$kind" = themes ]; then
            # accent: argument, else the submenu; copy the scheme's folders afresh (clean) and re-apply it
            load_accents "${items[i]}"
            if [ -n "$accent_arg" ]; then
                printf '%s\n' "${acc_names[@]}" | grep -qx "$accent_arg" || { echo "'$accent_arg' is not an accent of ${items[i]}. Available: ${acc_names[*]}" >&2; exit 1; }
                accent_pick="$accent_arg"
            else choose_accent "${items[i]}"; fi
            if [ -n "$accent_pick" ]; then state_set "$state/accents" "${items[i]}" "$accent_pick"; fi
            copy_item "${items[i]}"
            [ -z "$accent_pick" ] || echo "Accent: $accent_pick."
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
                ac=$(current_accent "$sc")
                if [ -n "$ac" ] && [ "$ac" != "$acc_default" ]; then
                    accent_maps "$sc" "$ac"; tmpla=$(mktemp); trap 'rm -f "$tmpla"' EXIT
                    if [ "$map_light" = "$map_dark" ]; then sed -f "$map_dark" "$la" > "$tmpla"; else sed -f "$map_light" -f "$map_dark" "$la" > "$tmpla"; fi
                    chmod 644 "$tmpla"; la="$tmpla"
                fi
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

    *) echo "usage: themectl.sh <themes|icons> <install|list|update|remove|switch> [name] [accent]"; exit 2 ;;
esac
