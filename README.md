# gnome-themes

Terminal-inspired colour schemes for GNOME: GTK 3, GTK 4 / libadwaita and the GNOME Shell, plus an
installer for the themes and for a few icon sets. Each theme is the stock stylesheet with only the colour
values replaced, so layout and behaviour stay stock. Terminal (Ptyxis) and editor (GtkSourceView) colours
are included.

## About this repo

This is a personal project for my own machine, so please excuse the slop. It was written with Claude
(Anthropic's coding assistant) and I have only tested it on my own setup. More serious maintainers are
welcome to take anything here that looks useful, no need to ask.

## Requirements

[`just`](https://github.com/casey/just), bash and git; GNOME with the User Themes extension (for the Shell theme).

## Install

```
git clone https://github.com/redcodeworks/gnome-themes && cd gnome-themes
just install-themes          # checklist; or: just install-themes gruvbox-material
just switch-theme            # apply it (GTK, Shell, libadwaita), asks for the accent; or: just switch-theme nordic cyan
just install-icons           # checklist; or: just install-icons Papirus-Dark
just switch-icons Papirus-Dark
```

Themes go to `~/.themes`, icons to `~/.local/share/icons`, as real copies. Checklists: SPACE ticks,
ENTER confirms, q cancels.

| Themes | Icons | |
|---|---|---|
| `list-themes` | `list-icons` | what is available (✓ = installed) |
| `install-themes [name]` | `install-icons [name]` | checklist without a name |
| `update-themes` | `update-icons` | refresh everything installed |
| `remove-themes [name]` | `remove-icons [name]` | checklist without a name |
| `switch-theme [name] [accent]` | `switch-icons [name]` | checklist without a name |

Update with `just update-themes` / `just update-icons` (themes pull your checkout first); remove with
`just remove-themes` / `just remove-icons`. A same-named folder that gnome-themes did not install is only
replaced or removed after you confirm.

## Themes

| Theme | Variants | Accents |
|---|---|---|
| `gruvbox-material` | dark, light | red green yellow blue magenta cyan orange |
| `nordic` | dark | red green yellow blue magenta cyan orange |
| `dracula` | dark, light | red green yellow blue magenta cyan orange |
| `catppuccin` | dark, light | red green yellow blue magenta cyan orange |
| `tokyo-night` | dark, light | red green yellow blue magenta cyan orange |
| `solarized` | dark, light | red green yellow blue magenta cyan orange |
| `everforest` | dark, light | red green yellow blue magenta cyan orange |
| `material` | dark, light | red green yellow blue magenta cyan orange |
| `rose-pine` | dark, light | red green yellow blue magenta cyan (no orange) |
| `fairy-floss` | dark | red green yellow blue magenta cyan |
| `monokai` | dark | red green yellow blue magenta cyan orange |
| `sweet` | dark | red green yellow blue magenta cyan orange |
| `aubergine` | dark | red green yellow blue magenta cyan orange (the Ubuntu terminal look) |

Icon sets: Papirus, Gruvbox Plus, Zafiro, candy, Tela and Fluent (sources in `tools/icon-sources.conf`).
`switch-theme` also selects the matching Ptyxis palette and the Text Editor colour scheme.

## Flatpak apps

Flatpak apps cannot read `~/.themes`, the icons or `~/.config/gtk-3.0|4.0` unless allowed. After
`switch-theme`, gnome-themes asks once (default no) whether to grant read-only access for the missing
entries; it records only what it added and offers to undo exactly that when the last theme and icon set is
removed. Nothing is widened silently.

## Contributing

`main` is protected: work on `testing`, open a pull request; CI on the pull request is the test. Design
notes and the contributor workflow are in `CLAUDE.md`.

## Licence and credits

Tooling and docs are MIT (`LICENSE`). The generated theme files derive from GTK's and GNOME Shell's stock
stylesheets and stay LGPL: each `*/themes/<Name>/` folder carries its own `LICENSE`. Palette credits and the
exact split are in `NOTICE`.
