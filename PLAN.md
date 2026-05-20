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

**External dep**: `spice-to-schematic` crate handles SPICE import already.

---

## Dependency Graph

```
core (DONE)
 ├─► connectivity (NEW module in handler)
 │    ├─► display (needs connectivity for net highlight)
 │    └─► sim/netlist (needs connectivity for net resolution)
 │         └─► optimizer (needs sim results)
 ├─► plugins (independent — needs handler only)
 └─► import (independent — needs core only)
```

---

## Parallel Agent Streams

### Stream 1: Connectivity Engine
**Crate**: `handler` (new module `connectivity.rs`)
**Blocks**: display net-highlight, sim netlist gen
**Ref**: `src/schematic/connectivity.zig`

- [ ] Union-find data structure (point-key → root → net-id)
- [ ] Wire endpoint connection (same-position merge)
- [ ] T-junction detection (wire interior touches)
- [ ] Instance pin resolution (apply rotation/flip to pin positions)
- [ ] Net naming (explicit labels > auto `n0,n1,...`)
- [ ] `resolve(&Schematic, &Rodeo) -> Connectivity` pure fn
- [ ] Invalidation flag on schematic mutation (already wired in dispatch)
- [ ] Tests: simple nets, T-junctions, labeled nets, rotated instances

**Size**: ~400 lines. **Risk**: Low — pure algorithm, no deps.

---

### Stream 2: Display / GUI
**Crate**: `display`
**Ref**: `src/gui/` (~15 files)
**Depends on**: core, handler. Connectivity nice-to-have (net colors).

Split into sub-agents:

#### 2A: App Scaffold + Canvas Rendering
- [ ] eframe::App impl, main loop, theme (dark/light)
- [ ] Canvas widget: pan (middle-drag), zoom (scroll), grid
- [ ] Wire rendering (color, thickness, bus)
- [ ] Symbol rendering from `PrimEntry` geometry (segs, circles, arcs, text)
- [ ] Instance rendering (symbol + rotation/flip transform + name/param labels)
- [ ] Selection overlay (highlight, rubber-band rect)
- [ ] Ghost overlay (placement preview, wire-in-progress)

#### 2B: Input + Interaction
- [ ] Mouse hit detection (instance bbox, wire proximity, pin snap)
- [ ] Tool dispatch (select, wire, move, pan, draw tools)
- [ ] Keyboard shortcuts (keybind map → Command dispatch)
- [ ] Drag: move instance, rubber-band select, pan
- [ ] Wire drawing mode (click-click, orthogonal routing)
- [ ] Context menu (right-click on instance/wire/canvas)

#### 2C: Panels + Dialogs
- [ ] Tab bar (multi-document)
- [ ] Toolbar (tool buttons, zoom controls)
- [ ] Command bar (text command entry)
- [ ] File explorer panel (project tree)
- [ ] Library browser panel (primitive catalog)
- [ ] Properties dialog (instance props edit)
- [ ] Find dialog (search instances/nets)
- [ ] Settings dialog (theme JSON, keybinds)
- [ ] Import dialog
- [ ] Spice code editor dialog
- [ ] New primitive dialog

#### 2D: Export
- [ ] SVG export (canvas → SVG writer)
- [ ] PNG export (egui screenshot or re-render)
- [ ] PDF export (via svg2pdf or similar)

**Size**: ~3000-4000 lines total. **Risk**: High — largest stream, UI iteration.

---

### Stream 3: Simulation
**Crate**: `sim`
**Ref**: `src/simulation/` (Netlist.zig, SpiceIF.zig, results.zig, json_results.zig)
**Depends on**: core, connectivity (for net resolution)

#### 3A: Netlist Generation
- [ ] PySpice-rs Python script emission (hierarchical, flat, top-only)
- [ ] Device mapping: DeviceKind → spice line / built-in component
- [ ] Net naming from connectivity
- [ ] Subcircuit handling (descend hierarchy)
- [ ] `.model` / `.param` / `.include` emission
- [ ] Measurement declaration emission

#### 3B: SPICE IR
- [ ] `SpiceComponent` tagged enum (resistor, mosfet, bjt, diode, vcvs, subckt, raw...)
- [ ] `Value` enum (literal, param, expr)
- [ ] `emit_component(writer, comp)` → SPICE text
- [ ] Backend-specific dialect (ngspice, Xyce, LTspice, Spectre)

#### 3C: Backend Integration
- [ ] Subprocess launch (ngspice, Xyce)
- [ ] Result parsing (AC, DC, tran, op — `.raw` file or stdout)
- [ ] JSON result storage
- [ ] Backend availability probing
- [ ] Error extraction (convergence, syntax)

**Size**: ~1500 lines. **Risk**: Medium — needs connectivity first for netlist.

---

### Stream 4: Optimizer
**Crate**: `sim` (submodule `optimizer/`)
**Ref**: `src/simulation/optimizer/` (8 files)
**Depends on**: sim (3A/3C working)

