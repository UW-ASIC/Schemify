# import

Import schematics from external EDA tools into Schemify's native format.

## Functionality

- **EasyImport facade**: unified `init → convertProject` API across backends
- **XSchem backend**: .sch/.sym parsing, symbol resolution, xschemrc Tcl evaluation, PDK remapping (Sky130, GF180MCU, IHP SG13G2)
- **Virtuoso backend**: CDL + Spectre netlist parsing, cds.lib resolution, analogLib/PDK cell mapping, pin translation
- **SPICE backend**: netlist → schematic pipeline (parse → layout → route → Schemify)
- **TCL evaluator**: subset interpreter for xschemrc files (set, if, proc, foreach, expr, switch, regexp, source, namespace)

## Public API

- `EasyImport.init(alloc, path, backend_kind)` → facade entry point
- `EasyImport.convertProject()` → `ConvertResultList`
- `EasyImport.getFiles()` → XSchem file listing (xschem backend only)
- `BackendKind` — enum: xschem, virtuoso, spice
- `ConvertResult` / `ConvertResultList` — shared result types

## Internal Structure

| Path | Purpose |
|------|---------|
| `lib.zig` | EasyImport facade, BackendUnion, comptime interface check |
| `types.zig` | ConvertResult, ConvertResultList |
| `XSchem/mod.zig` | XSchem Backend, re-exports, symbol resolution |
| `XSchem/reader.zig` | .sch/.sym line parser (L/B/P/A/T/N/C tags) |
| `XSchem/converter.zig` | XSchem ↔ Schemify bidirectional conversion |
| `XSchem/props.zig` | Property tokenizer with XSchem escaping |
| `XSchem/pdk_remap.zig` | PDK symbol → generic primitive remapping |
| `XSchem/xschemrc.zig` | xschemrc file evaluation via TCL |
| `XSchem/types.zig` | XSchemFiles DOD container, XSchem-specific types |
| `XSchem/fileio/` | Serialization (read/write .sch/.sym format) |
| `Virtuoso/mod.zig` | Virtuoso Backend, cell maps, pin translation, cds.lib parser |
| `Virtuoso/oa.zig` | CDL + Spectre netlist parsers |
| `Virtuoso/skill.zig` | SKILL expression parser |
| `spice2schematic/mod.zig` | SPICE Backend, conversion pipeline |
| `spice2schematic/parser.zig` | SPICE netlist parser |
| `spice2schematic/layout.zig` | Schematic placement |
| `spice2schematic/router.zig` | Wire routing + power symbol insertion |
| `spice2schematic/pdk_map.zig` | SPICE model → DeviceKind mapping |
| `TCL/mod.zig` | Tcl facade struct |
| `TCL/evaluator.zig` | Tcl interpreter (commands, var substitution, control flow) |
| `TCL/commands.zig` | Built-in Tcl command implementations |
| `TCL/tokenizer.zig` | Tcl source tokenizer |
| `TCL/expr.zig` | Tcl expr evaluator (arithmetic, comparison, string ops) |

## Dependencies

- `schematic` — domain types (Schemify, DeviceKind, Instance, Wire, Pin, Property, Conn)
