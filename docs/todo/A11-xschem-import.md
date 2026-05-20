# A11: XSchem Importer

**Wave**: 3
**Depends on**: nothing (only needs core)

## Goal
Import XSchem `.sch` and `.sym` files into Schemify schematics. Includes PDK remapping and a minimal TCL evaluator for xschemrc.

## Branch
`feat/xschem-import`

## Zig Reference Files
- `../Schemify/src/import/lib.zig` — entry point (importProject)
- `../Schemify/src/import/types.zig` — ConvertResult, ImportSource
- `../Schemify/src/import/XSchem/mod.zig` — main backend
- `../Schemify/src/import/XSchem/reader.zig` — .sch file parser
- `../Schemify/src/import/XSchem/converter.zig` — XSchem → Schemify
- `../Schemify/src/import/XSchem/exporter.zig` — Schemify → XSchem (round-trip)
- `../Schemify/src/import/XSchem/pdk_remap.zig` — PDK model mapping
- `../Schemify/src/import/XSchem/props.zig` — XSchem property parsing
- `../Schemify/src/import/XSchem/xschemrc.zig` — xschemrc support
- `../Schemify/src/import/XSchem/types.zig` — XSchem types
- `../Schemify/src/import/XSchem/TCL/` — TCL interpreter (tokenizer, evaluator, expr, commands)

## Crate/File Map

### Option A: new crate `crates/import/`
### Option B: module in `crates/io/src/import/`

Recommend **Option A** — import is complex enough (TCL eval alone is ~500 lines) to warrant its own crate.

### import (`crates/import/src/`)
- `lib.rs` — public API: `import_xschem(path, interner) -> Vec<Schematic>`
- NEW `xschem/mod.rs` — orchestrator
- NEW `xschem/reader.rs` — parse .sch/.sym files line by line
- NEW `xschem/types.rs` — XSchem-specific types (XSchemComponent, XSchemWire, etc.)
- NEW `xschem/converter.rs` — XSchem types → Schemify Schematic
- NEW `xschem/props.rs` — XSchem property string parsing (key=value pairs in braces)
- NEW `xschem/pdk_remap.rs` — sky130/xh018/etc model name mapping
- NEW `xschem/exporter.rs` — Schemify → XSchem (round-trip)
- NEW `tcl/mod.rs` — minimal TCL evaluator
- NEW `tcl/tokenizer.rs` — TCL tokenizer
- NEW `tcl/evaluator.rs` — TCL evaluator (variable expansion, control flow)
- NEW `tcl/expr.rs` — TCL expression parser (math expressions)
- NEW `tcl/commands.rs` — built-in commands (set, puts, if, foreach, proc, source)

### import Cargo.toml
```toml
[dependencies]
schemify-core = { path = "../core" }
lasso = "0.7"
```

## XSchem .sch Format
```
v {xschem version=3.4.5 file_version=1.2}
G {}
K {}
V {}
S {}
E {}
T {text} x y rotation flip size ...
C {symbol_path} x y rotation flip {props}
N x0 y0 x1 y1 {net_label}
L layer x0 y0 x1 y1 ...
B layer x0 y0 x1 y1 ...
A layer cx cy r start_angle sweep ...
P layer npins pin_x pin_y dir ...
```

Key sections:
- `C` = component instance
- `N` = wire (net)
- `T` = text
- `L` = line, `B` = box, `A` = arc
- `P` = pin definition (in .sym files)

## Checklist
- [ ] `xschem/reader.rs`: parse .sch file → Vec<XSchemElement>
- [ ] `xschem/reader.rs`: parse .sym file → XSchemSymbol
- [ ] `xschem/types.rs`: XSchem element types
- [ ] `xschem/props.rs`: parse `{key=value key2=value2}` property strings
- [ ] `xschem/converter.rs`: XSchem elements → Schematic (instances, wires, geometry)
- [ ] `xschem/converter.rs`: handle rotation/flip (XSchem uses 0-3 rotation + flip flag)
- [ ] `xschem/converter.rs`: resolve symbol paths to DeviceKind
- [ ] `xschem/pdk_remap.rs`: sky130 model name mapping
- [ ] `xschem/pdk_remap.rs`: xh018 model name mapping
- [ ] `xschem/exporter.rs`: Schematic → .sch file string (round-trip)
- [ ] `tcl/tokenizer.rs`: tokenize TCL source
- [ ] `tcl/evaluator.rs`: variable expansion ($var, ${var})
- [ ] `tcl/evaluator.rs`: command substitution [cmd args]
- [ ] `tcl/commands.rs`: set, puts, if, foreach, proc, source, lappend, file
- [ ] `tcl/expr.rs`: arithmetic/comparison expressions
- [ ] Apply xschemrc: extract XSCHEM_LIBRARY_PATH, search paths
- [ ] Tests: parse simple .sch file
- [ ] Tests: parse .sym file with pins
- [ ] Tests: property string parsing
- [ ] Tests: round-trip (import → export → import = same)
- [ ] Tests: TCL variable expansion
- [ ] Commit after each meaningful change

## Do NOT Touch
- `handler/` — handler calls import functions, you don't modify handler
- `display/` — not your crate
- `sim/` — not your crate
- `io/` — CHN format is separate from XSchem format
