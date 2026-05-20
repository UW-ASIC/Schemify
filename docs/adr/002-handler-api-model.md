# ADR-002: Handler API Model

**Status:** Accepted
**Date:** 2026-05-19

## Context

`schemify-handler` owns all mutable state. Other crates need to read state and request mutations. We need to decide how handler exposes its API.

## Decision

Handler exposes an opaque `App` struct. State is private. Interaction is through:

1. **`dispatch(Command)`** — the only way to mutate state. All commands are undoable.
2. **Accessor methods** — read-only access, returning either:
   - References to core types: `&[Wire]`, `&[Instance]`, `Option<&SimResult>`
   - Primitives: `f32`, `bool`, `&str`, `usize`

### Rules

- `AppState` is a private field of `App`. No crate can construct or destructure it.
- No `&mut` references to state internals leak out.
- Every state mutation goes through `dispatch()`. There are no setter methods.
- Commands are a flat enum. No immediate/undoable split — all commands enter the undo system.

### Example API Shape

```rust
// handler/src/lib.rs
pub struct App { state: AppState }

impl App {
    pub fn new() -> Self;
    pub fn dispatch(&mut self, cmd: Command);

    // Read schematic data (returns core types)
    pub fn wires(&self) -> &[Wire];
    pub fn instances(&self) -> &[Instance];
    pub fn sim_results(&self) -> Option<&SimResult>;
    pub fn pdk(&self) -> Option<&Pdk>;

    // Read decomposed state (returns primitives)
    pub fn zoom(&self) -> f32;
    pub fn pan(&self) -> [f32; 2];
    pub fn is_instance_selected(&self, idx: usize) -> bool;
    pub fn active_doc_name(&self) -> &str;
    pub fn active_tool(&self) -> Tool;
    pub fn status_msg(&self) -> &str;
}
```

## Consequences

- Display constructs `Command` values (from core) and calls `dispatch()`.
- Display reads data through accessors. It never mutates state.
- Plugins interact through the same `dispatch()` + accessor model.
- Testing is straightforward: construct `App`, dispatch commands, assert on accessors.
