# Technology Stack: XSchem-to-Schemify Converter

**Project:** EasyImport (XSchem backend)
**Researched:** 2026-03-26
**Dimension:** Parsing strategies, data representation, testing approaches for `.sch`/`.sym` to `.chn` format conversion

---

## Recommended Stack

### Core Framework

| Technology | Version | Purpose | Why |
|---|---|---|---|
| Zig | 0.15 | Parser, translator, plugin entry point | Must match host Schemify build. Already proven in existing XSchem.zig parser. No alternative. |
| Zig `std.heap.ArenaAllocator` | 0.15 | Per-file allocation lifetime | Both XSchem and Schemify structs already use arenas. One arena per conversion = zero leak risk, single `deinit()` teardown. |
| Zig `std.MultiArrayList` | 0.15 | SOA storage for geometric elements | Already the canonical pattern in both `XSchem.zig` and `Schemify.zig`. Cache-friendly batch access for coordinate transforms. |

**Confidence: HIGH** -- These are not choices; they are constraints from the host project.

### Parser Strategy

| Strategy | Recommendation | Why |
|---|---|---|
| **Line-by-line scanner with tag dispatch** | USE THIS | XSchem format is inherently line-oriented. Each element starts with a single-character tag (`N`, `C`, `T`, `L`, `B`, `A`, `P`, `v`, `K`, `G`, `S`, `V`, `E`, `F`). The existing `XSchem.zig` parser already implements this pattern successfully. No grammar/tokenizer needed. |
| Recursive descent parser | DO NOT USE | XSchem format is NOT recursive (apart from `{}` brace-balanced property blocks). A full recursive descent parser adds complexity with zero benefit. |
| PEG/parser combinator | DO NOT USE | The format is too simple to justify a grammar framework. XSchem files are positional (space-separated fields after a tag char), not expression-structured. Parser combinators would be overkill and hurt performance. |
| Streaming SAX-style | DO NOT USE | Files are small enough to load entirely into memory (largest PDK schematic libraries are <1MB). Streaming adds state machine complexity for no memory benefit. |

**Confidence: HIGH** -- The existing parser proves this approach works. XSchem's own C codebase also uses line-by-line tag dispatch (`load_schematic()` in xschem).

### Property String Parser

| Technology | Purpose | Why |
|---|---|---|
| Custom `PropTokenizer` (already exists in XSchem.zig) | Parse `key=value key="quoted value"` within `{...}` blocks | XSchem property strings have a specific escaping convention: `\\` and `\"` within quoted values. The existing `PropTokenizer` handles multi-line quoted values and single-quoted values. Reuse it. |

**Confidence: HIGH** -- Proven in existing code, handles edge cases already.

### Tcl Evaluator

| Technology | Purpose | Why |
|---|---|---|
| Custom `TCL.zig` (already exists in EasyImport) | Evaluate xschemrc variable expressions | Real xschemrc files use `$env()`, `[file dirname [info script]]`, `set`, `append`, `lappend`, conditional logic. The existing `TCL.zig` implements a tokenizer + evaluator that handles this Tcl subset. No external Tcl library needed or wanted (WASM target constraint). |

**Confidence: MEDIUM** -- The existing TCL evaluator works for most cases, but complex real-world xschemrc files (e.g., Sky130 open_pdks) may use Tcl constructs not yet supported (`proc`, `foreach`, `glob`). Phase-specific research needed when hitting these.

### Data Representation

| Pattern | Recommendation | Rationale |
|---|---|---|
| **SOA (Struct-of-Arrays) via `MultiArrayList`** | USE for geometric elements (lines, rects, arcs, wires, instances) | Matches both XSchem.zig and Schemify.zig storage. Enables batch coordinate transforms (`f64` to `i32`) via direct slice access. Cache-friendly for iteration. |
| **AOS (Array-of-Structs) via `ArrayListUnmanaged`** | USE for variable-length elements (props, conns, nets) | Props and conns are indexed by `prop_start`/`prop_count` from instances. AOS is simpler for these because they are accessed per-instance, not in batch. Already the pattern in Schemify.zig. |
| **Arena-per-file** | USE | Each `.sch`/`.sym` parse gets its own arena (XSchem struct). Each conversion output gets its own arena (Schemify struct). When a file is fully converted and written, both arenas can be freed. No per-element free needed. |
| **Flat index arrays** over pointer-based trees | USE | Instance props use `prop_start: u32, prop_count: u16` indexing into a flat `props` array. This avoids pointer indirection and is trivially serializable. Already the pattern in both data models. |
| **`StringHashMap` for lookup tables** | USE for dependency graphs, symbol resolution cache, visited-set | Zig's `StringHashMap` with arena-owned key strings. Used for: (1) tracking which files have been converted, (2) symbol path resolution cache, (3) net name dedup. |

