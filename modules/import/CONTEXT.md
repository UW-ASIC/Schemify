# import

Import schematics from external EDA tools into Schemify's native format.

## Functionality

Three backends behind a unified facade:

- **XSchem**: parses `.sch`/`.sym` files, resolves symbols via xschemrc library paths, maps XSchem device types to `DeviceKind`, remaps PDK-specific symbols (Sky130, GF180MCU, IHP SG13G2) to generic primitives, bidirectional XSchem<->Schemify conversion, round-trip serialization.
- **Virtuoso**: parses CDL and Spectre netlists, resolves cells via `cds.lib`, maps 125+ analogLib/GPDK/TSMC cells to `DeviceKind`, translates Cadence pin names (context-aware: `B`=body for MOSFET, `B`=base for BJT), strips global-net `!` suffix.
- **SPICE**: parses standard SPICE netlists (`.spice`/`.sp`/`.cir`/`.net`/`.cdl`), generates schematic layout via BFS topological placement, routes wires with Manhattan geometry, inserts power symbols.
- **TCL evaluator**: subset Tcl interpreter for xschemrc files. Supports 22 commands (set, if, for, foreach, while, switch, proc, catch, return, break, regexp, source, expr, file, info, string, array, namespace, incr, append, lappend, unset, puts). Not a general-purpose Tcl; handles path resolution and variable seeding for XSchem library path discovery.

## Public API

| Symbol | Signature | Purpose |
|--------|-----------|---------|
| `EasyImport` | `init(alloc, path, backend_kind) -> EasyImport` | Facade. Detects project root, initializes chosen backend. |
| `EasyImport.convertProject` | `() -> ConvertResultList` | Convert all discovered schematics to Schemify format. |
| `EasyImport.getFiles` | `() -> XSchem.FileList` | List discovered files. XSchem backend only; others return `error.BackendNotImplemented`. |
| `EasyImport.label` | `() -> []const u8` | Human-readable backend name. |
| `BackendKind` | `enum { xschem, virtuoso, spice }` | Backend selector. |
| `BackendUnion` | `union(BackendKind)` | Tagged union wrapping backend instances. Comptime-checked for interface conformance. |
| `ConvertResult` | `struct { name, sch_path, sym_path, schemify }` | Single converted schematic. `schemify` is `core.Schemify`. |
| `ConvertResultList` | `struct { results, arena }` | Owned list of results with arena for cleanup. |
| `Tcl` | `init(alloc) -> Tcl` | Tcl evaluator facade. |
| `Tcl.eval` | `(script) -> []const u8` | Evaluate Tcl script, return result string. |
| `Tcl.getVar` / `setVar` | get/set variable by name | Read/write Tcl variable table. |
| `Tcl.setScriptPath` | `(path) -> void` | Set `[info script]` path for `[file dirname]` resolution. |
| `parseRc` | `(alloc, bytes, dir, path) -> RcResult` | Parse xschemrc file. Returns resolved library paths, PDK root, share dir. |
| `XSchem.convert` | `(files, resolver, alloc) -> Schemify` | XSchem -> Schemify conversion. |
| `XSchem.mapSchemifyToXSchem` | `(schemify, alloc) -> XSchemFiles` | Schemify -> XSchem reverse conversion. |
| `remapPdk` | `(files, alloc) -> void` | Replace PDK-specific instances with generic primitives in-place. |
| `spice2schematic.importSpice` | `(alloc, netlist_bytes) -> ConvertResultList` | One-call SPICE import convenience API. |

## Internal Structure

