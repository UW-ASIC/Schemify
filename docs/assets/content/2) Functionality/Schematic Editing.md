# Schematic Editing

How to build schematics in Schemify — placing components, drawing wires, and editing properties.

---

## Placing Components

### From the Library Browser

Press **Insert** or go to **Place > Insert from Library** to open the library browser. Browse available symbols and click to place.

### Quick Primitives

Use **Place** menu or keybinds to insert common devices:

| Device | Menu Path |
| --- | --- |
| NMOS / PMOS | Place > NMOS / PMOS |
| Resistor | Place > Resistor |
| Capacitor | Place > Capacitor |
| Inductor | Place > Inductor |
| Diode | Place > Diode |
| NPN / PNP | Place > NPN / PNP |
| VSource / ISource | Place > VSource / ISource |
| GND / VDD | Place > GND / VDD |

### Pins

- **Ctrl+P** — Insert input pin (ipin)
- **Ctrl+Shift+P** — Insert output pin (opin)
- **Alt+L** — Insert label pin

Pins define the interface when a schematic is used as a subcircuit.

---

## Drawing Wires

1. Press **W** or click **Place > Wire**
2. Click to start the wire
3. Click again to place segments
4. Press **Escape** to end

### Routing Modes

Press **Shift+L** to cycle through routing modes:

- **Auto** — picks H-first or V-first based on direction
- **H first** — horizontal segment then vertical
- **V first** — vertical segment then horizontal
- **Diagonal** — direct point-to-point

You can also change routing in **Help > Preferences > Wire Routing**.

### Wire Operations

| Action | Key |
| --- | --- |
| Break wires at junctions | ! |
| Join collinear wires | & |
| Toggle wire stretching | Y |

Wire stretching (rubber-band mode) automatically adjusts connected wires when you move a component.

---

## Drawing Shapes

Shapes are used for symbol graphics and schematic annotations.

| Tool | Key | Description |
| --- | --- | --- |
| Line | L | Straight line segment |
| Rectangle | R (menu) | Box shape |
| Polygon | P | Multi-point closed shape |
| Arc | Shift+C | Curved arc |
| Circle | Ctrl+Shift+C | Full circle |
| Text | T | Text label |

Access all tools from the **Place** menu.

---

## Moving and Transforming

### Move Mode

Press **M** to enter move mode, then drag selected objects. Wire stretching is automatic when **Y** (toggle) is enabled — connected wires follow the moved component.

### Nudge

Use arrow keys to nudge selected items by 10 units in any direction.

### Rotate and Flip

| Action | Key |
| --- | --- |
| Rotate clockwise | R |
| Rotate counter-clockwise | Shift+R |
| Flip horizontal | X or Shift+F |
| Flip vertical | Shift+X |

Multi-selection: rotates/flips around the group center.
Single selection: rotates/flips in place.

### Align to Grid

**Edit > Align to Grid** snaps selected objects to the current grid.

---

## Selection

| Action | Key |
| --- | --- |
| Click | Select single object |
| Drag | Area select |
| Ctrl+A | Select all |
| Ctrl+Shift+A | Select none |
| Escape | Clear selection |
| Ctrl+F | Find by name |
| D | Duplicate selected |

### Copy / Paste

- **Ctrl+C** — Copy selected to clipboard
- **Ctrl+X** — Cut
- **Ctrl+V** — Paste (offset by 20 units)
- **Delete** — Delete selected

---

## Editing Properties

### Instance Properties

Select an instance and press **Q** to open the Properties dialog.

You can edit:
- **Name** — the instance reference designator
- **Properties** — key-value pairs (model, W, L, etc.)

The dialog also shows read-only symbol info: format string, pin count, and symbol-level properties.

### Batch Properties

When multiple instances are selected, **Q** opens the batch properties viewer showing all selected instances and their properties.

### Property Commands

| Command | Description |
| --- | --- |
| `:set-prop <key> <value>` | Set a property on selected instance |
| `:rename <name>` | Rename selected instance |
| Q | Open properties dialog |
| Shift+Q | Edit in external editor |
| Ctrl+Shift+Q | View properties (read-only) |
| Alt+Q | Open raw schematic file in editor |

### SPICE Ignore

Press **Shift+T** on a selected instance to toggle the `spice_ignore` flag. When set, the instance is excluded from netlist generation.

---

## Undo / Redo

All schematic mutations (place, delete, move, rotate, flip, property changes) are undoable.

- **Ctrl+Z** or **U** — Undo
- **Ctrl+Y** or **Shift+U** — Redo
