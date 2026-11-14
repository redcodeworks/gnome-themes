# gnome-themes

Terminal-inspired color schemes for GNOME: GTK 3, GTK 4 / libadwaita and the GNOME Shell, plus an
installer for the themes and for a few icon sets. Only the colors change, so layout and behavior stay
stock. Matching terminal (Ptyxis) and editor (GtkSourceView) colors are included.

## Requirements

[`just`](https://github.com/casey/just), bash and git; GNOME with the User Themes extension (for the Shell theme).

## Install and usage

```
git clone https://github.com/redcodeworks/gnome-themes && cd gnome-themes
just install-theme          # checklist; or: just install-theme gruvbox-material
just switch-theme            # apply it (GTK, Shell, libadwaita), asks for the accent; or: just switch-theme nordic cyan
just install-icon           # checklist; or: just install-icon Papirus-Dark
just switch-icon Papirus-Dark
```

Themes go to `~/.themes`, icons to `~/.local/share/icons`, as real copies. Checklists use `gum` when it is installed, otherwise a built-in picker: SPACE ticks,
`/` filters, ENTER confirms, q cancels.

| Themes | Icons | |
|---|---|---|
| `list-themes` | `list-icons` | what is available (✓ = installed) |
| `install-theme [name]` | `install-icon [name]` | checklist without a name |
| `update-theme` | `update-icon` | refresh everything installed |
| `remove-theme [name]` | `remove-icon [name]` | checklist without a name |
| `switch-theme [name] [accent]` | `switch-icon [name]` | checklist without a name |

Update with `just update-theme` / `just update-icon` (themes pull your checkout first); remove with
`just remove-theme` / `just remove-icon`. A same-named folder that gnome-themes did not install is only
replaced or removed after you confirm.

## Themes

Every theme ships a dark variant and, where the palette has one, a light variant, each with seven or six
accent colors (red, green, yellow, blue, magenta, cyan, plus orange where the palette has one). `just list-themes`
shows what is available (a checkmark marks the installed ones); the install checklist shows the same list, all
unticked. Featured themes are listed first (marked with a star), then the rest alphabetically. The
palettes come from the built-in Ptyxis terminal palettes, so the terminal, the apps and the Shell match.

Icon sets: Papirus, Gruvbox Plus, Zafiro, candy, Tela and Fluent (sources in `tools/icon-sources.conf`).
`switch-theme` also selects the matching Ptyxis built-in palette (the light or dark one, by the system setting, for schemes that have two) and the Text Editor color scheme.

## Flatpak apps

Flatpak apps cannot read `~/.themes`, the icons or `~/.config/gtk-3.0|4.0` unless allowed. After
`switch-theme` you are asked once (default no) whether to grant read-only access for what is missing, and
the grant is undone when you remove the last theme and icon set. Nothing is widened silently.

## Contributing

`main` is protected. Changes go on a feature branch, into `testing` by pull request, and from `testing` into
`main` by pull request; CI is the test.
The contributor workflow and design notes are in `CLAUDE.md`.

## License and credits

Tooling and docs are MIT (`LICENSE`). The generated theme files derive from GTK's and GNOME Shell's stock
stylesheets and stay LGPL: each `*/themes/<Name>/` folder carries its own `LICENSE`. Palette credits and
the exact split are in `NOTICE`.

## Disclaimer

This is a personal project, assisted by Claude (Anthropic's coding assistant), so please excuse the slop.
I have only tested it on my own setup and will not actively maintain it beyond my own needs. If you find
something valuable here, you are encouraged to fork it.