| Path | Purpose |
|------|---------|
| `lib.zig` | EasyImport facade, BackendUnion, comptime interface check (init/deinit/label/detectProjectRoot/convertProject/getFiles) |
| `types.zig` | ConvertResult, ConvertResultList |
| **XSchem/** | |
| `XSchem/mod.zig` | Backend struct, SymPathResolver (resolves symbols via xschemrc lib_paths), directory walking, symbol resolution |
| `XSchem/reader.zig` | `.sch`/`.sym` tag-dispatch parser (V/E/S/G/K/L/B/P/A/T/N/C tags), multi-line brace-depth tracking |
| `XSchem/converter.zig` | Bidirectional conversion (~1010 LOC). `mapXSchemStem()` (82 entries), `mapXSchemKType()` (37 entries), `matchFetPrefix()`, bus pin collapsing, label wire injection, Tcl format evaluation |
| `XSchem/props.zig` | PropertyTokenizer for XSchem `key=value` parsing with brace/quote/backslash escaping |
| `XSchem/types.zig` | DOD types (Line/Rect/Arc/Circle/Wire/Text/Pin/Instance/Prop), XSchemFiles MultiArrayList container, FileType enum, ParseError, PinDirection |
| `XSchem/pdk_remap.zig` | PDK prefix matching + standard cell gate mapping (Sky130/GF180MCU/IHP SG13G2). 14 tests. |
| `XSchem/xschemrc.zig` | `parseRc()`: evaluates xschemrc via TCL, seeds XSCHEM_SHAREDIR/USER_CONF_DIR/PDK_ROOT, probes standard paths and PATH-based binary discovery |
| `XSchem/fileio/mod.zig` | Re-exports parse + writeFile + serialize |
| `XSchem/fileio/reader.zig` | **Duplicate of `XSchem/reader.zig`** (imports props from `utils.zig` instead of `props.zig`) |
| `XSchem/fileio/writer.zig` | XSchem file serializer: K block, S block, geometry, pins (as B 5 rects), instances (C lines), property escaping |
| `XSchem/fileio/utils.zig` | **Duplicate of `XSchem/props.zig`** |
| **Virtuoso/** | |
| `Virtuoso/mod.zig` | Backend struct (~930 LOC). `cadence_cell_map` (125 entries), `matchPdkPrefix()`, context-aware pin translation (`PinContext` enum), cds.lib DEFINE parser, property key translation, global net `!` stripping. ~40 tests. |
| `Virtuoso/oa.zig` | CDL parser (`.SUBCKT`/`.ENDS`, `+` continuation, `$SUB=`/`$PINS` directives, prefix-based instance parsing). Spectre parser (parenthesized terminals, parameter parsing). Fixed-size scratch: 128 ports, 256 instances, 512 nets/pins, 256 params. |
| `Virtuoso/skill.zig` | SKILL helpers: template strings for CDL export/instance enumeration/net export, `generateExportScript()`, placeholder property list parser. Not a real evaluator. |
| **spice2schematic/** | |
| `spice2schematic/mod.zig` | Backend struct (~650 LOC). `convertNetlist()`, `buildComponent()`/`buildTestbench()`, `appendElementProps()`/`appendElementConns()`, `pinNamesForKind()`. |
| `spice2schematic/parser.zig` | SPICE netlist parser (~600 LOC). Logical line joining (`+` continuation), `.SUBCKT`/`.ENDS`/`.MODEL`/`.PARAM`/`.GLOBAL`/`.TITLE`/`.END` directives, R/C/L/D/M/Q/J/V/I/E/G/F/H/B/X element parsing. |
| `spice2schematic/layout.zig` | Topological placer. BFS layer assignment from V/I sources. Grid: H_STEP=200, V_STEP=120, SNAP=10. Overlap nudging. Power/ground net classification. |
| `spice2schematic/router.zig` | Manhattan wire router. Net-to-pin mapping, L-shaped wire segments, GND/VDD symbol insertion. Pin offset tables per DeviceKind. |
| `spice2schematic/pdk_map.zig` | PDK model->DeviceKind mapping (18 prefix entries for Sky130/GF180MCU/IHP SG13G2). Polarity inference via substring heuristics. |
| **TCL/** | |
| `TCL/mod.zig` | Tcl facade wrapping Evaluator. Re-exports Evaluator, Tokenizer, Token, ExprResult, evalExpr. |
| `TCL/evaluator.zig` | Full interpreter (~860 LOC). 22 commands via StaticStringMap dispatch. Proc definitions, catch/error, glob matching, simple regex, variable substitution (scalar + `$env()` + `$arr(key)`). Loop cap: 10,000 iterations. |
| `TCL/commands.zig` | Built-in implementations: `file` (dirname/normalize/join/isdir/isfile/tail/extension), `info` (exists/script), `string` (equal/tolower/length/is). `readSourceFile` with 10MB limit. `SegmentScanner` for brace/bracket matching. |
| `TCL/tokenizer.zig` | Source tokenizer (eof/newline/semicolon/whitespace/word/quoted_string/braced_string/variable/bracket_cmd/comment). Backslash-newline continuation, nested brackets/braces. 7 tests. |
| `TCL/expr.zig` | Recursive-descent expression parser. Operators: `\|\|`, `&&`, `==`, `!=`, `eq`, `ne`, `<`, `>`, `<=`, `>=`, `+`, `-`, `*`, `/`, `%`, `!`, ternary `?:`. Functions: int/abs/round/ceil/floor/double/wide/sqrt/exp. Contains `cmpBool` noinline workaround for Zig 0.15 miscompilation. |

## Dependencies

- `schematic` -- domain types: Schemify, DeviceKind, Instance, Wire, Pin, Property, Conn

## Reference Docs

- `XSCHEM.md` -- comprehensive XSchem symbol mapping reference (116 built-in symbols, PDK-specific patterns for Sky130/GF180MCU/IHP SG13G2, pin conventions, recommended `mapXSchemStem()` additions)
- `CADENCE.md` -- Cadence Virtuoso component mapping reference (analogLib inventory, CDL/Spectre format notes, PDK patterns for TSMC/GF180MCU/GPDK, pin translation tables)

## Gaps

### Missing Features

- **Polygon parsing**: XSchem `P` tag is deferred ("Phase 4") in both reader.zig files. Polygons are silently skipped.
- **Transmission line**: `tline` DeviceKind exists but XSchem `delay_line` (type=transmission_line) is not mapped in ktype or stem maps.
- **XSPICE digital primitives**: `adc_bridge`, `dac_bridge`, digital gates -- no Schemify DeviceKind for these.
- **XSchem scope/probe symbols**: `scope`, `scope2`, `scope_ammeter`, `param_agauss`, `res_noisy`, `rgb_led`, `lab_generic` are not mapped in `mapXSchemStem()`. See XSCHEM.md "Recommended Additions" section for the full list.
- **Virtuoso OA database reading**: only CDL/Spectre text netlists are supported. No native OpenAccess binary parsing.
- **Spectre simulator commands**: `.tran`, `.dc`, `.ac` etc. in Spectre format are not parsed or preserved.
- **SPICE `.INCLUDE`/`.LIB`**: the parser recognizes these directives but does not follow them to read included files.
- **Hierarchical import**: SPICE backend handles subcircuits but does not recursively build a hierarchy tree across files.
- **Error recovery**: all three parsers abort on first error rather than collecting multiple diagnostics.
- **TCL unsupported constructs**: `global`, `package`, `eval`, `uplevel`, `upvar` are not implemented. Real xschemrc files that use these for path resolution will produce incomplete results.
- **SKILL evaluator**: `Virtuoso/skill.zig` is template generation only, not a real SKILL parser. Cannot evaluate SKILL scripts from Virtuoso projects.

### API Issues

- **Duplicate code**: `XSchem/fileio/reader.zig` duplicates `XSchem/reader.zig`, and `XSchem/fileio/utils.zig` duplicates `XSchem/props.zig`. One copy should be deleted; the other should import from the canonical location.
- **`getFiles()` leaks backend type**: returns `XSchem.FileList` (an XSchem-specific type) through the facade. Virtuoso and SPICE backends return `error.BackendNotImplemented`. Should either return a backend-agnostic file list type or be removed from the facade interface.
- **`toLowerBuf()` duplicated**: appears in `spice2schematic/layout.zig`, `spice2schematic/pdk_map.zig`, and `TCL/evaluator.zig`. Should be in a shared utility.
- **XSchem coordinates are f64**: XSchem native format uses floating-point coordinates. These are truncated to `i32` at the Schemify boundary via `@intFromFloat`. No rounding or precision-loss handling.
- **CDL/Spectre fixed scratch buffers**: `oa.zig` uses comptime-sized scratch arrays (128 ports, 256 instances, 512 nets). Exceeding these limits causes silent truncation or panic, not a recoverable error. Real foundry netlists can exceed 256 instances per subcircuit.
- **Tcl loop cap hardcoded**: evaluator.zig caps all loops at 10,000 iterations with no way to configure this. Not a problem for xschemrc files, but the limit is undocumented in the API.
- **Zig 0.15 workaround**: `expr.zig` has a `cmpBool` function marked `noinline` to work around a Zig 0.15 miscompilation. Should be revisited when upgrading Zig versions.
- **No error types for SPICE parse failures**: `parser.zig` uses generic `error.InvalidFormat` for all parse errors. No structured error with line number or context.