- [ ] GMID lookup tables (MOSFET gm/ID design)
- [ ] GMIC lookup tables (BJT gm/IC design)
- [ ] Cubic spline interpolation
- [ ] Sweep engine (parameter sweep + callback sim)
- [ ] NSGA-II multi-objective optimizer (Pareto fronts)
- [ ] Testbench management (linked .chn_tb files, measurement extraction)
- [ ] PDK characterization framework

**Size**: ~2000 lines. **Risk**: High — math-heavy, needs working sim.
**Can defer**: Yes. Core editing works without optimizer.

---

### Stream 5: Plugins
**Crate**: `plugins`
**Ref**: `src/plugins/` (8 files)
**Independent**: only needs core + handler

- [ ] Plugin manifest parser (`plugin.toml`)
- [ ] PluginManager: discovery, resolution, lifecycle
- [ ] JSON-RPC 2.0 marshaling (serde_json)
- [ ] Runtime: spawn subprocess, pipe I/O, async read
- [ ] Host callbacks (register panel, push command, query state)
- [ ] Capability negotiation
- [ ] Panel rendering integration (widget tags → egui widgets)
- [ ] WASM transport (future — skip for MVP)

**Size**: ~1200 lines. **Risk**: Medium — IPC complexity.
**Can defer**: Yes. App works without plugins.

---

### Stream 6: Import System
**Crate**: new `crates/import/` or module in `io`
**Ref**: `src/import/` (15+ files)
**Independent**: only needs core
**Note**: SPICE import already done via `spice-to-schematic` crate.

#### 6A: XSchem Importer
- [ ] `.sch` file parser (Tcl-ish format)
- [ ] `.sym` file parser
- [ ] XSchem → Schemify converter (geometry + pins + props)
- [ ] PDK remapping (sky130, xh018)
- [ ] xschemrc TCL evaluator (tokenizer, evaluator, expr, commands)
- [ ] Round-trip exporter (Schemify → XSchem)

#### 6B: Other Importers
- [ ] Virtuoso/CDL importer
- [ ] Verilog-A parser
- [ ] PySpice script executor + converter

#### 6C: Import Utilities
- [ ] Wire router (Manhattan routing from netlist)
- [ ] Label placer (auto net-label placement)
- [ ] PDK model name mapping

**Size**: ~2500 lines (XSchem alone ~1500). **Risk**: High for XSchem (TCL eval).
**Can defer**: 6B entirely. 6A high value for existing users.

---

## Parallelism Matrix

```
Time ──────────────────────────────────────────────►

Stream 1 (Connectivity)  ████████░░░░░░░░░░░░░░░░░░
Stream 2A (Canvas)        ░░████████████░░░░░░░░░░░░
Stream 2B (Input)         ░░░░░░████████████░░░░░░░░
Stream 2C (Panels)        ░░░░░░░░░░████████████░░░░
Stream 2D (Export)        ░░░░░░░░░░░░░░░░░░████████
Stream 3A (Netlist)       ░░░░░░░░████████░░░░░░░░░░
Stream 3B (SPICE IR)      ████████░░░░░░░░░░░░░░░░░░
Stream 3C (Backend)       ░░░░░░░░░░████████░░░░░░░░
Stream 4 (Optimizer)      ░░░░░░░░░░░░░░░░████████░░
Stream 5 (Plugins)        ████████████░░░░░░░░░░░░░░
Stream 6A (XSchem)        ████████████░░░░░░░░░░░░░░
Stream 6B (Other Import)  ░░░░░░░░░░░░████████░░░░░░

Legend: █ = active  ░ = blocked/waiting
```

**Fully parallel from day 1**: 1, 2A, 3B, 5, 6A (5 agents)
**Unblocks after Stream 1**: 2B (needs hit detection context), 3A, 3C
**Unblocks after 3A+3C**: 4
**Sequential within display**: 2A → 2B → 2C → 2D

---

## MVP Definition (Minimum Viable Schematic Editor)

**Must have**:
- Stream 1 (connectivity)
- Stream 2A + 2B + 2C (display minus export)
- Stream 3A + 3C (netlist gen + one backend)

**Defer to post-MVP**:
- Stream 2D (export)
- Stream 4 (optimizer)
- Stream 5 (plugins)
- Stream 6 (import — SPICE already works)

---

## Agent Assignment

| Agent | Stream | Can Start Now | Blocked By |
|-------|--------|---------------|------------|
| A1 | Connectivity | YES | — |
| A2 | Canvas Render | YES | — |
| A3 | SPICE IR | YES | — |
| A4 | Plugins | YES | — |
| A5 | XSchem Import | YES | — |
| A6 | Input+Interaction | NO | A2 (canvas) |
| A7 | Netlist Gen | NO | A1 (connectivity) |
| A8 | Panels+Dialogs | NO | A2 (canvas scaffold) |
| A9 | Backend Integration | NO | A7 (netlist) |
| A10 | Optimizer | NO | A9 (backend) |
| A11 | Export | NO | A2 (canvas) |
| A12 | Other Importers | DEFER | — |
