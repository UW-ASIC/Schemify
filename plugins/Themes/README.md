<p align="center">
  <img src="logo.svg" width="96" alt="Themes logo"/>
</p>

<h1 align="center">Themes</h1>

<p align="center">
  <b>Live theme switcher for Schemify</b><br/>
  23 built-in color themes &middot; custom user themes &middot; UI shape controls &middot; persistent across sessions
</p>

---

## Features

- **23 built-in themes** covering dark, light, retro, and high-contrast styles
- **One-click switching** via a sidebar dropdown — changes apply instantly
- **UI shape controls** — corner radius (Sharp / Balanced / Rounded / Pill), wire width, and tab style
- **User themes** — drop a `.json` file in `~/.config/Schemify/themes/` and it appears automatically
- **Edit in place** — click "Edit Theme JSON" to open any theme in your system editor; bundled themes are copied to your user directory first so originals stay intact
- **Persistent** — your selected theme and settings survive restarts

## Install

```bash
make install
```

Builds a native `.so` and installs to `~/.config/Schemify/plugins/Themes/`.

## Built-in Themes

| Dark | Light | Specialty |
|------|-------|-----------|
| Schemify Dark | Catppuccin Latte | Cyberpunk |
| Dracula | GitHub Light | Matrix |
| Catppuccin Mocha | High Contrast Light | Green Phosphor |
| Tokyo Night | Paperwhite | Amber CRT |
| Nord | | Brutalist |
| Gruvbox Dark | | Glassmorphism |
| One Dark | | KiCad Dark |
| Monokai | | Pastel Dream |
| Rose Pine | | |
| Solarized Dark | | |
| Everforest | | |

## Creating a Custom Theme

1. Create `~/.config/Schemify/themes/my_theme.json`
2. Define your colors:

```json
{
  "name": "My Theme",
  "canvas_bg": [20, 20, 30],
  "grid_dot": [60, 60, 80, 100],
  "wire": [100, 200, 255],
  "wire_selected": [255, 180, 100],
  "wire_endpoint": [80, 220, 150],
  "instance_body": [50, 55, 70],
  "instance_pin": [240, 210, 90],
  "symbol_line": [230, 230, 240],
  "wire_preview": [100, 230, 140, 170],
  "sidebar_bg": [25, 27, 35],
  "bottombar_bg": [25, 27, 35]
}
```

3. Restart Schemify — your theme appears in the dropdown

Or just click **Edit Theme JSON** on any existing theme to use it as a starting point.

### Color Format

| Key | Format | Description |
|-----|--------|-------------|
| `canvas_bg` | `[R, G, B]` | Schematic canvas background |
| `grid_dot` | `[R, G, B, A]` | Grid dot color with alpha |
| `wire` | `[R, G, B]` | Default wire color |
| `wire_selected` | `[R, G, B]` | Selected wire / instance highlight |
| `wire_endpoint` | `[R, G, B]` | Wire connection dots |
| `wire_preview` | `[R, G, B, A]` | Wire being drawn (with alpha) |
| `instance_body` | `[R, G, B]` | Component body fill |
| `instance_pin` | `[R, G, B]` | Component pin dots |
| `symbol_line` | `[R, G, B]` | Symbol outline strokes |
| `sidebar_bg` | `[R, G, B]` | Side panel background |
| `bottombar_bg` | `[R, G, B]` | Bottom bar background |

### Optional Overrides

| Key | Type | Description |
|-----|------|-------------|
| `corner_radius` | float | UI corner roundness (0 = sharp, 16 = pill) |
| `wire_width` | float | Wire thickness multiplier (default 1.0) |
| `tab_shape` | int | Tab style: 0 = Rect, 1 = Rounded, 2 = Bordered, 3 = Underline |

## Requirements

- Python 3.10+
- No external dependencies
