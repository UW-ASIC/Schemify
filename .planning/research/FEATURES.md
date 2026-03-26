# Feature Landscape: XSchem-to-Schemify Converter

**Domain:** EDA schematic format conversion (XSchem .sch/.sym to Schemify .chn)
**Researched:** 2026-03-26
**Confidence:** HIGH (existing codebase + official XSchem docs + real-world xschemrc samples)

---

## XSchem Format Elements Requiring Handling

This section catalogs every element type, property, and construct in the XSchem ecosystem that the converter must process. This is the ground-truth coverage matrix.

### File-Level Structures

| Element | Tag | Present In | Description | Handling Complexity |
|---------|-----|------------|-------------|---------------------|
| Version header | `v` | .sch, .sym | `v {xschem version=X.X.X file_version=1.2}` | Low -- parse and validate |
| Global VHDL property | `G` | .sym | Symbol-level VHDL netlist rules | Low -- store as sym_prop |
| Global K property | `K` | .sym | Symbol netlisting: `type=`, `format=`, `template=`, `vhdl_format=`, `verilog_format=` | HIGH -- drives netlist behavior |
| SPICE global property | `S` | .sch | Schematic-level SPICE directives | Med -- map to code block |
| Verilog global property | `V` | .sch | Schematic-level Verilog body | Med -- store as verilog_body |
| tEDAx global property | `E` | .sch | Schematic-level tEDAx | Low -- skip for v1 |
| Spectre global property | `F` | .sch (v1.3+) | Spectre netlist format | Low -- skip for v1 |

### Graphical Primitives

| Element | Tag | Fields | Notes |
|---------|-----|--------|-------|
| Line | `L` | `layer x1 y1 x2 y2 {attrs}` | Non-electrical, cosmetic drawing |
| Rectangle | `B` | `layer x1 y1 x2 y2 {attrs}` | Non-electrical; PIN layer (layer 5) creates pins; supports `fill`, `dash`, `image_data` (base64 embedded images) |
| Polygon | `P` | `layer npoints x1 y1 ... xn yn {attrs}` | Open or closed path, `fill`, `bezier` attributes |
| Arc | `A` | `layer cx cy radius start_angle sweep_angle {attrs}` | CCW angles in degrees |
| Text | `T` | `{text} x y rotation mirror hsize vsize {attrs}` | Supports `font`, `layer`, `hcenter`, `vcenter`, `weight`, `slant`, `hide` |

### Electrical Elements

| Element | Tag | Fields | Notes |
|---------|-----|--------|-------|
| Wire | `N` | `x1 y1 x2 y2 {lab=netname}` | Electrical connectivity; `lab=` is display annotation (NOT authoritative net name) |
| Component instance | `C` | `{symbol_ref} x y rotation flip {key=val ...}` | Core element; rotation 0-3, flip 0-1; props are freeform key=value in braces |

### Symbol-Specific Constructs

| Construct | Where | Description |
|-----------|-------|-------------|
| Pin boxes | B on layer 5 | Rectangles on PIN layer define electrical pins |
| Pin direction | `dir=` attr on pin box | `input`, `output`, `inout` |
| Pin propagation | `propag=` attr | `0` = do not propagate net name through this pin |
| Pin numbering | `pinnumber=` attr | Physical pin mapping for PCB export (not needed for SPICE) |
| Embedded symbol | `[` ... `]` after C line | Complete inline .sym definition following instance |

### Instance Property System

These are the key=value properties that appear in C-line attribute strings and K-block globals:

| Property | Scope | Purpose | Converter Impact |
|----------|-------|---------|------------------|
| `name` | Instance | Instance designator (e.g., M1, R2) | CRITICAL -- maps to Schemify instance name |
| `type` | Symbol K-block | Device classification: `subcircuit`, `nmos`, `pmos`, `resistor`, `capacitor`, etc. | CRITICAL -- drives DeviceKind mapping |
| `format` | Symbol K-block / Instance | SPICE netlist template: `@name @pinlist @symname W=@W L=@L` | CRITICAL -- defines netlist output format |
| `template` | Symbol K-block | Default parameter values: `name=X1 W=1u L=0.18u m=1` | HIGH -- provides parameter defaults for new instances |
| `lvs_format` | Symbol K-block | LVS-specific netlist format override | Med -- store, use when present |
| `spice_ignore` | Instance | `1` or `true` = skip in SPICE netlist | HIGH -- must filter code blocks |
| `verilog_ignore` | Instance | `1` or `true` = skip in Verilog netlist | Low -- store but not used in SPICE path |
| `tedax_ignore` | Instance | Skip in tEDAx | Low -- skip for v1 |
| `value` | Instance | Component value (resistance, SPICE code block) | HIGH -- core parameter |
| `model` | Instance | SPICE model reference | HIGH -- needed for netlisting |
| `W`, `L`, `m` | Instance | MOSFET/passive sizing parameters | HIGH -- core parameters |
| `highlight` | Instance | GUI selection highlight | LOW -- cosmetic meta-prop, filter out |
| `color` | Instance | GUI color override | LOW -- cosmetic meta-prop, filter out |
| `simulator` | Instance | Which simulator uses this code block | Med -- pass through for code blocks |
| `only_toplevel` | Instance | Code block placement directive | Med -- pass through |
| `place` | Instance | Code block placement: `header`, `end` | Med -- pass through |
| `schematic` | Instance | Path to alternate schematic for symbol | LOW -- rare, skip for v1 |
| `embed` | Instance | Inline symbol definition follows `[...]` | Med -- must handle embedded symbols |
| `lab` | Wire/Instance | Net name label | CRITICAL -- drives net naming |
| `bus` | Wire | `1` = render as bus (thicker wire) | Low -- pass through |

### xschemrc Tcl Constructs

Real-world xschemrc files use these Tcl patterns that must be evaluated:

| Construct | Example | Frequency | Complexity |
|-----------|---------|-----------|------------|
| `set VAR value` | `set PDK sky130A` | Every file | Low |
| `set VAR {braced}` | `set XSCHEM_LIBRARY_PATH {}` | Common | Low |
| `$VAR` / `${VAR}` | `${PDK_ROOT}/${PDK}` | Every file | Low |
| `$env(NAME)` | `$env(HOME)`, `$env(PDK_ROOT)` | Common | Med |
| `[info exists env(X)]` | Conditional PDK detection | Common | Med |
| `[file dirname [info script]]` | Script location detection | Every file | Low (hardcoded pattern) |
| `[file normalize ...]` | Path canonicalization | Common | Med |
| `[file isdir ...]` | Directory existence check | Common | Med |
| `append VAR :path` | Library path building | Every file | Low |
| `lappend VAR item` | List building (tcl_files) | Common | Low |
| `if {cond} {body} else {body}` | Conditional config | Common | HIGH |
| `proc name args body` | Custom procedures | PDK xschemrc | HIGH |
| `switch -regexp` | Model-specific DRC | PDK xschemrc | HIGH (v2+) |
| `array unset`/`set arr(k) v` | Color mapping arrays | PDK xschemrc | Med |
| `source filepath` | Include other xschemrc | Every PDK project | HIGH |
| `$topwin.menubar insert` | Dynamic menu creation | PDK xschemrc | SKIP -- GUI only |
| `for`/`foreach` loops | Instance iteration | PDK procs | HIGH (v2+) |

### Device Kind Taxonomy

The converter must classify XSchem instances into Schemify DeviceKinds. The existing `map.zig` handles 80+ symbol names. Complete categorization:

