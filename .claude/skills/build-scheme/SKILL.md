---
name: build-scheme
description: Add a new colour scheme (a new top-level theme directory) to gnome-themes. Starts from a Ptyxis built-in palette (by id), then hands off to the deterministic generators. Use when asked to add, port or build a scheme or theme from a colour palette.
---

# Add a scheme to gnome-themes

A scheme is a top-level directory with one `scheme.toml`; everything else (GTK 3/4, Shell, libadwaita file, accent maps, GtkSourceView styles; the terminal is a Ptyxis built-in, nothing is generated for it) is generated. Your job is only the decisions about colours; the scripts do the rest. Read `CLAUDE.md` first (colour values only, generated files are never hand-edited, structure check stays at 0 differing lines).

## 1. Decide what you are building

- The scheme's directory name (lowercase, hyphens: `tokyo-night`), its display title and whether it has a dark variant, a light variant or both (a dark-only scheme fills the GTK light slot from the dark values; do not invent a light variant).
- Check `just list-themes` and the existing `*/scheme.toml` for an existing scheme with that name.

## 2. Find the palette

Principle: the Ptyxis built-in palette, by ID, is the source of truth for every variant that has one (no "official source" override, no generated palette). Ptyxis keys a profile's palette by id (the resource file name, case-sensitive: `nord`, `Gruvbox Material`), never by display Name.

a. **Pick the built-in id per variant.** `tools/ptyxis-palette.sh list` prints `<id> <Name> <sections>` (`Light,Dark` or `flat`); `show "<id>"` prints one (`PTYXIS_BIN` overrides the binary). Mode-split families take their own flat palettes (`ptyxis = "Rosé Pine"` and `ptyxis_light = "Rosé Pine Dawn"`; switch-theme picks one by the system colour scheme); a sectioned built-in (Light and Dark in one palette) needs only `ptyxis`; where only a dark built-in exists the light variant says `no_builtin` and the dark built-in serves both modes. Several ids in one family (`solarized` vs `Solarized`, `Fairy Floss` vs `Fairy Floss Dark`): compare with `python3 -I tools/ptyxis-compare.py <scheme>` (delta E per candidate) and give the reason in `ptyxis_reason`. Many built-ins are Gogh ports (their header comment says so): credit them accordingly.

b. **Research only for what the built-in cannot give** (a light variant that has none, licence and credit text of the project the theme follows). A session without web tools must not guess: return `Needs from hub: research for <scheme>` and stop.

c. **Never invent colours silently.** If the scheme has no orange, no surface steps, no light variant and so on, derived or invented values are allowed only when marked as such in `scheme.toml` comments and in `NOTICE` (see `fairy-floss/scheme.toml`).

## 3. Draft with the script

```
just new-scheme <scheme-dir> "<ptyxis id>" ["<light id>"]
# = python3 -I tools/scheme-from-ptyxis.py <scheme-dir> <id> [<light-id>]
```

It writes a DRAFT `<scheme-dir>/scheme.toml` (it refuses to overwrite an existing scheme): Color1-6 become the six accents per variant, Foreground/Background become `fg`/`bg_deep`, black, white, brights or cursor that differ from the defaults go to `[<variant>.terminal]` with `source = "<id>"`, and `ptyxis` / `ptyxis_light` carry the ids. title/gtk_name/shell_name come from the directory name. It prints a `# TODO` list; resolve each item in the file and delete the TODO lines:

- credit line, licence and provenance notes (the colours are Ptyxis's palette of that name; credit the project that inspired the theme),
- `ptyxis_reason`: one line on which built-in and why,
- the orange role (derived by default; a scheme's own orange also needs a seventh `orange` entry in `[<variant>.ansi]`, otherwise there is none),
- the surface ladder (`bg`, `surface`, `surface_high`) and `fg_dim`/`comment`/`selection` when the scheme defines them,
- `accent_fg` overrides where an accent fails 4.5:1 with the default ink,
- `default_accent` with a one-line reason,
- dark-only or not.

## 4. Check and build with the existing pipeline

Every variant needs `[<variant>.terminal]` with `source = "<built-in id>"` (the id it declares) plus the built-in's black, white and brights, or `no_builtin = "<why>"`. A colour that must differ from the built-in because a contrast check forces it (selftest: fg on the window under 4.5:1) is a nudge, recorded as `[<variant>.nudge]` / `Foreground = { from = "<built-in>", to = "<ours>", de = <delta E>, why = "<reason>" }`; keep it small (NUDGE_MAX in `tools/ptyxis-compare.py`). `python3 -I tools/ptyxis-compare.py --check <scheme>` (needs the Ptyxis binary or `PTYXIS_BIN`) fails on an id that does not exist, a source that is not the declared id, an unlisted difference from the built-in or a bad nudge.

```
just generate <scheme>          # palette.toml, GTK3/GTK4/Shell, libadwaita, accent maps, GtkSourceView styles
just test <scheme>              # contrast, structure, parse, accent maps, probes
tools/test.sh <scheme>          # optional developer tool: whole suite in a container (tests the COMMITTED state); not used by agents, CI on the pull request is the test
```

If `accent-maps-gen` reports `VERIFY FAILED`, two role colours collide with an accent token: nudge the derived role (orange first), see the header of `tools/palette-from-scheme.py`. Contrast exceptions (a pair under 4.5:1 that the tests report or that the generators document, e.g. the GtkSourceView `adjusted:` comments) go into your report; do not hide them.

## 5. Finish

- `NOTICE`: the palette credit and licence of the new scheme (the suite requires the scheme name to appear there).
- `README.md`: the one-line list of schemes.
- Commit by explicit paths on `testing` (never `git add -A`), message says why. Never push or open pull requests unless asked; `main` is protected.
- The scheme needs nothing else: schemes are discovered by their `scheme.toml`, so it appears in `list-themes` and `install-themes` automatically and is installable on an image that ships the recipes with `ujust gnome-themes install-themes <scheme>`.
- Report: what you added, the test totals, contrast exceptions, which values are verified vs derived vs invented, anything for the hub under `Needs from hub:`.
