# gnome-themes

Terminal-inspired colour schemes for GNOME, built on top of the stock GNOME Shell, GTK 4 / libadwaita
and GTK 3 templates. Each theme takes the stock stylesheet unchanged and replaces colour values only,
from a per-scheme `palette.toml`. Selectors, geometry and assets stay stock.

Schemes: `gruvbox-material` (palette by [sainnhe](https://github.com/sainnhe/gruvbox-material)).
Layout: `<scheme>/palette.toml`, `<scheme>/themes/<Name>/` (installed as-is), `<scheme>/libadwaita/gtk.css`.

## Requirements

- To install: [`just`](https://github.com/casey/just) and bash.
- To regenerate the CSS (`just generate`): python3, python3-gobject, GTK 3, GTK 4 and gnome-shell.

## Install

```
just pick                                  # checklist; copies the chosen themes into ~/.themes
just pick Gruvbox-Material                 # no prompt
just install gruvbox-material              # a whole scheme into /usr/share/themes (root)
just install-user                          # libadwaita apps: installs ~/.config/gtk-4.0/gtk.css
```

Then select the GTK theme in Tweaks (or `gsettings set org.gnome.desktop.interface gtk-theme Gruvbox-Material`)
and the Shell theme with the User Themes extension. GTK 3 follows `gtk-application-prefer-dark-theme` in
`~/.config/gtk-3.0/settings.ini`, not `color-scheme`. Flatpak apps only see `~/.themes`
(`flatpak override --user --filesystem=~/.themes:ro`).

Licence: LGPL-2.1, see `LICENSE` and `NOTICE` for the stock-stylesheet and palette credits.
