# ADR-001: Core vs State Boundary Rule

**Status:** Accepted
**Date:** 2026-05-19

## Context

SchemifyRS has two foundational crates:

- `schemify-core` — shared type definitions
- `schemify-handler` — state management + pure function API

Other crates (`display`, `plugins`, `sim`, `devices`) consume handler through its public API. They never see `AppState` or any internal state struct directly. State is either opaque or read-only through accessor functions.

We need a concrete, testable rule for deciding where a type lives.

## Decision

**A type belongs in `core` if it crosses a crate boundary whole — as a function argument, return type, or slice element. If handler can decompose it into primitives (`f32`, `bool`, `usize`, `&str`) at its API surface, it belongs in `state`.**

### Core (shared vocabulary)

Types that multiple crates must speak about as-is:

- **Schematic data** — `Instance`, `Wire`, `Pin`, `Line`, `Rect`, `Circle`, `Arc`, `Text`, `Polygon`, `Property`, `ModelDef`
- **Commands** — `Command`, `Tool` (display constructs these, handler processes them)
- **Simulation results** — `SimResult`, `Waveform`, `Measurement`, `OpPoint`, `SimError`
- **Device library** — `Pdk`, `CellInfo`
- **Enums & primitives** — `DeviceKind`, `SchematicType`, `PinDirection`, `Color`, `InstanceFlags`, `SpiceBackend`

### State (private memory)

Types that only handler needs internally. Consumers get decomposed primitives through handler's API:

- **Viewport** — handler exposes `zoom() -> f32`, `pan() -> [f32; 2]`
- **Selection** — handler exposes `is_instance_selected(idx) -> bool`, `selected_count() -> usize`
- **All dialog/panel state** — `DialogStates`, `SettingsDialogState`, `FindDialogState`, etc.
- **Canvas interaction** — `CanvasState`, `PanMode`, rubber band, drag tracking
- **Clipboard** — internal copy buffer
- **Undo/Redo** — `UndoEntry`, history deques
- **Project config** — `ProjectConfig`, `ProjectPaths` (handler exposes `project_name() -> &str`)
- **Connectivity** — handler exposes `net_at(x, y) -> Option<&str>`, consumers don't walk net topology
- **GUI bookkeeping** — `ViewFlags`, `ViewMode`, optimizer window state, plugin UI state, etc.
- **Session persistence** — `PersistentSettings`, `LastSessionState`

### The Test

When adding a new type, ask: **"Does a crate other than handler need to hold, match on, or iterate over this type?"**

- Yes → `core`
- No, handler can expose its data as primitives or slices of existing core types → `state`

## Consequences

- `core` stays small and stable. Changes to core ripple to all consumers.
- `state` can evolve freely. Internal refactors don't break display or plugins.
- Handler's public API is the single control surface. All reads go through accessors, all writes through `dispatch(Command)`.
- `Origin`, `ProjectConfig`, `Connectivity` move out of core into handler-internal state.
