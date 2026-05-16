# gui

Immediate-mode GUI for the schematic editor. Builds the entire UI every frame from application state. All mutation flows through the command queue — the GUI never writes to the Schematic directly.

## Language

**Document**:
An open Schematic in the editor. Wraps a Schematic with its file path, selection state, viewport, and undo history. One Document per tab.
_Avoid_: file, tab (the UI element representing a Document), project (multiple Documents)

## Relationships

- A **Document** contains exactly one Schematic (defined in the schematic module)
- The GUI produces Commands (defined in the commands module) — it never mutates a Schematic directly
- The GUI renders Plugin panels (defined in the plugins module) via a type-erased host interface
- The GUI reads settings (defined in the settings module) for theme and keybind configuration

## Example dialogue

> **Dev:** "What happens when I open a file?"
> **Domain expert:** "A new **Document** is created — it wraps the parsed Schematic along with a fresh selection, viewport, and undo history. A tab appears in the tab bar representing that **Document**."

> **Dev:** "If I have three tabs open, are those three Schematics?"
> **Domain expert:** "Three **Documents**. Each one holds a Schematic, but a **Document** also carries the editor state for that tab — where you're zoomed, what's selected, your undo stack."

## Flagged ambiguities

- **"State"** is heavily overloaded: `AppState` (global singleton), `GuiState` (per-frame visual state), `ToolState` (current tool mode), dialog states, marketplace state. In domain terms, none of these are named concepts — they're implementation of the editor.
- **`state.zig`** is a separate build module (not part of gui proper) to break the gui-commands circular dependency. In domain terms, it's still part of the GUI's responsibility.
