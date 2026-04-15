# Keyboard Shortcuts & Editor Usage

Schemify is keyboard-driven. Most operations have single-key bindings. The editor supports a vim-like command mode for panel navigation.

## Basic Navigation

| Key             | Action                              |
| --------------- | ----------------------------------- |
| `W` `A` `S` `D` | Pan the canvas                      |
| `+` / `-`       | Zoom in / out                       |
| `Ctrl+0`        | Fit view to schematic               |
| `Esc`           | Cancel current action               |
| `Tab`           | Cycle focus between open schematics |

## Placing Elements

| Key | Action                                 |
| --- | -------------------------------------- |
| `W` | Place wire                             |
| `I` | Insert instance (opens symbol browser) |
| `L` | Place net label                        |
| `P` | Place port (ipin/opin/iopin)           |
| `B` | Place bus                              |
| `T` | Place text annotation                  |

## Selection & Editing

| Key                    | Action                              |
| ---------------------- | ----------------------------------- |
| Click                  | Select element                      |
| `Shift+Click`          | Add to selection                    |
| Click+Drag             | Rubber-band selection               |
| `A`                    | Select all                          |
| `Esc`                  | Clear selection                     |
| `M`                    | Move selection                      |
| `C`                    | Copy selection                      |
| `Delete` / `Backspace` | Delete selection                    |
| `R`                    | Rotate selected instance            |
| `F`                    | Flip (mirror) selected instance     |
| `E`                    | Edit properties of selected element |
| `Q`                    | Edit instance parameters            |

## Undo / Redo

| Key                        | Action |
| -------------------------- | ------ |
| `Ctrl+Z`                   | Undo   |
| `Ctrl+Y` or `Ctrl+Shift+Z` | Redo   |

## File Operations

| Key      | Action                 |
| -------- | ---------------------- |
| `Ctrl+S` | Save current schematic |
| `Ctrl+O` | Open schematic         |
| `Ctrl+N` | New schematic          |

## Simulation

| Key      | Action                            |
| -------- | --------------------------------- |
| `Ctrl+R` | Generate netlist + run simulation |
| `Ctrl+G` | Generate netlist only             |

## Hierarchy

| Key       | Action                           |
| --------- | -------------------------------- |
| `H`       | Descend into selected subcircuit |
| `Shift+H` | Ascend to parent                 |
| `Ctrl+H`  | Show hierarchy tree              |

## View

| Key      | Action                  |
| -------- | ----------------------- |
| `G`      | Toggle grid             |
| `N`      | Toggle net labels       |
| `Ctrl+D` | Toggle dark/light theme |

## Panel Navigation (vim-mode)

Open any plugin panel (if you have it installed) with its registered vim command:

```
:wv        # open Waveform Viewer
:sim       # open Simulation panel
:pdk       # open PDK/Volare panel
:opt       # open Optimizer
```

## Mouse

| Action              | Effect       |
| ------------------- | ------------ |
| Left click          | Select       |
| Left drag on canvas | Pan          |
| Scroll wheel        | Zoom         |
| Middle click drag   | Pan          |
| Right click         | Context menu |

## Tips

- Double-clicking a wire starts a new wire segment from that point
- `Esc` during wire placement closes the wire at the last junction
- Hold `Ctrl` while placing to snap to nearby pins
- `Shift+R` rotates by 90° in the other direction
