# 06 — WASM raw-SPICE import smoke test + PySpice-unavailable UX

Status: ready-for-agent
Labels: feature-gap, test
Crate: schemify-handler, schemify-display
Complexity: S

## Problem

PySpice import is unavailable under wasm (`dispatch.rs:541-544` returns an error
string), but raw-SPICE text import still works. There is no test guarding the
wasm path, and the import dialog does not disable the PySpice option on wasm.

## Acceptance criteria (TDD)

1. A `#[cfg(target_arch = "wasm32")]`-gated test asserts raw-SPICE
   `import_spice` works (no `python3` dependency).
2. The import dialog hides/greys the PySpice source option when compiled for
   wasm.
3. `cargo build --target wasm32-unknown-unknown` (or `trunk build`) succeeds.
4. `cargo nextest run` green on native.