**Electrical devices (emit SPICE):**
- Passives: `res.sym`, `res3.sym`, `var_res.sym`, `capa.sym`, `capa-2.sym`, `ind.sym`
- Diodes: `diode.sym`, `zener.sym`
- MOSFETs: `nmos3.sym`, `nmos.sym`, `pmos3.sym`, `pmos.sym`, `nmos4.sym`, `pmos4.sym`, `nmos4_depl.sym`, `nmos-sub.sym`, `pmos-sub.sym`, `nmoshv4.sym`, `pmoshv4.sym`, `rnmos4.sym`
- BJTs: `npn.sym`, `pnp.sym`
- JFETs: `njfet.sym`, `pjfet.sym`
- MESFET: `mesfet.sym`
- Sources: `vsource.sym`, `vsource_arith.sym`, `vsource_pwl.sym`, `isource.sym`, `isource_arith.sym`, `isource_pwl.sym`, `sqwsource.sym`, `ammeter.sym`
- Behavioral: `bsource.sym`, `asrc.sym`, `behavioral.sym`
- Controlled: `vcvs.sym`, `vccs.sym`, `ccvs.sym`, `cccs.sym`
- Logic gates (as behavioral): `buf.sym`, `inv.sym`, `and.sym`, `or.sym`, `nor.sym`, `nand.sym`, `xor.sym`, `xnor.sym`
- Switches: `switch.sym`, `vswitch.sym`, `sw.sym`, `switch_ngspice.sym`, `switch_v_xyce.sym`, `iswitch.sym`, `csw.sym`
- Coupling/transmission: `k.sym`, `tline.sym`, `tline_lossy.sym`
- Subcircuits: any user-defined `.sym`/`.sch`

**Non-electrical (no SPICE, but affect schematic):**
- Net labels: `lab_pin.sym`, `lab_wire.sym`, `ipin.sym`, `opin.sym`, `iopin.sym`
- Power: `gnd.sym`, `vdd.sym`
- Control: `code.sym`, `code_shown.sym`, `simulator_commands.sym`, `simulator_commands_shown.sym`, `param.sym`, `param_agauss.sym`
- Probes: `spice_probe.sym`, `spice_probe_vdiff.sym`
- HDL: `arch_declarations.sym`, `architecture.sym`, `assign.sym`, `connect.sym`, `bus_connect.sym`, `use.sym`, `package.sym`, `verilog_delay.sym`, `verilog_timescale.sym`, `attributes.sym`, `port_attributes.sym`
- Cosmetic: `title.sym`, `title-2.sym`, `noconn.sym`, `launcher.sym`, `ngspice_probe.sym`, `ngspice_get_expr.sym`, `ngspice_get_value.sym`, `lab_show.sym`, `scope_ammeter.sym`, `rgb_led.sym`, `generic.sym`, `graph.sym`

**PDK-specific (prefix-inferred):**
- `nfet*`, `pfet*` -> MOSFET
- `res_*` -> resistor
- `cap_*` -> capacitor
- `ind_*` -> inductor
- `diode_*` -> diode
- `npn_*`, `pnp_*` -> BJT
- `.tcl(...)` -> TCL generator symbol (runtime-generated)

---

## Table Stakes

Features users expect. Missing any of these = conversion produces broken or unusable output.