**Confidence: HIGH** -- All patterns already proven in existing codebase.

### Coordinate System

| Decision | Value | Rationale |
|---|---|---|
| XSchem coordinates | `f64` (double-precision floating point) | XSchem stores all coordinates as doubles. This is baked into the format. |
| Schemify coordinates | `i32` (32-bit integer, grid-snapped) | Schemify's core model uses integer coordinates. |
| Conversion function | `f2i(x: f64) -> i32` = `@intFromFloat(@round(x))` | Already exists in XSchem.zig. Rounds to nearest integer. XSchem's default snap grid is 10.0 units, so all well-formed schematics have integer-aligned coordinates anyway. |

**Confidence: HIGH** -- Already implemented and working.

### Dependency Tree / Walk Order

| Approach | Recommendation | Rationale |
|---|---|---|
| **BFS from root schematic** | USE THIS | Start from `XSCHEM_START_WINDOW` (or user-specified root). Parse each `.sch`, discover child instance symbols. Queue symbols not yet visited. Convert leaves first (primitives), then composites that depend on them. This is what `walkSchematic` in impl.zig already does recursively. |
| Topological sort on full dependency graph | DO NOT USE as primary | Building a full graph upfront requires parsing ALL files before converting ANY. BFS with "convert on first encounter" is simpler and handles cycles (mutual recursion is rare but possible in XSchem). |
| Lazy conversion (convert only when referenced) | USE as optimization | When a symbol is referenced by multiple schematics, convert it once and cache the result. The `visited` hash set in `walkSchematic` already does this. |

**Confidence: HIGH** -- BFS walk is the natural approach for hierarchical schematics and is already implemented.

### File Classification

| Input Pattern | Output | Detection |
|---|---|---|
| `.sch` + companion `.sym` | `.chn` (component) | Check if `<stem>.sym` exists in search paths |
| `.sch` alone (no `.sym`) | `.chn_tb` (testbench) | No companion symbol found AND zero pins in schematic |
| `.sym` alone (no `.sch`) | `.chn_prim` (primitive) | Symbol-only file, typically PDK cells |
| `.sch` with pins but no `.sym` | `.chn` (component) | Has ipin/opin/iopin instances -> component even without separate .sym file |

**Confidence: HIGH** -- This classification is specified in PROJECT.md and Page.md.

### Symbol Data Resolution

| Strategy | When Used | Why |
|---|---|---|
| `map.zig` comptime LUT | Built-in XSchem devices (resistor, nmos4, vsource, etc.) | O(1) `StaticStringMap` lookup from sym filename to `DeviceKind`. Already handles 70+ canonical symbols and aliases. |
| Search path resolution | User/PDK symbols | Walk `XSCHEM_LIBRARY_PATH` dirs looking for `<symbol>.sym`. Parse the `.sym` to extract pin names, directions, format string, template. |
| Builtin fallback | When .sym file not found | `builtinSymFallback` in impl.zig provides SymData from DeviceKind's hardcoded pin order. Prevents crashes on missing symbols. |

**Confidence: HIGH** -- All three strategies exist in impl.zig and are tested.

---

## Testing Strategy

### Primary: Netlist Roundtrip Comparison

| Approach | What | Why | Confidence |
|---|---|---|---|
| **SPICE netlist diff** | Generate SPICE from XSchem (via `xschem -n`), generate SPICE from converted `.chn` (via `Schemify.emitSpice`), diff the netlists | This is THE definitive correctness test. If both netlists produce the same SPICE, the conversion is electrically correct. Property-level differences that do not affect the netlist are acceptable. | HIGH |

Implementation:
```
for each test case (sch_path, sym_path):
  1. xschem -n -q <sch_path> -o /tmp/ref.spice    # Reference netlist
  2. convertFiles(sch_path, sym_path) -> Schemify
  3. schemify.resolveNets()
  4. schemify.emitSpice() -> candidate_spice
  5. normalize both (strip comments, sort subckt pins, collapse whitespace)
  6. assert normalized_ref == normalized_candidate
```

