# 03 — `Schematic` ↔ s2s-IR pure adapter (enables re-layout)

Status: ready-for-agent
Labels: feature-gap, refactor
Crate: schemify-handler
Complexity: M

## Problem

`convert_subcircuit` (`spice_import.rs:52-213`) is a one-way s2s-IR → core
`Schematic` conversion. There is no inverse, so:
- `Command::AutoLayout` (gui-linking/02) has no clean way to feed an existing
  `Schematic` back into the placement/routing engines.
- Round-trip tests reconstruct s2s-IR by hand.

## Goal

Factor a pure-function pair (per CLAUDE.md inter-crate boundary rules — input in,
output out, no hidden state):

```rust
pub fn schematic_from_subcircuit(sub: &Subcircuit, int: &mut Rodeo) -> Schematic;
pub fn subcircuit_from_schematic(sch: &Schematic, int: &Rodeo) -> Subcircuit;
```

## Acceptance criteria (TDD)

1. Property test on fixtures: `subcircuit_from_schematic(schematic_from_subcircuit(s))`
   round-trips topology (instances, nets, ports) — net/instance counts and
   connectivity preserved.
2. A `relayout(&mut Schematic)` helper built on the pair re-runs
   `placement::place` + `routing::Router::route`.
3. Both functions are pure (no I/O, no global state) and unit-tested in
   isolation with three lines of setup each (write the usage code first).
4. `cargo nextest run` green.

Unblocks: gui-linking/02 (AutoLayout), spice-to-schematic/02 (hierarchical).
