# Commands Module Architecture

This module implements command handling for the schematic editor under `src/commands`.
It keeps command declaration (`command.zig`), dispatch (`Dispatch.zig`), and domain handlers (`*.zig`) separated.

## File layout

- `command.zig`
  - Defines command payload structs and top-level unions:
    - `Immediate`: UI/view actions that are **not** recorded in history.
    - `Undoable`: state mutations that are recorded as inverses.
  - Defines `CommandQueue` (frame-drained queue).
  - Re-exports `History`/`CommandInverse` from `Undo.zig`.
- `Dispatch.zig`
  - Single route point from `Command` to handler groups.
  - Defines the unioned `DispatchError` set from all handlers.
- Handler groups:
  - `View.zig`: viewport/display/export commands.
  - `Selection.zig`: selection/highlight operations.
  - `Clipboard.zig`: copy/cut/paste.
  - `Edit.zig`: transforms, delete/duplicate, place/delete/move/set/add/remove mutations.
  - `Wire.zig`: wire tool mode and wire topology edits.
  - `File.zig`: tab/file open/save/reload/clear commands.
  - `Hierarchy.zig`: descend/ascend and symbol/schematic variant saves.
  - `Netlist.zig`: netlist generation and output caching.
  - `Sim.zig`: waveform viewer launch + simulation kick-off.
  - `Undo.zig`: inverse types, bounded history, undo/redo command handling.
- `helpers.zig`
  - Shared predicates/helpers (`selInst`, `selWire`, `ptEq`, bitset growth+set helper).

## Runtime flow

1. UI/input emits `Command` values into `CommandQueue`.
2. Main loop drains queue each frame.
3. `dispatch(command, state)` routes to a handler module.
4. Undoable handlers push inverse entries into `state.history`.
5. `.undo` pops and applies inverse via `Undo.applyInverse`.

## Ownership and mutation conventions

- Handlers operate on `state` and active document (`state.active()`).
- Mutation commands set `fio.dirty = true` when content changes.
- Selection/highlight bitsets are resized before setting out-of-range bits.
- Clipboard/snapshot data may duplicate strings into allocator-owned buffers.
- History stores inverse actions, not the original forward command.

## Simplification opportunities (safe next steps)

- **Unify status+mode toggles**: several files still do repetitive `state.tool.active = ...; state.setStatus(...)` or boolean flag toggles.
- **Split large handlers by concern**: `Edit.zig` and `View.zig` are still the largest and include mixed responsibilities.
- **Centralize path derivation**: `.chn`/`.chn_prim` stem logic appears in multiple files.
- **Typed selection utilities**: current `helpers.zig` uses `anytype`; typed wrappers could improve compile-time diagnostics.
- **Redo support**: `Undo.zig` currently keeps inverse-only history.

## Invariants to preserve during refactors

- Keep `Immediate` and `Undoable` APIs stable (they are consumed across the app).
- Do not widen to `anyerror`; keep concrete error unions in `Dispatch.zig`.
- Preserve history semantics: push inverse only after successful mutation.
- Preserve selection-bitset safety (never set past `bit_length` without resize).
- Keep module boundary local: command declaration + dispatch + domain handlers.