Normalization is critical because:
- XSchem and Schemify may emit subcircuit parameters in different order
- Instance naming may differ (M0 vs m1)
- Comment lines differ
- Whitespace is irrelevant in SPICE

### Secondary: Golden File Tests

| Approach | What | Why | Confidence |
|---|---|---|---|
| **`.sch` -> `.chn` snapshot tests** | Convert known `.sch` files, compare output `.chn` against checked-in golden files | Catches regressions in the translation layer. If the output format changes intentionally, update golden files. Fast (no external tool dependency). | HIGH |

Implementation:
```
for each golden pair (input.sch, expected.chn):
  1. readFile(input.sch) -> XSchem
  2. xschemToSchemify(xschem) -> Schemify
  3. loadSymbolData(schemify, search_dirs)
  4. schemify.writeFile() -> actual_chn
  5. assert actual_chn == expected_chn (byte-exact or normalized)
```

Start with 3-5 golden files covering:
1. Simple component (cmos_inv.sch -- 2 MOSFETs, simple)
2. Testbench (test_ac.sch -- code blocks, analysis)
3. Hierarchical (poweramp.sch -- subcircuit instances)
4. PDK primitive (sky130_fd_sc_hd__inv_1.sym -- symbol-only)
5. Edge case (bus_keeper.sch -- bidirectional pins, doublepin)

### Tertiary: Structural Validation

| Approach | What | Why | Confidence |
|---|---|---|---|
| **Property preservation checks** | Verify that key properties (W, L, model, value) survive the conversion | Properties are the most fragile part of conversion. XSchem's `template=` and `format=` strings encode property names that must be preserved exactly for SPICE correctness. | MEDIUM |
| **Pin count assertions** | After conversion, assert `schemify.pins.len == xschem.pins.len` for components | Missing pins = broken connectivity. | HIGH |
| **Instance count assertions** | After conversion, assert electrical instance counts match | Missing instances = incorrect circuit. Non-electrical instances (labels, titles) should NOT be counted. | HIGH |

### What NOT to Test

| Anti-Test | Why Skip |
|---|---|
| Coordinate exact-match | XSchem uses f64, Schemify uses i32. Rounding differences are expected and irrelevant to correctness. Test connectivity, not geometry. |
| Visual rendering comparison | No automated rendering comparison feasible. Visual correctness is a manual QA step. |
| Fuzzing with random bytes | XSchem files are structured text. Random byte fuzzing has low signal. If fuzzing is desired later, use grammar-aware fuzzing that generates valid XSchem syntax with edge-case property values. |

**Confidence: HIGH** -- The netlist roundtrip approach is explicitly specified in PROJECT.md and Page.md as the primary validation method.

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|---|---|---|---|
| Parser type | Line-by-line tag dispatch | Recursive descent / PEG | Format is too simple. Existing parser works. |
| Memory model | Arena-per-file | GPA with individual frees | Arena matches existing pattern, simpler, no leaks possible. |
| Coordinate types | f64 parse -> i32 store | Store as f64 in Schemify | Schemify core uses i32. Converting at parse time is correct. |
| Tcl evaluator | Built-in Zig implementation | Embed libtcl / call `tclsh` | WASM target cannot shell out. Pure Zig is mandatory. |
| Dependency walk | BFS from root | Full graph + topo sort | BFS is simpler, handles the common case, and is already implemented. |
| Symbol lookup | Comptime LUT + runtime search | Dynamic config file mapping | Comptime LUT is O(1) for builtins, search path fallback handles the rest. |

---

## Key Libraries and Dependencies

### From Schemify Core (imported via `schemify_sdk`)

| Module | Import Path | Used For |
|---|---|---|
| `Schemify` | `core.Schemify` | Target data model -- the conversion output |
| `Devices` | `core.Devices` | `DeviceKind` enum, `Device` struct, PDK resolution |
| `SpiceIF` | `core.SpiceIF` | SPICE emission for netlist roundtrip tests |
| `FileIO` | `core.FileIO` | Generic read/write for `.chn` format |
| `PluginIF` | `PluginIF` | ABI v6 plugin protocol (`Reader`/`Writer`/`Descriptor`) |
| `utility` | `utility` | Logger, SIMD helpers (`LineIterator`, `estimateCHNSize`) |

### EasyImport-Internal Modules

