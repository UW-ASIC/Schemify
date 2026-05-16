# ADR-0002: Undo limited to invertible commands

## Status: accepted

## Context

Full undo/redo requires either:
1. **Snapshot-based:** Save full schematic state before each mutation. O(n) memory per undo step where n = schematic size. Simple but expensive for large schematics.
2. **Inverse-command-based:** Compute the reverse operation. O(1) memory per step. Only works for commands with clean mathematical inverses.
3. **Diff-based:** Capture before/after delta. O(delta) memory. Requires instrumented data structures.

At the time of implementation, the priority was getting basic undo working for the most common interactive operations (rotate, flip, nudge, move) where the inverse is trivial.

## Decision

Use inverse-command-based undo. `invertCommand()` returns the reverse for 10 of 23 Undoable variants (rotate, flip, nudge, move_instance, move_wire). Commands without a computable inverse (delete, place, property changes) silently skip undo recording — `Dispatch.zig` checks `invertCommand(und) != null` before pushing to history.

## Consequences

- **Pro:** Zero-allocation undo. The history ring stores `Undoable` values directly (fixed 64-entry array). No heap involvement.
- **Pro:** Correct for the commands it covers — rotation, flip, and move are exact inverses.
- **Con:** 13 of 23 Undoable variants cannot be undone: delete_selected, duplicate_selected, align_to_grid, place_device, add_wire, delete_instance, delete_wire, set_instance_prop, rename_instance, rename_net, set_spice_code, run_sim, plugin_mutation. Users get no feedback that these are non-undoable.
- **Con:** `delete_selected` destroying data with no recovery path is a significant usability gap.
- **Migration path:** Move to snapshot-based undo for the remaining commands. Store a compact schematic snapshot (instance array + wire array, no symbol data) before each non-invertible mutation. The History struct can be extended with a `union(enum) { inverse: Undoable, snapshot: *SchematicSnapshot }` without changing the dispatch interface.
