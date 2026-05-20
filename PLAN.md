# SchemifyRS Port Plan

## Status Snapshot

| Crate | State | Lines | Notes |
|-------|-------|-------|-------|
| core | DONE | ~1200 | 84 DeviceKind, 36 primitives, SoA Instance/Wire |
| handler | DONE | ~2150 | 50+ state types, 47 commands, undo/redo |
| io | DONE | ~800 | CHN reader/writer, config parser |
| display | EMPTY | 0 | egui stub only |
| sim | EMPTY | 0 | types in core, no logic |
| plugins | EMPTY | 0 | state types in handler, no runtime |

**External dep**: `spice-to-schematic` — will vendor under `handler/src/import/` (wave 2).

---

## Resolved Architecture Decisions

### From grill session (2026-05-19)

1. **Connectivity boundary**: `Connectivity` struct in core (cross-boundary type). `resolve()` logic in handler. Sim receives `&Connectivity` as arg — never computes it. Handler is the orchestrator.

2. **Display trait boundary**: Split traits in core:
   - `AppRead` — render surface (returns core types + primitives only). Canvas codes against this. Testable with mocks.
   - `AppWrite` — mutations (`dispatch(Command)`, setters). Input handler codes against this.
   - Panels/dialogs read handler state directly (cold path, pragmatic).

3. **Canvas + Interaction merged**: one agent, tightly coupled (shared coordinate system, hit regions, event loop).

4. **`InstanceFlags::transform_point`**: trivial method in core. Both connectivity (pin resolution) and display (symbol rendering) need it. ADR-001 compliant (same category as constructors).

5. **Fat connectivity**: pre-compute everything once (nets, point-to-net, per-instance connections, net names). Cache in `Document`. Data-oriented: compute → flat arrays → read many.

6. **egui 0.31** (latest). No existing code to migrate.

7. **Plugin-customizable display**: panels + commands + canvas overlays + theme/layout override. Slot + hook model for extension points. Token-level theme (~30-50 named tokens). Plugin overlay = additional shape layer.

8. **Layered shape cache**: each layer = `Vec<egui::Shape>` with dirty flag. Rebuild only changed layers per frame. Plugin overlays = additional layers in stack.

9. **Hot path minimization**: handler does ZERO per-frame work. `AppRead` returns references to pre-computed, cached data. Selection exposed as `&HashSet<usize>` (batch-friendly), not per-item queries.

10. **Spice-to-schematic vendoring**: strip CLI + pyo3 deps, keep anyhow/thiserror/serde_json. Move under `handler/src/import/`. Wave 2 task.

11. **Git workflow**: feature branches per agent (`feat/connectivity`, `feat/plugin-types`, etc.). Commit after every meaningful change.

---

## Dependency Graph

```
core (DONE)
 ├─► Connectivity struct (NEW — cross-boundary type)
 ├─► AppRead / AppWrite traits (NEW)
 ├─► ThemeTokens, SlotId, OverlayLayer (NEW — plugin types)
 │
 ├─► handler: resolve() logic, impl AppRead/AppWrite
 │    ├─► display: renders via AppRead, mutates via AppWrite
 │    │   └─► consumes ThemeTokens, OverlayLayer, SlotId
 │    └─► sim: receives &Connectivity as arg from handler
 │         └─► optimizer (wave 2+)
 ├─► plugins (wave 2 — runtime, JSON-RPC)
 └─► import (wave 2 — vendor spice-to-schematic, XSchem)
```

---

## Wave 1: Active (4 parallel agents)

Detailed TODOs in `docs/todo/`.

| Agent | Stream | Branch | Crate | TODO File |
|-------|--------|--------|-------|-----------|
| A1 | Connectivity | `feat/connectivity` | core + handler | `docs/todo/A1-connectivity.md` |
| A2 | Plugin types | `feat/plugin-types` | core | `docs/todo/A2-plugin-types.md` |
| A3 | Canvas + interaction | `feat/canvas` | core + display + handler | `docs/todo/A3-canvas.md` |
| A4 | SPICE IR | `feat/spice-ir` | sim | `docs/todo/A4-spice-ir.md` |

**Parallelism**: all 4 start now, touch different crates.
- A1: handler + core (Connectivity struct, transform_point)
- A2: core only (theme, plugin_types modules)
- A3: display + core (traits) + handler (trait impls)
- A4: sim only

**Conflict zones**: A1, A2, A3 all touch `core/src/`. Mitigated by different files:
- A1 adds to `types.rs`
- A2 creates `theme.rs` + `plugin_types.rs`
- A3 creates `traits.rs`

---

## Wave 2: After wave 1 merges

| Agent | Stream | Depends On | Crate |
|-------|--------|------------|-------|
| A5 | Panels + Dialogs | A3 (canvas scaffold) | display |
| A6 | Plugin Runtime | A2 (plugin types) | plugins |
| A7 | Netlist Generation | A1 (connectivity) + A4 (SPICE IR) | sim |
| A8 | Vendor spice-to-schematic | — | handler |

## Wave 3: After wave 2

| Agent | Stream | Depends On | Crate |
|-------|--------|------------|-------|
| A9 | Backend Integration | A7 (netlist) | sim |
| A10 | Export (SVG/PNG/PDF) | A3 (canvas) | display |
| A11 | XSchem Importer | — | io or new import crate |

## Wave 4: Post-MVP

| Agent | Stream | Depends On | Crate |
|-------|--------|------------|-------|
| A12 | Optimizer | A9 (backend) | sim |
| A13 | Other Importers (Virtuoso, VerilogA) | — | import |
| A14 | WASM plugin transport | A6 (plugin runtime) | plugins |

---

## MVP Definition

**Must have** (waves 1-2):
- Connectivity (A1)
- Plugin types (A2)
- Canvas + interaction (A3)
- Panels + dialogs (A5)
- Netlist gen (A7)

**Nice to have** (wave 3):
- Backend integration (A9)
- Export (A10)

**Defer**:
- Optimizer (A12)
- Non-SPICE importers (A13)
- WASM plugins (A14)
