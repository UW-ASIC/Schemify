# Keyboard Shortcuts

All keyboard shortcuts available in Schemify. Shortcuts can be customized via `~/.config/Schemify/keybinds.toml`.

---

## File Operations

| Key | Action |
| --- | --- |
| Ctrl+N | New schematic |
| Ctrl+O | Open file |
| Ctrl+S | Save |
| Ctrl+T | New tab |
| Ctrl+W | Close tab |
| Ctrl+Left | Previous tab |
| Ctrl+Right | Next tab |
| Ctrl+Shift+T | Reopen closed tab |
| Alt+O | Open file in new tab |
| Alt+S | Reload from disk |
| B | Merge external file into schematic |

## Navigation / Hierarchy

| Key | Action |
| --- | --- |
| E | Descend into schematic |
| Ctrl+E | Ascend to parent schematic |
| Backspace | Ascend to parent schematic |
| I | Descend into symbol view |
| Alt+I | Edit selected symbol in new tab |
| Alt+E | Edit selected schematic in new tab |

## Selection

| Key | Action |
| --- | --- |
| Ctrl+A | Select all |
| Ctrl+Shift+A | Select none |
| Ctrl+F | Find / select by name |
| Escape | Clear selection, cancel mode |

## Clipboard

| Key | Action |
| --- | --- |
| Ctrl+C | Copy |
| Ctrl+X | Cut |
| Ctrl+V | Paste |

## Undo / Redo

| Key | Action |
| --- | --- |
| Ctrl+Z | Undo |
| Ctrl+Y | Redo |
| U | Undo |
| Shift+U | Redo |

## Component Placement

| Key | Action |
| --- | --- |
| Insert | Open library browser |
| Ctrl+P | Insert input pin (ipin) |
| Ctrl+Shift+P | Insert output pin (opin) |
| Alt+L | Insert label pin |

## Drawing Tools

| Key | Action |
| --- | --- |
| W | Start wire |
| L | Line tool |
| R | Rotate CW (when placing/selected) |
| T | Text tool |
| P | Polygon tool |
| Shift+C | Arc tool |
| Ctrl+Shift+C | Circle tool |

## Movement and Transformation

| Key | Action |
| --- | --- |
| M | Move mode |
| D | Duplicate selected |
| R | Rotate clockwise |
| Shift+R | Rotate counter-clockwise |
| X | Flip horizontal |
| Shift+X | Flip vertical |
| Shift+F | Flip horizontal |
| Delete | Delete selected |

## View / Zoom

| Key | Action |
| --- | --- |
| F | Zoom to fit all |
| Z | Zoom to fit all |
| Shift+Z | Zoom box (drag to area) |
| Ctrl+= | Zoom in |
| Ctrl+- | Zoom out |
| Ctrl+0 | Zoom reset |
| Ctrl+Shift+F | Zoom to selected |
| \ | Toggle fullscreen |
| Shift+O | Toggle light/dark color scheme |
| Shift+/ | Show keybinds dialog |
| 5 | View only probes |

## Grid and Snap

| Key | Action |
| --- | --- |
| G | Halve snap size |
| Shift+G | Double snap size |
| Shift+% (5) | Toggle grid visibility |

## Net Highlighting

| Key | Action |
| --- | --- |
| K | Highlight selected nets |
| Shift+K | Unhighlight all |
| Ctrl+K | Unhighlight all |

## Wire Operations

| Key | Action |
| --- | --- |
| ! (Shift+1) | Break wires at junctions |
| & (Shift+7) | Join collinear wires |
| Y | Toggle wire stretching |
| Shift+L | Toggle orthogonal routing mode |

## Netlisting

| Key | Action |
| --- | --- |
| N | Generate hierarchical netlist |
| Shift+N | Generate top-level only netlist |
| Shift+A | Toggle netlist view |

## Symbol / Schematic

| Key | Action |
| --- | --- |
| A | Make symbol from schematic pins |
| Ctrl+L | Make schematic from symbol |
| S | Switch to schematic view |
| Shift+V | Switch to symbol view |
| Ctrl+B | Toggle text in symbols |
| Alt+B | Toggle symbol details |

## Display / Layers

| Key | Action |
| --- | --- |
| Ctrl+1..9 | Set current layer |
| Shift+< | Show all layers |
| Shift+> | Show only current layer |
| Alt+- | Decrease line width |
| Alt+= | Increase line width |

## Properties

| Key | Action |
| --- | --- |
| Q | Edit instance properties |
| Shift+Q | Edit properties in external editor |
| Ctrl+Shift+Q | View properties (read-only) |
| Alt+Q | Edit schematic file raw |
| Shift+T | Toggle SPICE ignore on selection |

## Design Checks

| Key | Action |
| --- | --- |
| # (Shift+3) | Highlight duplicate instance names |
| Ctrl+# | Auto-rename duplicate names |

## Simulation

| Key | Action |
| --- | --- |
| F5 | Run simulation (ngspice) |
| Alt+X | Toggle crosshair |
| Shift+P | Pan mode |

---

## Customizing Keybinds

Create `~/.config/Schemify/keybinds.toml`:

```toml
[keybinds]
"ctrl+s" = "file_save"
"alt+n" = "netlist_hierarchical"
"shift+d" = "delete_selected"
"f7" = "toggle_colorscheme"
```

Key names: `a`–`z`, `0`–`9`, `f1`–`f12`, `space`, `enter`, `escape`, `tab`, `backspace`, `delete`, `insert`, `up`, `down`, `left`, `right`, `minus`, `equal`, `comma`, `period`, `slash`, `backslash`, `semicolon`, `grave`, `apostrophe`, `left_bracket`, `right_bracket`.

Modifiers: `ctrl`, `shift`, `alt` (combine with `+`).

Command names match internal command tags: `zoom_in`, `zoom_out`, `file_save`, `delete_selected`, `rotate_cw`, `flip_horizontal`, `netlist_hierarchical`, `toggle_crosshair`, etc.
