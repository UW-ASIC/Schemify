# schemify_handler

Application logic layer. Owns the `App` struct that holds all state, processes every `Command`, manages undo/redo, and coordinates simulation, I/O, and plugins. This is the "brain" — display only reads from it, engine only calls into it.

## Files

### `lib.rs` — App handle

`App` is the single entry point for all mutation via `dispatch(Command)`. Implements `AppRead` (schematic access, view state, selection) and `AppWrite` (dispatch, canvas setters). Also provides file I/O (`open_file`, `save_to_path`), simulation (`run_simulation`, `generate_netlist`), and plugin integration.

### `state.rs` — Application state

All runtime state, organized by access temperature:

| Struct | What it holds |
|--------|--------------|
| `Document` | Per-tab: schematic, name, origin, viewport, selection, undo/redo stacks, connectivity cache, sim results. |
| `Viewport` | Pan and zoom. |
| `Selection` | `HashSet<usize>` per object type (instances, wires, lines, rects, circles, arcs, texts, polygons). |
| `ToolState` | Active tool, wire start point, placement state, draw state, snap settings, bus mode. |
| `CanvasState` | Cursor position, move accumulator. |
| `ViewState` | Canvas size, grid toggle, view flags, layers. |
| `DialogStates` | Open/closed state for every dialog. |
| `PersistentSettings` | User preferences. |

### `dispatch.rs` — Command handlers

Every `Command` variant is handled here. Categories: meta (undo/redo), view, file, selection, clipboard, tool, dialogs, movement, nudge (coalesced), transform, deletion, duplication, placement, wiring, geometry, properties, simulation, layout, symbol generation, import, plugins.

**Undo strategy:** `UndoEntry::Inverse(Command)` for simple invertible commands, `UndoEntry::Snapshot(Schematic)` for complex operations. Nudges coalesce into a single `MoveSelected`.

**How to add a new command handler:**
1. Add the `Command` variant in `core/src/commands.rs`.
2. Add a match arm in `dispatch()`.
3. If undoable, push an `UndoEntry` before mutating.

### `connectivity.rs` — Net resolution

Pure function `resolve()` computes connectivity from wire endpoints and instance pins. Uses union-find with path compression. Detects T-junctions, merges nets by proximity and explicit names, auto-names unnamed nets.

### `geometry.rs` — Hit testing & selection

`HitResult` enum: Instance, Wire, Line, Rect, Circle, Arc, Text, Polygon, Nothing. Priority-ordered hit testing for click targets. `select_in_rect()` for rubber-band selection. Includes geometry helpers (point-to-segment distance, angle normalization, point-in-polygon).

### `netlist.rs` — Schematic to CircuitIR

`to_circuit_ir()` converts a `Schematic` into the simulation IR. Resolves connectivity, maps instances to `Component` types, collects parameters, handles model definitions. The output is serialized to JSON and passed to PySpice.

### `transform.rs` — Bounding box & collection ops

`BoundsAccum` for bounding box accumulation. `SchematicCollection` trait implemented for all SoA/AoS element vectors.

### `spice_import.rs` — SPICE netlist import

`import_spice()` (flat) and `import_spice_hierarchical()` (with subcircuits) run the full s2s pipeline: parse → annotate → recognize → place → route → convert to `Schematic`.

### `examples.rs` — Embedded example schematics

Include guard for generated example files.

### `plugin_dist.rs` — Plugin lifecycle actions

`PluginAction` enum (12 variants) for install/uninstall workflows. `install_actions()` and `uninstall_actions()` return action plans; the engine executes them.

---

## `s2s/` — SPICE-to-Schematic Pipeline

Converts a SPICE netlist into a placed-and-routed schematic. The pipeline flows:

```
SPICE text → parse → annotate → recognize → place → route → output
```

### `s2s/parser/` — SPICE parser

| File | What it does |
|------|-------------|
| `mod.rs` | `SpiceParser::parse()` — line-by-line parser handling components, `.subckt`, `.model`, `.param`, `.include`, `.lib`, control blocks, `.global`, and pragmas. |
| `expr.rs` | Expression evaluator for `.param` values — tokenizer + recursive-descent parser supporting arithmetic, functions (`sin`, `cos`, `sqrt`, `log`, `exp`, `abs`, etc.), and SI suffixes. |
| `params.rs` | `resolve_params()` — fixed-point iteration to resolve `.param` dependencies. `substitute_params()` — replace resolved values in instance parameters. |