| # | Feature | Why Expected | Complexity | Existing Code |
|---|---------|--------------|------------|---------------|
| T1 | .sch/.sym text parser | Cannot convert what you cannot parse | Med | XSchem.zig (solid, DOD SoA) |
| T2 | xschemrc parser with Tcl subset evaluation | Real projects use `$env()`, `[file dirname]`, `if/else`, `set/append` -- without this, library paths cannot be resolved | HIGH | XSchemRC.zig + TCL.zig (exists but needs robustness for `proc`, `source`, `switch`) |
| T3 | Library path resolution | XSchem resolves symbols via XSCHEM_LIBRARY_PATH search order; without this, instance symbols are unresolvable | HIGH | Partial in impl.zig (search_dirs), needs rewrite |
| T4 | Instance-to-DeviceKind classification | Determines whether an instance is a MOSFET, resistor, subcircuit, net label, code block, etc. Wrong classification = wrong netlist | HIGH | map.zig (comprehensive, 80+ symbols) |
| T5 | Wire translation (f64 to i32 coords) | XSchem uses f64 coordinates; Schemify uses i32. Rounding errors break connectivity | Med | f2i() exists in XSchem.zig |
| T6 | Instance translation with properties | Map XSchem instances to Schemify components, including name, position, rotation, flip, and filtered properties | HIGH | xschemToSchemify() in impl.zig (exists, needs cleanup) |
| T7 | Net label handling (lab_pin, ipin, opin, iopin, vdd, gnd) | These special instances define net names and pin directions. Missing = all nets unnamed, pins absent | CRITICAL | Handled in xschemToSchemify() switch |
| T8 | Code block handling (code.sym, param.sym) | SPICE simulation directives (.dc, .tran, .control blocks); `spice_ignore` filtering | Med | Exists in impl.zig |
| T9 | Symbol data loading (pin positions, format, template) | Netlisting requires knowing pin order/positions from .sym files to connect instances to nets correctly | HIGH | loadSymbolData/loadOneSymData in impl.zig (exists, complex) |
| T10 | Companion .sym geometry merge | For .sch+.sym pairs, the .sym provides the visual symbol (lines, rects, arcs, pins) that must appear in the .chn output | Med | mergeSymbolData in impl.zig |
| T11 | File classification (.sch+.sym -> .chn, .sch alone -> .chn_tb, .sym alone -> .chn_prim) | Determines output file type; wrong classification = Schemify opens file in wrong mode | Med | Documented in spec, straightforward logic |
| T12 | Dependency tree / conversion ordering | Must convert leaf symbols before parents that reference them; otherwise parent instances reference nonexistent .chn files | HIGH | walkSchematic (BFS) in impl.zig, needs proper ordering |
| T13 | .chn serialization | Write valid Schemify format output that Reader.zig can parse back | Med | Schemify.writeFile() exists in core |
| T14 | Config.toml generation | Converted project needs its own Config.toml with library paths to .chn files | Med | generateConfigToml in impl.zig |
| T15 | PDK library conversion | Convert all PDK .sym files to .chn_prim, maintaining directory structure (e.g., sky130_fd_pr/) | HIGH | convertPdkLibrary/convertOnePdk in impl.zig |
| T16 | Property filtering (meta-props) | XSchem meta-properties (template, type, highlight, color, spice_ignore, etc.) must not leak into .chn component props | Med | isXschemMetaProp() exists |
| T17 | Brace unescaping | XSchem escapes `{` and `}` with backslash in property strings; must unescape for Schemify | Low | unescapeBraces() exists |
| T18 | Backslash removal from symbol paths | XSchem uses `\\` in paths; must strip for filesystem access | Low | clean_sym_buf logic exists |
| T19 | Graphical element translation (lines, rects, arcs, circles, text) | Visual fidelity of the schematic; without these, converted files have invisible symbols | Med | All handled in xschemToSchemify() |

---

## Differentiators

Features that set this converter apart from manual conversion or competing approaches. Not expected, but create significant value.

| # | Feature | Value Proposition | Complexity | Notes |
|---|---------|-------------------|------------|-------|
| D1 | Netlist roundtrip validation | Automatically verify XSchem SPICE netlist matches Schemify SPICE netlist from converted files -- the ultimate correctness proof | HIGH | Requires invoking both XSchem and Schemify netlisters, diffing output. Flagship testing feature per spec. |
| D2 | TCL generator symbol support | Execute `.tcl(...)` scripts that generate .sym definitions at runtime, extract pins/format/type | HIGH | executeTclGenerator() exists in impl.zig; requires tclsh on PATH |
| D3 | Embedded symbol handling | Parse inline `[...]` symbol definitions that follow C lines with `embed=true` | Med | Not yet implemented; rare but real in some designs |
| D4 | Bus wire expansion | Properly handle bus notation (multi-bit wires with `[N:M]` naming) | Med | `bus` flag exists in wire parsing; expansion into individual nets needed for some designs |
| D5 | Structural validation report | Post-conversion report showing: N instances converted, M wires, K pins, any warnings (unresolved symbols, unknown device kinds) | Low | Valuable for user trust; ConvertResult partially supports this |
| D6 | ABI v6 plugin GUI | Interactive panel in Schemify with project path input, progress display, conversion log | Med | Plugin entry point scaffolded in impl.zig |
| D7 | CLI batch mode | `zig build run -- --convert-xschem <path>` for CI/automation | Low | Easy to add alongside plugin |
| D8 | Incremental PDK conversion | Only re-convert PDK symbols that have changed since last conversion (mtime check) | Low | Performance optimization; PDK conversion can take minutes for large PDKs |
| D9 | Global net declaration (.GLOBAL) | Properly emit .GLOBAL for VDD/VSS power nets (XSchem skips `0` from .GLOBAL) | Low | Partially handled (addGlobal with "0" filter) |
| D10 | Multi-backend xschemrc eval | Evaluate xschemrc with correct `sim_is_ngspice` / `sim_is_xyce` conditional paths | Med | TCL evaluator already supports Backend enum |
| D11 | Polygon handling | Translate P-elements (polygons) to closest Schemify equivalent or series of line segments | Med | XSchem.zig parses polygons but xschemToSchemify() does not yet translate them |

