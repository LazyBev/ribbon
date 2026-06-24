# ribbon

A Wayland status bar with a Lisp-like `.rib` config DSL.

Written in Odin, renders with cairo + librsvg, uses `wlr-layer-shell` for Wayland shell surface protocol.

## Requirements

- **Wayland compositor** with `wlr-layer-shell` support (Niri, Hyprland, Sway, river, etc.)
- **Dependencies**: wayland, cairo, librsvg, pango, glib, fontconfig, freetype
- **Optional**: wireplumber/pulseaudio (volume widget), nmcli (wifi widget)

## Build

### Nix

```sh
nix build          # produces result/bin/ribbon
nix develop        # dev shell with all dependencies
```

### Non-Nix (Linux)

```sh
bash build_ribbon.sh   # requires odin compiler + deps via pkg-config
just user-install       # builds and installs to ~/.local/bin/
just install            # builds and installs to /usr/local/bin/
```

## Usage

Create `~/.config/ribbon/config.rib`:

```scheme
; config.rib — status bar configuration
(bar.create)
(bar.set-interval 0.2)
(bar.set-font "DejaVu Sans" size 14)
(bar.set-background height 30 colour "#1e1e2e" font-color "#c0caf5")
; optional auto-separator: (bar.separator " | " colour "#585b70")
(bar.wifi-icon #t)
(bar.set-logo-size 24)
(bar.set-widget-gap 0)
(bar.set-left distro-logo)
(bar.set-center clock txt " | " (!"date '+%A %d %Z'"))
(bar.set-right (battery fmt "Bat: {}") txt " " battery-state txt " | " (cpu fmt "CPU: {}") txt " | " (memory fmt "Mem: {}") txt " | " (volume fmt "VOL: {}") txt " | " (wifi fmt "SSID: {}"))
; no systray currently — on the roadmap
(bar.pad left 8)
(bar.start)
```

Then run `ribbon`. Kill with `ribbon kill`.

## Widgets

| Widget | Description |
|---|---|
| `clock` | Current time (HH:MM) |
| `cpu` | CPU usage (`75%`) |
| `memory` | RAM usage (`3.2/15.6G`) |
| `battery` | Battery percentage |
| `battery-state` | Charging arrow (↑↓—) |
| `wifi` | Network name + signal |
| `distro` | OS name from `/etc/os-release` |
| `distro-logo` | Distro SVG icon |
| `volume` | Volume percentage (`wpctl`) |
| `!command` | Run shell command, show output |

See `CONFIGS_DOC.txt` for the full configuration reference.

## License

MIT
