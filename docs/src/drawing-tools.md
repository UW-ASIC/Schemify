# Drawing Tools

Schemify provides a set of drawing tools for schematic capture and symbol editing. Each tool has a single-key shortcut for fast switching.

## Tool Shortcuts

| Key | Tool | Description |
|---|---|---|
| **Esc** | Select | Click to select components and wires. Drag to box-select. |
| **W** | Wire | Draw electrical connections between pins. |
| **M** | Move | Drag selected components to reposition them. |
| **L** | Line | Draw non-electrical lines (for annotations or symbol shapes). |
| **A** | Arc | Draw arcs (for symbol artwork). |
| **C** | Circle | Draw circles. |
| **P** | Polygon | Draw filled or outlined polygons. |
| **T** | Text | Place text labels on the canvas. |

## Select Tool (Esc)

The default tool. Use it to:

- **Click** a component or wire to select it
- **Drag** an empty area to box-select multiple items
- **Ctrl+A** to select everything
- **Ctrl+Shift+A** to deselect everything
- **Delete** or **Backspace** to delete selected items

## Wire Tool (W)

Draws electrical wires between component pins.

- Click a pin to start a wire
- Click to place a corner point
- Click on another pin to finish the connection
- Wires snap to the grid automatically
- Bus wires (thick lines) carry multi-bit signals

## Transform Operations

After selecting one or more components:

| Key | Action |
|---|---|
| **R** | Rotate 90° clockwise |
| **Shift+R** | Rotate 90° counter-clockwise |
| **X** | Flip horizontally |
| **Shift+X** | Flip vertically |
| **D** | Duplicate selected items |
| **Arrow keys** | Nudge by one grid unit |

## Snap to Grid

All placements snap to the grid by default. Use **align-to-grid** (available via command mode) to snap existing components that are off-grid.