---

## Anti-Features

Features to explicitly NOT build for v1. Each has a clear rationale.

| # | Anti-Feature | Why Avoid | What to Do Instead |
|---|--------------|-----------|-------------------|
| A1 | Cadence Virtuoso backend | Different file format (SKILL/OA), different complexity level. Dilutes focus on getting XSchem right | Stub only; defer to separate milestone |
| A2 | Reverse conversion (Schemify -> XSchem) | Different tool entirely; no user demand yet; complicates design with bidirectional concerns | Build as separate plugin if needed |
| A3 | Incremental re-conversion (watch mode) | Over-engineering for v1; users convert once, iterate in Schemify | Manual re-trigger via CLI or plugin button |
| A4 | GUI preview of conversion diff | Requires building a diff viewer UI; not worth complexity for v1 | Text-based conversion log is sufficient |
| A5 | Full Tcl interpreter (proc, for, foreach, switch) | Real xschemrc files DO use `proc` and `for` in PDK setup, but these are in sourced PDK xschemrc files that define menu/DRC helpers -- not in path resolution. The `source` command to include PDK xschemrc IS needed, but executing arbitrary procs for non-path-related logic is not | Support `set`, `append`, `lappend`, `if/else`, `[file dirname]`, `$env()`, `source` for path resolution. Log warnings for unhandled constructs. |
| A6 | tEDAx / Spectre netlist output | Schemify targets SPICE (ngspice/Xyce). tEDAx and Spectre are niche | Skip E and F global properties; store but do not process |
| A7 | VHDL / Verilog behavioral simulation | Focus is on SPICE analog simulation. Digital/mixed-signal is a separate domain | Store HDL properties but do not validate or process HDL code blocks beyond pass-through |
| A8 | Symbol graphical editing during conversion | Converting visual fidelity is table stakes, but allowing users to tweak symbol graphics during import adds complexity | Convert as-is; users edit in Schemify post-conversion |
| A9 | Base64 embedded image round-trip | XSchem supports embedded raster images in B-elements. Complex binary data handling | Store image_data as opaque blob if present; do not decode/re-encode |
| A10 | PCB export / pinnumber mapping | XSchem's `pinnumber=` attribute maps to physical PCB pins. Schemify is a schematic editor focused on SPICE, not PCB | Ignore pinnumber attribute |
| A11 | Hierarchical flattening | Flatten multi-level hierarchy into single schematic | Out of scope -- Schemify handles hierarchy natively via subcircuit references |

---

## Feature Dependencies