### `s2s/ir/` — Pipeline IR

| Type | What it is |
|------|-----------|
| `Primitive` | 17-variant enum: Nmos, Pmos, Npn, Pnp, Resistor, Capacitor, Inductor, Diode, Vsource, Isource, Vcvs, Vccs, Ccvs, Cccs, Jfet, BehavioralSource, Subcircuit. |
| `NetClass` | Power, Ground, Bias, Clock, DifferentialP/N, HighFanout, LocalSignal, Signal. |
| `PinDir` | Input, Output, Inout, Power, Ground, Bulk. |
| `Subcircuit` | Name, ports, instances, nets, wires, labels — the IR document. |
| `AnalysisBlock` | Collected `.tran`, `.ac`, `.dc`, `.meas`, `.save`, `.option`, `.control` directives. |

### `s2s/annotation/` — Net & port classification

`annotate()` classifies nets (power/ground/signal by name patterns and connectivity heuristics) and infers port directions. Also detects differential pairs.

### `s2s/recognition/` — Block pattern matching

Uses VF2 subgraph isomorphism to recognize analog building blocks:

| BlockType | What it matches |
|-----------|----------------|
| `DiffPair` | Two matched transistors with shared source |
| `CurrentMirror` | Diode-connected + mirror transistor |
| `Cascode` | Stacked transistors |
| `CascodeMirror` | Mirror + cascode combination |
| `PushPull` | NMOS + PMOS output stage |
| `CommonSource` | Single transistor amplifier |
| `SourceFollower` | Source-degenerated stage |
| `RcCompensation` | R-C compensation network |
| `WilsonMirror` | Wilson current mirror topology |
| `WidlarMirror` | Widlar current mirror topology |
| `ResistorDivider` | Two-resistor voltage divider |

**How to add a new block pattern:**
1. Add a variant to `BlockType`.
2. Create a pattern builder function in `patterns.rs` returning a `PatternGraph` with nodes and edges.
3. Add it to `all_patterns()` (sorted by node count, most specific first).
4. Add a placement function in `s2s/placement/mod.rs`.

### `s2s/placement/` — Instance placement

- Recognized blocks get template-based placement (diff pairs side-by-side, mirrors stacked, etc.).
- Remaining instances go through simulated annealing optimization.
- Cost function: hard constraint violations + HPWL + signal flow + aspect ratio.
- Constraints: symmetry, alignment, adjacency, rail-side, port location, proximity, matching.

**How to add a new placement constraint:**
1. Add a variant to the `Constraint` enum in `constraints.rs`.
2. Generate it in `constraint_gen.rs`.
3. Evaluate it in `cost.rs`.

### `s2s/routing/` — Wire routing

- `classify_nets()` decides Wire vs Label strategy per net (short Manhattan span → wire, global/power/high-fanout → label).
- A* pathfinding on an obstacle grid with bend and crossing penalties.
- L-shape fallback when A* fails or for simple two-pin nets.
- Post-processing: merge collinear segments, deduplicate, add T-junction labels.

### `s2s/output/` — Backend writers

| Backend | Output format |
|---------|--------------|
| `SchemifyBackend` | `.chn` files (native format) |
| `XschemBackend` | `.sch` files (XSchem format) |

Both implement the `Backend` trait (`resolve_symbol()`, `write_all()`) and `PinGeometry` trait (pin offset tables per device type).

**How to add a new output backend:**
1. Create a struct implementing `Backend` and `PinGeometry`.
2. Define pin offset tables for each device type.
3. Implement `write_all()` to generate the output format.

### `s2s/validation/` — Output validation

Checks: unique instance names, grid alignment, valid rotation values, wire orthogonality, no duplicate wires, net-label consistency. Returns `Vec<ValidationError>` with severity.

### `s2s/adapter.rs` — IR ↔ Core conversion

Maps between s2s `Primitive` enum and core `DeviceKind`. `schematic_from_subcircuit()` and `subcircuit_from_schematic()` for round-trip conversion. `relayout()` re-runs placement + routing on an existing schematic.