| Module | Path | Purpose |
|---|---|---|
| `XSchem.zig` | `src/XSchem/XSchem.zig` | XSchem DOD struct + parser/writer |
| `XSchemRC.zig` | `src/XSchem/XSchemRC.zig` | xschemrc Tcl-subset parser |
| `map.zig` | `src/XSchem/map.zig` | Comptime sym-to-DeviceKind bidirectional map |
| `impl.zig` | `src/XSchem/impl.zig` | Conversion pipeline (xschemToSchemify, walkSchematic, etc.) |
| `TCL.zig` | `src/TCL.zig` | Tcl evaluator for variable expansion |
| `mod.zig` | `src/XSchem/mod.zig` | Public API (Backend struct, convertFiles, convertProject) |

### External Dependencies: NONE

The converter has zero external dependencies beyond the Zig standard library and the Schemify core SDK. This is by design:
- No C libraries (WASM compatibility)
- No network dependencies (offline operation)
- No external Tcl interpreter (pure Zig evaluator)

---

## Build Configuration

```zig
// plugins/EasyImport/build.zig -- already exists
const sdk_dep = b.dependency("schemify_sdk", .{});

// Key modules:
// - "core" -> schemify core (Schemify, Devices, FileIO, SpiceIF)
// - "PluginIF" -> ABI v6 plugin interface
// - "TCL" -> Tcl evaluator module
// - "xschem_dropin" -> main EasyImport module (used by tests)
```

Tests run via:
```bash
cd plugins/EasyImport && zig build test
```

The test runner CWD is set to the Schemify root (via `run_test.setCwd(sdk_dep.path("."))`) so relative paths to example schematics work.

---

## Critical Implementation Notes

### 1. Wire Net Names: Strip from Physical Wires

XSchem's `N` line `lab=` attribute is a GUI display label, NOT the authoritative net name. The authoritative net name comes from label instances (lab_pin, vdd, gnd, ipin, opin, iopin). The existing `xschemToSchemify` correctly strips `net_name` from physical wires and only sets it on label-injected zero-length wires. **Do not regress on this.**

**Confidence: HIGH** -- Verified in impl.zig lines 127-150. XSchem's own netlister works the same way.

### 2. Symbol Path Rewriting: `.sym` to `.chn`

When an instance references a subcircuit symbol (e.g., `cmos_inv.sym`), the converter rewrites the path to `.chn` (e.g., `cmos_inv.chn`). Built-in device symbols (resistor, nmos4, etc.) keep their original names because `DeviceKind` is authoritative for them.

**Confidence: HIGH** -- Already implemented in impl.zig line 175-179.

### 3. Property Filtering: Meta vs Electrical

XSchem instances carry meta-properties (`name`, `spice_ignore`, `highlight`) that should NOT appear in the converted Schemify output. The filter list in impl.zig (`isXschemMetaProp`) must be kept up to date as new XSchem versions add properties.

**Confidence: MEDIUM** -- The current filter covers known meta-props, but new XSchem releases may add more.

### 4. Rotation/Flip Encoding

XSchem: `rot` is `i32` (0, 1, 2, 3 = 0/90/180/270 degrees), `flip` is `bool`.
Schemify: `rot` is `u2` (same values), `flip` is `bool`.
Conversion: `@truncate(@as(u32, @bitCast(xs_rot)))` -- already in impl.zig.

**Confidence: HIGH**

### 5. f2i Precision

`f2i(x: f64) -> i32` rounds to nearest integer. XSchem's default snap grid is 10.0, so well-formed files always have integer-aligned coordinates. However, manually edited or buggy files may have fractional coordinates. Rounding is the correct behavior (not truncation).

**Confidence: HIGH**

---

## Sources

- [XSchem Developer Info / File Format](https://xschem.sourceforge.io/stefan/xschem_man/developer_info.html) -- Official format specification (verified via WebFetch)
- [XSchem Manual](https://xschem.sourceforge.io/stefan/xschem_man/xschem_man.html) -- Properties, netlisting, symbol conventions
- [XSchem Properties](https://xschem.sourceforge.io/stefan/xschem_man/xschem_properties.html) -- K block attributes, format strings, template strings
- Existing codebase: `plugins/EasyImport/src/XSchem/XSchem.zig` (parser), `impl.zig` (converter), `map.zig` (device mapping) -- PRIMARY source of truth
- `src/core/Schemify.zig`, `src/core/Reader.zig`, `src/core/Writer.zig` -- Target data model and serialization format
- `docs/Arch.md` -- .chn format specification
