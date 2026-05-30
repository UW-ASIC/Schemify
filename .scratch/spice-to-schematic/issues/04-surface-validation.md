# 04 — Surface s2s validation results to the user on import

Status: ready-for-agent
Labels: feature-gap, ux
Crate: schemify-handler, schemify-display
Complexity: S

## Problem

`s2s/validation/mod.rs` computes `ValidationError`s (unique names, grid
alignment, rotation, wire orthogonality, duplicate wires, net-label
consistency), but after `Command::ImportSpice` the dispatch path
(`dispatch.rs:523-577`) only reports a generic success message. Validation
warnings/errors are computed-capable but discarded.

## Acceptance criteria (TDD)

1. Import collects validation results and exposes them via a handler accessor
   (e.g. `last_import_diagnostics() -> &[Diagnostic]`).
2. A handler test imports a netlist crafted to trigger a known validation
   warning and asserts the accessor returns it.
3. The import dialog (`display/src/dialogs.rs:614-666`) renders the diagnostics
   list on completion.
4. `cargo nextest run` green.
