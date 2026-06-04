# User Interface

Schemify uses an immediate-mode GUI built with egui. The interface is minimal and keyboard-driven.

## Layout

```
┌──────────────────────────────────────────────────────┐
│  Menu Bar                                            │
├──────────┬───────────────────────────────┬────────────┤
│          │                               │            │
│  Left    │       Schematic Canvas        │   Right    │
│  Sidebar │                               │  Sidebar   │
│          │                               │            │
│          │                               │            │
├──────────┴───────────────────────────────┴────────────┤
│  Bottom Bar / Status                                  │
└──────────────────────────────────────────────────────┘
```

- **Menu Bar** -- file operations, edit commands, view toggles, simulation controls
- **Schematic Canvas** -- the main editing area with an infinite grid
- **Left Sidebar** -- component browser and hierarchy navigator (extensible via plugins)
- **Right Sidebar** -- properties panel, net inspector (extensible via plugins)
- **Bottom Bar** -- status messages, simulation output, command mode input
- **Status Bar** -- current tool, zoom level, cursor position

## Tabs

Schemify supports multiple open documents as tabs:

- **Ctrl+T** -- open a new tab
- **Ctrl+W** -- close the current tab
- Click a tab header to switch

## Canvas Navigation

| Action | Input |
|---|---|
| Pan | Middle-click drag, or scroll while holding Shift |
| Zoom in / out | Scroll wheel, or **Ctrl+=** / **Ctrl+-** |
| Zoom to fit | **F** or **Z** |
| Reset zoom | **Ctrl+0** |
| Toggle grid | **G** |

## View Modes

Switch between different views of your design:

- **S** -- Schematic view (default) -- edit the circuit
- **Shift+V** -- Symbol view -- edit the graphical symbol for the current schematic

## Theme

Schemify supports dark and light themes with 48 named color tokens. Toggle with the menu or the `toggle-color-scheme` command.

## Command Mode

Press **:** (Shift+Semicolon) to open the command palette. Type any command name and press Enter to execute it. This gives you access to every operation without memorizing shortcuts.
