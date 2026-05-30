# 02 — Hierarchical subcircuit import (multi-sheet)

Status: ready-for-agent
Labels: feature-gap
Crate: schemify-handler
Complexity: L

## Problem

The parser builds nested `.subckt` definitions and the pipeline places/routes
each (`spice_import.rs:27-35`), but `convert_subcircuit` only converts
`circuit.top` into a single `Schematic` (`spice_import.rs:42`). Child subcircuits
are **not** emitted as separate sheets/symbols — each X-instance collapses to a
flat `DeviceKind::Subckt` placeholder with no generated child schematic.

## Acceptance criteria (TDD)

1. Importing a netlist with one `.subckt` produces **two** `Schematic`s (parent
   + child) and an auto-generated symbol for the child.
2. The parent's X-instance references the child symbol (not a flat placeholder).
3. Net continuity across the subckt port boundary holds (a test asserts the
   parent pin nets map to the child port nets).
4. Nested subckts (subckt within subckt) produce N+1 sheets.
5. `cargo nextest run` green.

Depends on: 03 (the `schematic_from_subcircuit` adapter makes this cleaner).