```
T1 (parser) -----> T5 (wire translation)
                |-> T6 (instance translation) ---> T7 (net labels)
                |                              |-> T8 (code blocks)
                |                              |-> T16 (prop filtering)
                |                              |-> T17 (brace unescaping)
                |                              |-> T18 (backslash removal)
                |-> T19 (graphical elements)

T2 (xschemrc) ---> T3 (library path resolution)
                |-> T15 (PDK library conversion)

T3 (lib paths) --> T9 (symbol data loading) --> T10 (sym geometry merge)
                                            |-> T4 (DeviceKind classification)

T4 (DeviceKind) --> T6 (instance translation)

T9 (sym data) ---> T12 (dependency tree) --> T15 (PDK conversion)
                                         |-> T13 (.chn serialization)
                                         |-> T11 (file classification)

T13 (.chn write) -> T14 (Config.toml generation)

D1 (netlist roundtrip) depends on ALL table stakes being correct.
D2 (TCL generators) depends on T2 (Tcl eval) + T9 (sym loading).
D6 (plugin GUI) depends on T13 (.chn write) + T14 (Config.toml).
D7 (CLI) depends on T13 (.chn write) + T14 (Config.toml).
```

---

## MVP Recommendation

### Must ship (Phase 1 core):

1. **T1** -- .sch/.sym parser (exists, needs DOD cleanup)
2. **T2** -- xschemrc parser with Tcl subset (exists, needs `source` command support)
3. **T3** -- Library path resolution
4. **T4** -- DeviceKind classification (exists, solid)
5. **T5** -- Wire translation with f64->i32 (exists)
6. **T6** -- Instance translation with property mapping (exists, needs cleanup)
7. **T7** -- Net label handling (exists)
8. **T8** -- Code block handling (exists)
9. **T16, T17, T18** -- Property filtering/cleaning (exists)
10. **T19** -- Graphical element translation (exists)

### Must ship (Phase 2 integration):

11. **T9** -- Symbol data loading from resolved paths
12. **T10** -- Companion .sym geometry merge
13. **T11** -- File classification
14. **T12** -- Dependency tree ordering
15. **T13** -- .chn serialization (core provides this)
16. **T14** -- Config.toml generation
17. **T15** -- PDK library conversion

### Must ship (Phase 3 validation):

18. **D1** -- Netlist roundtrip testing (THE validation strategy)
19. **D5** -- Structural validation report

### Defer to v1.1:

- **D2** -- TCL generator symbols (rare, needs tclsh)
- **D3** -- Embedded symbol handling (rare)
- **D4** -- Bus wire expansion
- **D6** -- ABI v6 plugin GUI
- **D7** -- CLI batch mode
- **D8** -- Incremental PDK conversion

**Rationale:** The conversion pipeline must produce correct output before UI/UX polish. Netlist roundtrip testing is the acceptance criterion that gates everything. The existing code in `.cache/src_old/` provides substantial implementation for 80%+ of table stakes, but it needs a ground-up rewrite following DOD principles (the old impl.zig is over-abstracted with Runtime unions and Backend traits).

---

## Sources

- [XSchem Developer Info / File Format](https://xschem.sourceforge.io/stefan/xschem_man/developer_info.html) -- Official file format specification
- [XSchem Properties](https://xschem.sourceforge.io/stefan/xschem_man/xschem_properties.html) -- Property key documentation
- [XSchem Elements](https://xschem.sourceforge.io/stefan/xschem_man/xschem_elements.html) -- Element type catalog
- [xschem_sky130 xschemrc](https://github.com/StefanSchippers/xschem_sky130/blob/main/xschemrc) -- Real-world xschemrc example with complex Tcl
- [XSchem Sky130 Integration Tutorial](https://xschem.sourceforge.io/stefan/xschem_man/tutorial_xschem_sky130.html) -- PDK integration patterns
- [EasyEDA Export Guide](https://www.schemalyzer.com/en/blog/easyeda/export-import/export-easyeda-schematics) -- EDA converter best practices
- [InnoFour Netlist Converter](https://www.innofour.com/solutions/electronic-system-design-products/netlist-converter/) -- Commercial converter feature reference
- Existing codebase: `plugins/EasyImport/.cache/src_old/XSchem/XSchem.zig`, `impl.zig`, `map.zig`, `XSchemRC.zig`, `TCL.zig`
- Existing codebase: `src/core/Schemify.zig`, `Types.zig`, `Devices.zig`, `Reader.zig`, `Writer.zig`
