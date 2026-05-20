# A13: Other Importers (Virtuoso, VerilogA, PySpice)

**Wave**: 4 (post-MVP)
**Depends on**: A11 (XSchem importer — shares import utilities)

## Goal
Additional import backends: Cadence Virtuoso (CDL/Spectre netlists), Verilog-A module parser, PySpice script executor.

## Branch
`feat/other-importers`

## Zig Reference Files
- `../Schemify/src/import/Virtuoso/mod.zig` — Virtuoso importer
- `../Schemify/src/import/Virtuoso/oa.zig` — OpenAccess database
- `../Schemify/src/import/Virtuoso/skill.zig` — SKILL script support
- `../Schemify/src/import/VerilogA.zig` — Verilog-A parser
- `../Schemify/src/import/PySpice/mod.zig` — PySpice import
- `../Schemify/src/import/Router.zig` — wire routing for imported layouts
- `../Schemify/src/import/LabelPlacer.zig` — automatic label placement
- `../Schemify/src/import/PdkMap.zig` — PDK model name mapping

## Crate/File Map

### import (`crates/import/src/`)
- NEW `virtuoso/mod.rs` — CDL/Spectre netlist parser → Schematic
- NEW `virtuoso/cdl.rs` — CDL netlist parser
- NEW `virtuoso/spectre.rs` — Spectre netlist parser
- NEW `verilog_a/mod.rs` — Verilog-A module parser → Schematic symbol
- NEW `verilog_a/parser.rs` — Verilog-A tokenizer + parser
- NEW `pyspice/mod.rs` — execute PySpice-rs script, capture output, convert
- NEW `util/router.rs` — Manhattan wire routing from netlist connectivity
- NEW `util/label_placer.rs` — auto-place net labels at optimal positions
- NEW `util/pdk_map.rs` — universal PDK model name mapping

## Checklist

### Virtuoso
- [ ] CDL netlist parser (subcircuit, instance, net)
- [ ] Spectre netlist parser (different syntax from SPICE)
- [ ] Convert parsed netlist → Schematic (reuse routing/placement from spice import)
- [ ] Tests: parse sample CDL file

### Verilog-A
- [ ] Tokenizer for Verilog-A
- [ ] Parse module declaration (ports, parameters)
- [ ] Parse analog block (for documentation, not execution)
- [ ] Generate Schematic symbol from module interface
- [ ] Tests: parse simple Verilog-A module

### PySpice
- [ ] Execute Python script as subprocess
- [ ] Capture generated netlist from stdout
- [ ] Parse captured netlist → Schematic (reuse SPICE import)
- [ ] Tests: round-trip PySpice script

### Utilities
- [ ] Wire router: Manhattan routing from netlist connectivity graph
- [ ] Label placer: find optimal label positions (minimize overlap)
- [ ] PDK map: extensible model name mapping (sky130, xh018, gpdk045, etc.)
- [ ] Commit after each meaningful change

## Do NOT Touch
- `handler/` — handler calls import API
- `display/` — not your crate
- `sim/` — not your crate
- `io/` — CHN format is separate
