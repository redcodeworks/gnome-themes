---
name: build-scheme
description: Add a new colour scheme (a new top-level theme directory) to gnome-themes. Starts from a Ptyxis built-in palette, falls back to researching the scheme's official palette, then hands off to the deterministic generators. Use when asked to add, port or build a scheme or theme from a colour palette.
---

# Add a scheme to gnome-themes

A scheme is a top-level directory with one `scheme.toml`; everything else (GTK 3/4, Shell, libadwaita file, accent maps, Ptyxis palette, GtkSourceView styles) is generated. Your job is only the decisions about colours; the scripts do the rest. Read `CLAUDE.md` first (colour values only, generated files are never hand-edited, structure check stays at 0 differing lines).

## 1. Decide what you are building

- The scheme's directory name (lowercase, hyphens: `tokyo-night`), its display title and whether it has a dark variant, a light variant or both (a dark-only scheme fills the GTK light slot from the dark values; do not invent a light variant).
- Check `just list-themes` and the existing `*/scheme.toml` for an existing scheme with that name.

## 2. Find the palette (in this order)

a. **Ptyxis built-in palettes.** `tools/ptyxis-palette.sh list` shows the names and their sections (`Light,Dark` or `flat`); `tools/ptyxis-palette.sh show "<name>"` prints one. Match by name, including light and dark variants (some schemes have one palette with `[Light]`/`[Dark]` sections, others two flat palettes such as "Catppuccin Latte" and "Catppuccin Mocha"). Many built-ins are Gogh ports: treat them as a starting point, not as the scheme's official values.

b. **Research** when no built-in matches (or to verify one): find the scheme's official specification or repository and take hex values from the raw files, not from screenshots or summaries. Record the licence and the attribution text that licence requires, and which values were verified against the source and which were not. A session without web tools must not guess: return `Needs from hub: palette research for <scheme>` (the official repo URL if known, the variants wanted) and stop.

c. **Never invent colours silently.** If the scheme has no orange, no surface steps, no light variant and so on, derived or invented values are allowed only when marked as such in `scheme.toml` comments and in `NOTICE` (see `fairy-floss/scheme.toml` for the pattern: a header that separates "from the source", "derived by the fixed rules" and "invented").

## 3. Draft with the script

```
just new-scheme <scheme-dir> "<ptyxis palette name or file>" ["<light palette>"]
# = python3 -I tools/scheme-from-ptyxis.py <scheme-dir> <palette> [<light-palette>]
```

It writes a DRAFT `<scheme-dir>/scheme.toml` (it refuses to overwrite an existing scheme): Color1-6 become the six accents per variant, Foreground/Background become `fg`/`bg_deep`, a black, white, brights or cursor that differ from the generator defaults go to `[<variant>.terminal]` with the palette as source, title/gtk_name/shell_name come from the directory name. It prints a `# TODO` list; resolve each item in the file and delete the TODO lines:

- credit line, licence and provenance notes (verified vs invented),
- the orange role (derived by default; a scheme's own orange also needs a seventh `orange` entry in `[<variant>.ansi]`, otherwise there is none),
- the surface ladder (`bg`, `surface`, `surface_high`) and `fg_dim`/`comment`/`selection` when the scheme defines them,
- `accent_fg` overrides where an accent fails 4.5:1 with the default ink,
- `default_accent` with a one-line reason (the draft proposes the best-contrast accent; the scheme's signature colour is usually the better choice),
- dark-only or not,
- `ptyxis`: the draft says `ptyxis = "generated"` with a TODO reason; step 4 decides it.

Also replace the Ptyxis-derived values with the official ones wherever the research (step 2b) found different hex values; the Ptyxis copy is often slightly off.

## 4. Terminal palette: built-in or generated, then build with the existing pipeline

Do not generate a Ptyxis palette that duplicates a built-in. Once the scheme's colours are final, run `python3 -I tools/ptyxis-compare.py <scheme>` (needs the Ptyxis binary or `PTYXIS_BIN`; the table lists the same-named built-ins with a colour distance per variant). A built-in qualifies by the rules in that script's header (close = within its single THRESHOLD for every variant; it must have `[Light]`/`[Dark]` sections when the scheme has two variants, because one Ptyxis profile holds one palette name and two flat built-ins cannot follow the system light/dark setting; a flat one for a dark-only scheme). Then set in `scheme.toml`, next to `credit`:

```
ptyxis = "<built-in name>"      # or "generated"
ptyxis_reason = "<one line: the numbers that decided it>"
```

`python3 -I tools/ptyxis-compare.py --check <scheme>` fails when the declaration contradicts the data. A generated scheme's palette is written by `just generate`; for a built-in nothing is written.

```
just generate <scheme>          # palette.toml, GTK3/GTK4/Shell, libadwaita, accent maps, Ptyxis palette (generated schemes only), GtkSourceView styles
just test <scheme>              # contrast, structure, parse, accent maps, probes
tools/test.sh <scheme>          # whole suite for the scheme, in its container (it tests the COMMITTED state: commit first)
```

If `accent-maps-gen` reports `VERIFY FAILED`, two role colours collide with an accent token: nudge the derived role (orange first), see the header of `tools/palette-from-scheme.py`. Contrast exceptions (a pair under 4.5:1 that the tests report or that the generators document, e.g. the GtkSourceView `adjusted:` comments) go into your report; do not hide them.

## 5. Finish

- `NOTICE`: the palette credit and licence of the new scheme (the suite requires the scheme name to appear there).
- `README.md`: the one-line list of schemes.
- Commit by explicit paths on `testing` (never `git add -A`), message says why. Never push or open pull requests unless asked; `main` is protected.
- The scheme needs nothing else: schemes are discovered by their `scheme.toml`, so it appears in `list-themes` and `install-themes` automatically and is installable on an image that ships the recipes with `ujust gnome-themes install-themes <scheme>`.
- Report: what you added, the test totals, contrast exceptions, which values are verified vs derived vs invented, anything for the hub under `Needs from hub:`.
