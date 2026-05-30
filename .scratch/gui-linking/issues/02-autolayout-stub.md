# 02 — `Command::AutoLayout` is a stub

Status: ready-for-agent
Labels: bug, feature-gap
Crate: schemify-handler (+ display menu/shortcut)
Complexity: M
Depends on: gui-linking/01 (display must compile), spice-to-schematic/03 (the
relayout primitive). Implement the engine in s2s/03; this issue wires the
Command + GUI entry point.

## Problem

`crates/handler/src/dispatch.rs:512`:

```rust
Command::AutoLayout => Err("Auto-layout not yet implemented".to_string()),
```

The placement (`handler/src/s2s/placement/`) and routing
(`handler/src/s2s/routing/`) engines already exist and run at import time, but
there is no way to re-run them on an already-loaded schematic.

## Acceptance criteria (TDD)

1. Dispatching `Command::AutoLayout` on a hand-built schematic (instances with
   arbitrary coords, wires) snaps instances onto the placement grid and
   re-routes wires via the existing A* router.
2. The operation is a single undo entry; undo restores prior geometry exactly.
3. A handler test builds a 3-instance schematic, dispatches `AutoLayout`,
   asserts instances are grid-aligned and net connectivity is preserved
   (same `net_at` results before/after for the same logical nets).
4. Display has a menu item / shortcut that constructs `Command::AutoLayout`
   (verify it is reachable, not just defined).
5. `cargo nextest run` green.

## Notes

Requires the `Schematic` ↔ s2s-IR adapter from `spice-to-schematic/03`; without
it, this arm would have to reconstruct s2s-IR ad hoc. Land s2s/03 first.
