# gnome-themes

Terminal-inspired colour schemes for GNOME, built on top of the stock GNOME Shell, GTK 4 / libadwaita
and GTK 3 templates. Each theme takes the stock stylesheet unchanged and replaces colour values only,
from a per-scheme `palette.toml`. Selectors, geometry and assets stay stock; the one exception is the Shell themes, which are stock plus colours plus a single marked override that draws the calendar flat (no circle per day, plain weekday headings, month label and arrows).

A theme is a top-level directory of this repo, each with its own `scheme.toml` (roles plus the six terminal
colours as accents, and orange as a seventh where the scheme has one): `gruvbox-material`, `nordic`, `dracula`, `catppuccin`, `tokyo-night`, `solarized`, `everforest`, `fairy-floss`, `material`, `monokai`, `rose-pine`, `sweet`, `aubergine`
(the Ubuntu terminal look). `fairy-floss` has no upstream licence and partly invented accents; `monokai` is classic Monokai, not Monokai Pro. Icon
sets come from the repos in `tools/icon-sources.conf`: Papirus, Gruvbox Plus, Zafiro, candy, Tela and Fluent.

## About this repo

This is a personal project for my own machine, so please excuse the slop. It was written with Claude
(Anthropic's coding assistant) and I have only tested it on my own setup. More serious maintainers are
welcome to take anything here that looks useful, no need to ask.

## Requirements

- To install: [`just`](https://github.com/casey/just), bash and git.
- To regenerate the CSS (`just generate`): python3, python3-gobject, GTK 3, GTK 4 and gnome-shell.

## Install

```
git clone https://github.com/redcodeworks/gnome-themes && cd gnome-themes
just install-themes          # checklist; or: just install-themes gruvbox-material
just switch-theme            # apply it (GTK, Shell, libadwaita), asks for the accent; or: just switch-theme nordic cyan
just install-icons           # checklist; or: just install-icons Papirus-Dark
just switch-icons Papirus-Dark
```

| Themes | Icons | |
|---|---|---|
| `list-themes` | `list-icons` | what is available (✓ = installed; themes show the accent, icons the source) |
| `install-themes [name]` | `install-icons [name]` | checklist without a name |
| `update-themes` | `update-icons` | refresh everything installed |
| `remove-themes [name]` | `remove-icons [name]` | checklist without a name |
| `switch-theme [name] [accent]` | `switch-icons [name]` | checklist without a name |

Themes go to `~/.themes` and icons to `~/.local/share/icons` as real copies (Flatpak apps see
`~/.themes`, not `/usr/share/themes`, and cannot follow symlinks; see Flatpak below). In the checklists SPACE ticks an entry, ENTER confirms and q cancels (up/down or j/k move; a all, n none). Override the
destinations with `THEMES_DEST` and `ICONS_DEST` (icons use the XDG path; GTK also reads the legacy `~/.icons`),
and the papirus source with `ICONS_URL`.

Workflow, themes: `update-themes` pulls your checkout (`git fetch`, `git pull --ff-only`; quiet on a detached HEAD), then replaces each installed set's folder.
Icons: clone the source into `~/.cache/gnome-themes/icons/<source>` (or refresh it to the latest upstream; offline it uses the cache), then replace each set's folder.
Only the sets' own folders are replaced, never the whole directory.
Every installed folder carries a `.gnome-themes` marker; a same-named folder without it (e.g. a third-party `Dracula`) is replaced or removed only after you answer `y` at the prompt (default no); without a terminal it is skipped with a message, and `FORCE=1` overrides. Folders installed before the marker are adopted when their `index.theme` is identical to ours. Tela and Fluent run their upstream `install.sh` (third-party code from the cloned repo) into a temp dir.

The accent is one of the scheme's six terminal colours plus orange where the scheme has one (`<scheme>/accents/list`; not `rose-pine` and `fairy-floss`, whose upstream has no orange), applied with sed token maps
(`accents/<accent>.{dark,light}.sed`) and remembered in `~/.local/state/gnome-themes/accents`. `switch-theme` sets the GTK theme, the Shell theme (User Themes extension; dark or light follows your
colour scheme) and offers the libadwaita file `~/.config/gtk-4.0/gtk.css`, never replacing a different
one without asking. GTK 3 follows `gtk-application-prefer-dark-theme` in `~/.config/gtk-3.0/settings.ini`,
not `color-scheme`.

Ptyxis: every scheme has a terminal palette, and `scheme.toml` says which kind (`ptyxis = "<Ptyxis built-in name>"` or `ptyxis = "generated"`, with the reason in `ptyxis_reason`). A scheme uses a Ptyxis **built-in** when one matches its colours closely (Ptyxis ships 244, e.g. "Everforest"): nothing is installed, and `switch-theme` just selects that name. Otherwise a palette is **generated** (`<scheme>/ptyxis/gnome-themes-<scheme>.palette`, light and dark sections that follow the system colour scheme, shown in Ptyxis as "<Title> (GNOME Themes)"). A built-in qualifies only if every colour the scheme defines is within a small distance of it (`tools/ptyxis-compare.py`, one threshold, rules in its header) and it follows light/dark like the scheme does: Ptyxis keeps one palette name per profile, so two flat built-ins (Catppuccin Latte and Mocha) cannot replace a light and dark pair. For a generated palette, `install-themes` / `update-themes` / `remove-themes` copy, refresh and delete it in `~/.local/share/org.gnome.Ptyxis/palettes` (`PTYXIS_PALETTES` overrides), with the same marker and collision rules as the folders (built-ins are never copied or removed). `switch-theme` selects the palette on the default Ptyxis profile and on every profile that already has a palette set (via `dconf`; with no Ptyxis profile yet it says so and skips) and prints which one it chose. The accent does not change it.

GtkSourceView: the editor area of Text Editor, Builder and other GtkSourceView apps is a style scheme, not part of the GTK theme, so every scheme also ships `<scheme>/gtksourceview/gnome-themes-<scheme>-dark.xml` (and `-light` where the scheme has a light variant). They are installed, refreshed and removed with the theme (same marker and collision rules) into `~/.local/share/gtksourceview-5/styles` and, since a Flatpak editor only reads its own data directory, into `~/.var/app/org.gnome.TextEditor|org.gnome.Builder/data/gtksourceview-5/styles` when those apps are installed (no sandbox permission needed). `switch-theme` sets Text Editor's `style-scheme` (the -dark id while the desktop is dark, else -light) and Builder's only when Builder exists. Syntax colours are kept at 4.5:1 on the editor background (comments 3:1) by changing only their lightness; the generated file lists what moved.

## Flatpak apps

Flatpak apps (on a fresh Fedora Atomic image the Calculator and Text Editor are Flatpaks) cannot read `~/.themes`, `~/.local/share/icons` or `~/.config/gtk-3.0|4.0` unless allowed. gnome-themes manages that access itself: after `switch-theme`, if `flatpak` is installed and the global user override lacks any of `xdg-config/gtk-3.0:ro`, `xdg-config/gtk-4.0:ro`, `xdg-data/icons:ro`, `~/.themes:ro`, it asks once (default no) whether to allow read-only access for all Flatpaks; without a terminal it only prints the exact `flatpak override --user --filesystem=...` command. Only the missing entries are granted and recorded in `~/.local/state/gnome-themes/flatpak-overrides`; an entry that was already there is never recorded or removed. When `remove-themes` or `remove-icons` removes the last installed theme and icon set it asks (default no; no terminal: prints the `--nofilesystem` commands) whether to remove exactly the recorded entries. The sandbox is never widened silently.

## Contributing

A new scheme starts with `just new-scheme <dir> "<Ptyxis palette name>"` (a draft `scheme.toml` from a built-in Ptyxis palette, see `tools/ptyxis-palette.sh list`), then `just generate <dir>`; `.claude/skills/build-scheme/SKILL.md` has the checklist.

`main` is protected. Push your work to `testing` (`git push origin HEAD:testing`); CI runs the tests there
(`tools/test.sh`, also runnable locally: it builds a Fedora 45 test image once and runs the suite in a throwaway podman or docker container, plus a secret scan). Open a pull request from `testing` into `main`;
it can be merged only when both CI jobs pass.

Licence: the tooling and docs are MIT (`LICENSE`). The generated theme files derive from GTK's and GNOME Shell's stock stylesheets and stay LGPL: each `*/themes/<Name>/` folder carries its own `LICENSE`. See `NOTICE` for the exact split and the credits.
