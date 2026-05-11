# View Controls

Zoom, pan, grid, layers, and display options.

---

## Zoom

| Action | Key | Menu |
| --- | --- | --- |
| Zoom to fit all | F or Z | View > Zoom to Fit |
| Zoom to selected | Ctrl+Shift+F | (keybind only) |
| Zoom in | Ctrl+= | View > Zoom In |
| Zoom out | Ctrl+- | View > Zoom Out |
| Zoom reset (1:1) | Ctrl+0 | View > Zoom Reset |
| Zoom box | Shift+Z | (keybind only) |
| Mouse wheel | Scroll | Zoom in/out at cursor |

### Zoom Box

Press **Shift+Z** to enter zoom box mode. Drag a rectangle to zoom into that area.

---

## Pan

- **Middle mouse drag** — pan the view
- **Shift+P** — enter pan mode (left-click drag to pan)
- **Arrow keys** — nudge the view

---

## Grid

| Action | Key | Menu |
| --- | --- | --- |
| Toggle grid visibility | % (Shift+5) | View > Show/Hide Grid |
| Halve snap size | G | (keybind only) |
| Double snap size | Shift+G | (keybind only) |

Default grid: 20 units. Default snap: 10 units.

Snap size is shown in the status bar at the bottom. You can also change it in **Help > Preferences > Grid & Snapping**.

---

## Layers

Schemify supports multiple drawing layers. Each layer has its own color.

| Action | Key |
| --- | --- |
| Set current layer | Ctrl+1 through Ctrl+9 |
| Show all layers | Shift+< (comma) |
| Show only current layer | Shift+> (period) |

---

## Display Options

| Option | Key | Menu |
| --- | --- | --- |
| Toggle fullscreen | \ | View > Fullscreen |
| Toggle dark/light mode | Shift+O | View > Toggle Color Scheme |
| Toggle crosshair | Alt+X | View > Show Crosshair |
| View only probes | 5 | (keybind only) |
| Toggle text in symbols | Ctrl+B | (keybind only) |
| Toggle symbol details | Alt+B | (keybind only) |
| Toggle fill rectangles | (Preferences) | Help > Preferences |

### Line Width

| Action | Key |
| --- | --- |
| Decrease line width | Alt+- |
| Increase line width | Alt+= |

Line width range: 1–10. Also adjustable in **Help > Preferences**.

---

## Preferences Dialog

Open from **Help > Preferences**. Settings:

- **Appearance** — dark mode, fill rectangles, text in symbols, symbol details, line width
- **Grid & Snapping** — show grid, snap size
- **Wire Routing** — auto, H-first, V-first, diagonal

---

## Status Bar

The bottom status bar shows:
- Current status message
- Snap size
- Active tool
- View mode (schematic/symbol)
- Hierarchy breadcrumb (when descended)
- Command hint

In command mode (`:`) the bar shows your typed command with Enter/Esc hints.
