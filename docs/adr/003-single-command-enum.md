# ADR-003: Single Flat Command Enum

**Status:** Accepted
**Date:** 2026-05-19

## Context

The original design split commands into `ImmediateCommand` (non-undoable, view/UI) and `UndoableCommand` (schematic mutations). This created a two-level dispatch: `Command::Immediate(...)` vs `Command::Undoable(...)`.

## Decision

All commands are undoable. Use a single flat `Command` enum.

```rust
pub enum Command {
    // View
    ZoomIn,
    ZoomOut,
    // ...
    // Schematic mutations
    DeleteSelected,
    PlaceDevice { .. },
    AddWire { .. },
    // ...
}
```

### Rationale

- Simpler dispatch — one match, no nesting.
- Consumers construct `Command::ZoomIn`, not `Command::Immediate(ImmediateCommand::ZoomIn)`.
- Undo system handles all commands uniformly. View commands can have lightweight undo (restore previous zoom/pan). Schematic mutations snapshot as before.

## Consequences

- `ImmediateCommand` and `UndoableCommand` are removed.
- Handler's undo system must handle view commands (trivial — store previous value as inverse).
- The `Command` enum in core is the single vocabulary of all actions in the app.
