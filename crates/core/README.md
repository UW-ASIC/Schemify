# schemify_core

Shared types, enums, and traits used by every other crate. Nothing in `core` depends on the rest of the workspace — it is the leaf of the dependency tree.

## Files

### `types.rs` — Fundamental types

| Type | What it is |
|------|-----------|
| `Sym` | Interned string handle (`lasso::Spur`). Cheap to copy/compare, resolved via an interner. |
| `DeviceKind` | 87-variant enum classifying every device (resistors, MOSFETs, BJTs, sources, connectors, etc.). |
| `SchematicType` | `Schematic`, `Symbol`, `Testbench`, `Primitive` — what kind of document this is. |
| `PinDirection` | `Input`, `Output`, `InOut`, `Power`, `Ground`. |
| `InstanceFlags` | Packed u8 holding rotation (0-3), flip, and bus bits. |
| `Color` | RGBA struct. `Color::NONE` (alpha 0) means "use theme default". |
| `Connectivity` | Resolved net graph — nets, point-to-net map, per-instance pin connections. |

**How to add a new device kind:**
1. Add a variant to the `DeviceKind` enum.
2. Implement the match arms in `prefix()`, `default_pins()`, `model_keyword()`, `injected_net()`, `symbol_name()`, `from_name()`, `is_non_electrical()`, `is_label()`, `is_power()`.

### `commands.rs` — Command enum

Every user action is a `Command` variant — view changes, file ops, placement, wiring, transforms, simulation, plugins, etc. The handler dispatches these.

**How to add a new command:**
1. Add a variant to `Command`.
2. Handle it in `handler/src/dispatch.rs`.
3. If it needs a keybind, add an entry in `display/src/keybinds.rs`.
4. If it needs a menu item, add it in `display/src/chrome.rs`.
5. If it needs CLI access, add a `CliCommand` variant in `engine/src/main.rs`.

### `devices.rs` — PDK types

`Pdk` holds a map of `CellInfo` entries — each one describes a cell's symbol file, SPICE prefix, pin order, model name, and default parameters.

### `primitives.rs` — Built-in symbol library

36 embedded primitives (resistor, capacitor, nmos4, pmos4, gnd, vdd, etc.) with pin positions and drawing geometry.

**How to add a new primitive:**
1. Add an entry in the `build_table()` function with the primitive's name, kind, prefix, pins, parameters, and geometry.
2. Update the `prim_count()` test assertion.
3. Add a corresponding `DeviceKind` variant in `types.rs` if one doesn't exist.

### `schematic.rs` — Document model

`Schematic` is the central data structure — it holds instances (SoA), wires (SoA), pins, geometric shapes, properties, model definitions, plugin blocks, SPICE code, and simulation settings.

Key design choices:
- **SoA layout** — `Instance` and `Wire` use `soa_derive` so hot loops iterate positions without touching property data.
- **Property pool** — Instances index into a shared `Vec<Property>` via `prop_start`/`prop_count` to avoid per-instance allocation.

### `simulation.rs` — Simulation result types

`SimResult`, `Waveform`, `Measurement`, `OpPoint`, `SimError`, plus `SpiceBackend` and `StimulusLang` enums.

**How to add a new simulator backend:**
1. Add a variant to `SpiceBackend`.
2. Implement `as_str()` and `from_name()` arms.
3. Handle the new backend in `pyspice_rs` Python module if needed.

**How to add a new stimulus language:**
1. Add a variant to `StimulusLang`.
2. Implement `as_str()`, `from_name()`, `extension()`, and `is_python()` arms.
3. Update `ALL` constant.

### `theme.rs` — Theming

`ThemeTokens` holds 48 named tokens (colors, floats, bools). `dark()` and `light()` return presets. Plugins can push `ThemeOverride` to modify tokens by priority.

**How to add a new theme token:**
1. Add it to both `dark()` and `light()`.
2. Reference it in `display/src/theme.rs` palette resolution.
3. Update the `EXPECTED_TOKENS` test.

### `traits.rs` — Core traits

| Trait | Purpose |
|-------|---------|
| `AppRead` | Read-only access to schematic, view state, selection — used by display for rendering. |
| `AppWrite` | Mutable access — `dispatch(Command)` and canvas/cursor setters. |

### `plugin_types.rs` — Plugin UI types

Types for plugin integration: `SlotId` (7 UI slots), `PanelRegistration`, `CommandRegistration`, `OverlayShape` (Line, Circle, Rect, Text, Marker), `OverlayLayer`, and `WidgetNode` (30+ widget variants for plugin panels).

**How to add a new widget type:**
1. Add a variant to `WidgetNode` with serde attributes.
2. Handle rendering in `display/src/panels.rs` `render_widget()`.

**How to add a new overlay shape:**
1. Add a variant to `OverlayShape`.
2. Handle rendering in `display/src/canvas.rs`.

**How to add a new UI slot:**
1. Add a variant to `SlotId`.
2. Handle layout in `display/src/panels.rs`.
