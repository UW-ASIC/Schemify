# Optimizer Plugin Architecture

## Scope

`plugins/Optimizer` builds a Schemify plugin named `Optimizer` (ABI v6).
Current runtime behavior is UI-focused: panel rendering, command handling, and plugin lifecycle hooks.

## Module Layout

- `src/main.zig`
  - Plugin entrypoint and exported ABI symbols via `Framework.define(...).export_plugin()`.
  - Maintains plugin-local state (`status`, `iteration`, status message buffer).
  - Handles widget events (`Run`, `Stop`, `Reset`) and command tags (`optimizer_run`, `optimizer_stop`).
- `src/problemizer.zig`
  - Domain model for future circuit optimization orchestration.
  - Defines `Primitive`, `Component`, `Specification`, `Testbench`, `Observation`, `Problem`, and `CircuitOptimizer` generic.
  - Contains stubs for `TestbenchRunner` and `CircuitLoader`.
- `src/backend/backend.zig`
  - Backend contract validation (`validateBackend`) and backend type definitions.
  - Includes in-tree Bayesian and Python backend skeletons plus TRACE acquisition helpers.
- `build.zig`
  - Uses `schemify_sdk` helper APIs to compile/install the native plugin artifact.

## Runtime Flow (Current)

1. Schemify loads plugin and calls `on_load`.
2. UI panel draw callback emits labels/buttons from the current `State`.
3. Button callbacks mutate `State`, set host status text, and request panel refresh.
4. Command callback maps command tags to state transitions.
5. Unload callback resets state and logs unload event.

## State Model

- `OptStatus`: `idle | running | done | err`
- `iteration`: loop counter displayed in panel
- `msg_buf` + `msg_len`: bounded status message storage for panel display

State mutation is centralized through small helper functions in `src/main.zig` to keep transitions consistent.

## Notes On Extensibility

- `problemizer.zig` and `backend/backend.zig` are not wired into `src/main.zig` runtime yet.
- The intended integration path is:
  - map panel/commands to optimizer execution steps,
  - use `Problem` + backend to generate candidates,
  - evaluate candidates through a concrete `TestbenchRunner`.
