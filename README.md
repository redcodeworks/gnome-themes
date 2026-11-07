# gnome-themes

Terminal-inspired colour schemes for GNOME, built on top of the stock GNOME Shell, GTK 4 / libadwaita
and GTK 3 templates. Each theme takes the stock stylesheet unchanged and replaces colour values only,
from a per-scheme `palette.toml`. Selectors, geometry and assets stay stock.

A theme is a top-level directory of this repo (so far `gruvbox-material`, palette by
[sainnhe](https://github.com/sainnhe/gruvbox-material)); icon sets come from an icon repo
(Papirus by default), where each top-level directory is one set.

## About this repo

This is a personal project for my own machine, so please excuse the slop. It was written with Claude
(Anthropic's coding assistant) and I have only tested it on my own setup. More serious maintainers are
welcome to take anything here that looks useful, no need to ask.

## Requirements

- To install: [`just`](https://github.com/casey/just), bash and git (`gum` makes the checklists nicer).
- To regenerate the CSS (`just generate`): python3, python3-gobject, GTK 3, GTK 4 and gnome-shell.

## Install

```
git clone https://github.com/redcodeworks/gnome-themes && cd gnome-themes
just install-themes          # checklist; or: just install-themes gruvbox-material
just switch-theme            # apply it (GTK, Shell, libadwaita); or: just switch-theme gruvbox-material
just install-icons           # checklist; or: just install-icons Papirus-Dark
just switch-icons Papirus-Dark
```

| Themes | Icons | |
|---|---|---|
| `list-themes` | `list-icons` | what is available (✓ = installed) |
| `install-themes [name]` | `install-icons [name]` | checklist without a name |
| `update-themes` | `update-icons` | refresh everything installed from the repo |
| `remove-themes [name]` | `remove-icons [name]` | checklist without a name |
| `switch-theme [name]` | `switch-icons [name]` | checklist without a name |

Themes go to `~/.themes` and icons to `~/.local/share/icons` as real copies (Flatpak apps see
`~/.themes`, not `/usr/share/themes`, and cannot follow symlinks; give them
`--filesystem=~/.themes:ro`). In the checklists `x` ticks an entry and enter confirms. Override the
destinations with `THEMES_DEST` and `ICONS_DEST`, and the icon repo with `ICONS_URL`.

`switch-theme` sets the GTK theme, the Shell theme (User Themes extension; dark or light follows your
colour scheme) and offers the libadwaita file `~/.config/gtk-4.0/gtk.css`, never replacing a different
one without asking. GTK 3 follows `gtk-application-prefer-dark-theme` in `~/.config/gtk-3.0/settings.ini`,
not `color-scheme`.

Licence: the tooling and docs are MIT (`LICENSE`). The generated theme files derive from GTK's and GNOME Shell's stock stylesheets and stay LGPL: each `*/themes/<Name>/` folder carries its own `LICENSE`. See `NOTICE` for the exact split and the credits.
