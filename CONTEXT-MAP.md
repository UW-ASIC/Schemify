# SchemifyRS Context Map

## Crate Dependency Graph

```
                  ┌──────────┐
                  │   core   │  Shared vocabulary (types only, zero logic)
                  └────┬─────┘
                       │
          ┌────────────┼────────────┬──────────┐
          │            │            │          │
     ┌────▼───┐  ┌─────▼────┐ ┌────▼───┐ ┌───▼────┐
     │handler │  │ devices  │ │  sim   │ │plugins │
     │(state) │  │(PDK load)│ │(spice) │ │(C-ABI) │
     └────┬───┘  └──────────┘ └────────┘ └────────┘
          │
     ┌────▼───┐
     │display │  GUI (egui). Reads handler, dispatches Commands.
     └────────┘
```

## Boundary Rule (ADR-001)

> **Core contains types that cross crate boundaries whole.
> State contains types that handler decomposes into primitives at its API surface.**

## What Lives Where

### `schemify-core` — Shared Types

Domain data that multiple crates reference directly. Zero logic, zero state.

| Module | Types | Why in core |
|---|---|---|
| `types` | `Sym`, `DeviceKind`, `SchematicType`, `PinDirection`, `InstanceFlags`, `Color` | Foundation types used everywhere |
| `schematic` | `Schematic`, `Instance`/`InstanceVec`, `Wire`/`WireVec`, `Pin`, shapes, `Property`, `ModelDef` | Display reads `&WireVec`, `&InstanceVec` to render |
| `commands` | `Command`, `Tool` | Display constructs, handler processes |
| `simulation` | `SimResult`, `Waveform`, `Measurement`, `OpPoint`, `SimError`, `SpiceBackend` | Sim produces, display renders waveforms |
| `devices` | `Pdk`, `CellInfo` | Devices crate loads, display shows library browser |

### `schemify-handler` — State + Pure Functions

Private internals. Consumers never see these types.

| Category | Key Types | Exposed via accessor as |
|---|---|---|
| App root | `AppState` | Opaque `App` struct |
| Interner | `lasso::Rodeo` | `resolve(Sym) -> &str` |
| Viewport | `Viewport` | `zoom() -> f32`, `pan() -> [f32; 2]` |
| Selection | `Selection` | `is_instance_selected(idx) -> bool` |
| Canvas | `CanvasState`, `PanMode` | Internal interaction tracking |
| Dialogs | `DialogStates`, find/props/settings/... | Internal GUI state |
| Undo/Redo | `UndoEntry`, history deques | `can_undo() -> bool` |
| Clipboard | `Clipboard` | `has_clipboard() -> bool` |
| Config | `ProjectConfig`, `ProjectPaths` | `project_name() -> &str` |
| Connectivity | `Connectivity`, `NetConnection` | `net_at(x, y) -> Option<&str>` |
| View flags | `ViewFlags`, `ViewMode` | `is_dark_mode() -> bool` |
| Plugins | `PluginUiState`, plugin blob storage | Panel management |
| Optimizer | `OptimizerWindowState` | Internal optimization tracking |
| Persistence | `PersistentSettings`, `LastSessionState` | `ui_scale() -> f32` |
| Documents | `Document`, `Origin` | Schematic data via `wires()`, `instances()` |
| Backend | `BackendAvailability` | `is_backend_available(SpiceBackend) -> bool` |

### Other Crates

| Crate | Depends on | Role |
|---|---|---|
| `schemify-display` | core, handler | egui GUI. Reads handler accessors, dispatches `Command`s |
| `schemify-devices` | core | Loads PDK from disk into `Pdk`/`CellInfo` |
| `schemify-sim` | core | Runs SPICE via PySpice, produces `SimResult` |
| `schemify-plugins` | core | C-ABI plugin host. Dispatches `Command`s, reads via handler |

## Data Flow

```
User input (keyboard/mouse)
  → display constructs Command (from core)
  → display calls app.dispatch(cmd)
  → handler interns strings, mutates private AppState
  → handler pushes undo entry
  → display reads updated state via accessors
  → display resolves Sym → &str via app.resolve()
  → display renders frame
```

## Data-Oriented Design (ADR-004)

- **String interning:** `Sym` (4 bytes) replaces `String` (24 bytes) in hot types
- **Property pool:** Shared vec, instances index with `(start, count)`
- **SoA:** `Wire`/`Instance` via `soa_derive` (bulk iteration by field)
- **AoS:** Shapes, Pin, CellInfo (individual access, all fields together)
- **Packed:** `#[repr(u8)]` enums, `InstanceFlags` as u8, `Color::NONE` sentinel

## Key Invariants

1. **All mutation goes through `dispatch(Command)`**. No setters, no `&mut` leaks.
2. **All commands are undoable**. Single flat `Command` enum (ADR-003).
3. **Core has zero logic**. Only `#[derive]` impls and trivial constructors.
4. **Handler never depends on display**. Data flows one way.
5. **Sym values are only valid within their interner's lifetime**. Handler owns the interner.
