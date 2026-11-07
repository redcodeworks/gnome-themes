# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terminal-inspired colour schemes for GNOME (GTK 3, GTK 4/libadwaita, GNOME Shell) plus an installer for the themes and for icon sets. A theme is a top-level directory (`gruvbox-material`, `nordic`, `dracula`, `catppuccin`, ...). Each theme takes the *stock* stylesheet unchanged and replaces **colour values only**; selectors, geometry and assets stay stock. The one deliberate addition is a single marked calendar override block at the end of every generated Shell stylesheet. `README.md` is the user-facing documentation; `AGENTS.md` is a notice aimed at outside agents.

## Commands

Public recipes (ten, all thin calls into `tools/themectl.sh`; run from the repo root): `list-themes`, `install-themes [scheme]`, `update-themes`, `remove-themes [scheme]`, `switch-theme [scheme] [accent]`, and the same five for icons (`*-icons`, `switch-icons`). Without a name, install/remove/switch show a checklist (SPACE ticks, ENTER confirms, q cancels). `THEMES_DEST`, `ICONS_DEST`, `ICON_SOURCES`, `ICONS_URL`, `GNOME_THEMES_CACHE` and `FORCE=1` redirect or override the installer, which is how tests stay out of the real home.

Development (private recipes; need python3-gobject, GTK 3, GTK 4 and gnome-shell installed):
- `just generate [scheme|all]` regenerates everything for a scheme (palette, GTK3/GTK4/Shell themes, libadwaita file, accent maps). Generated files are committed; never hand-edit them.
- `just test <scheme>` or `python3 -I tools/selftest.py <scheme> [contrast|gtk3|gtk4|shell|all]` runs the checks for one scheme.
- `tools/test.sh [--rebuild] [scheme ...]` is the whole suite (lint, hygiene, regeneration, selftest per scheme, install/switch/update/remove for every scheme and accent, icon recipes). It builds a cached Fedora 45 image from `tools/test.Containerfile` + `tools/test-packages.txt` and runs itself in a throwaway podman/docker container with the repo mounted read-only. It tests the **committed HEAD** (a fresh clone), so commit before running it.

## Architecture

**Generation pipeline** (needs several files to see): `<scheme>/scheme.toml` (roles per variant, the six terminal ANSI accents, optional seventh `orange`, `default_accent`) -> `tools/palette-from-scheme.py` derives `<scheme>/palette.toml` (ramps, colour families, exact overrides; the fixed derivation rules are documented in its header) -> `tools/gtk3-theme-gen.py`, `gtk4-theme-gen.py` and `shell-theme-gen.py` read the **stock** CSS from the installed libraries (GTK3 Adwaita and GTK4 Default resources, `gnome-shell-theme.gresource`) and replace colour tokens through the shared engine `tools/themegen.py` -> `<scheme>/themes/<Name>/...`; `tools/libadwaita-gen.py` writes `<scheme>/libadwaita/gtk.css`; `tools/ptyxis-gen.py` writes the Ptyxis palette `<scheme>/ptyxis/gnome-themes-<scheme>.palette` straight from `scheme.toml` (rules in its header; optional `[<variant>.terminal]` tables hold real blacks/brights with their source; shared helpers in `tools/schemeroles.py`). The stock files are recoloured in place because `@define-color` overrides do nothing visible in GTK 3.24 (colours are inlined) and St has no such feature.

**Structure guarantee**: `tools/selftest.py` masks colour tokens in the stock file and the generated file and requires 0 differing lines (the calendar override block is stripped first and checked separately). Stock drift in a newer Fedora therefore fails the regeneration check: run `just generate <scheme>` and commit.

**Accents**: `tools/accent-maps-gen.py` re-runs the recolour per accent, diffs token by token and writes `<scheme>/accents/<accent>.{dark,light}.sed` plus `accents/list`. The maps are two-phase sed scripts (token -> placeholder -> new token) and are verified against the directly generated files. Some `accent_fg` / orange role values are nudged by a few units so every sed key token stays unique (the generated `palette.toml` header says which). Dark-only schemes fill the GTK light slot from the dark palette and have no Shell-Light folder.

**Installer** (`tools/themectl.sh`, one script, `themes` and `icons` kinds): themes copy from the checkout (`update-themes` does `git fetch` + `pull --ff-only` first); icon sets come from the sources in `tools/icon-sources.conf` (`top`, `root` and `script` layouts; Tela and Fluent run their upstream `install.sh` into a temp dir), cloned under `~/.cache/gnome-themes/icons/<source>`. Each set's own folder is replaced wholesale, never the whole destination. Installed folders carry a `.gnome-themes` marker; a same-named folder without it (for example a third-party `Dracula`) is only replaced after a `y` at the prompt (or `FORCE=1`). The Ptyxis palette is a marked single file in `PTYXIS_PALETTES` (same collision guard; install/update/remove copy, refresh, delete it; `switch-theme` sets the dconf `palette` key of the default profile and of profiles that already have one). Flatpak access is managed here too (`fp_*` in `tools/themectl.sh`): after `switch-theme` it offers (prompt, default no; no terminal: prints the command) the missing global read-only entries of one list, records only what it added in `$XDG_STATE_HOME/gnome-themes/flatpak-overrides`, and after the last theme and icon set (marker files) is removed it offers to undo exactly the recorded entries; never silent, no new recipe. `switch-theme` applies the accent (sed maps over the installed copies, remembered in `$XDG_STATE_HOME/gnome-themes/accents`), sets the GTK and Shell themes (dconf fallback when gsettings lacks the User Themes schema) and the libadwaita file `~/.config/gtk-4.0/gtk.css` (replaced silently only if generated by gnome-themes or a `.bak` exists, otherwise it asks).

## Workflow

`main` is protected: work goes to `testing`, CI (`.github/workflows/ci.yml`: job `test` runs `tools/test.sh` in a Fedora 45 container, job `secrets` runs gitleaks) must pass, and a pull request `testing` -> `main` is then merged (see README, Contributing). CI shellcheck runs at warning level.

## Scope and delegation

- This repo is its own Claude project: work only inside it. Never edit anything outside it (other repos, the real themes or icons directories, home-directory configs, live gsettings/dconf). Tests use temp dirs and `THEMES_DEST` / `ICONS_DEST`, as `tools/test.sh` does.
- Anything that needs the outside (applying a theme on the desktop, a live check in the running Shell, a change in another repo) is not done here. Report it as a request under `Needs from hub:` to whoever spawned the session, who handles or delegates it.
- Work on this repo from other sessions goes through a project agent spawned by that hub, not through direct edits to these files.

Licences: tooling and docs MIT (`LICENSE`); each `*/themes/<Name>/` folder carries its own LGPL `LICENSE` because the generated CSS derives from GTK / GNOME Shell stock stylesheets. A new scheme needs its palette credit in `NOTICE`, provenance notes in `scheme.toml`, and the folder `LICENSE` (`just generate` copies it).
