# Project Research Summary

**Project:** EasyImport (XSchem Backend)
**Domain:** EDA schematic format converter (XSchem .sch/.sym to Schemify .chn/.chn_tb/.chn_prim)
**Researched:** 2026-03-26
**Confidence:** HIGH

## Executive Summary

EasyImport is a format converter that transforms XSchem schematics (.sch/.sym) into Schemify's native .chn format. This is not a greenfield project -- roughly 80% of the conversion logic already exists in a 2700-line monolithic `impl.zig` that has grown unmaintainable. The rewrite decomposes that monolith into a clean five-stage pipeline (config parse, discovery, translation, serialization, config generation) while preserving the proven parsing and device-mapping code that already works. The technology stack is fully constrained by the host project: Zig 0.15, arena allocators, MultiArrayList SOA storage, and the ABI v6 plugin protocol. There are no external dependencies and no meaningful technology choices to make -- the work is architectural decomposition and correctness hardening.

The recommended approach is a strict separation of discovery from conversion. The old code interleaves file discovery with translation (walkSchematic converts files as it finds them), which prevents progress reporting, cycle detection, and correct dependency ordering. The new architecture builds a complete dependency DAG first, then converts files in topological order (leaves first). This guarantees that when a parent schematic references a child symbol, the child's .chn already exists. Each pipeline stage gets its own file (under 400 lines), its own arena allocator, and a clear input/output contract.

The primary risk is **pin ordering correctness**. XSchem has at least five different mechanisms that determine the order pins appear in a SPICE netlist (.subckt header). Getting this wrong produces circuits that simulate without errors but give completely wrong results because, for example, a MOSFET's drain and source are swapped. The mitigation is a single PinOrderResolver module with a documented priority chain, validated by netlist roundtrip testing (comparing XSchem-generated SPICE against Schemify-generated SPICE from the converted project). This roundtrip test is the acceptance criterion that gates the entire project.

## Key Findings

### Recommended Stack

The stack is fully determined by constraints from the Schemify host project and the WASM target requirement. There are zero discretionary technology choices.

**Core technologies:**
- **Zig 0.15** (std.heap.ArenaAllocator, std.MultiArrayList): Must match host build. Already proven in existing XSchem.zig parser. Arena-per-file allocation gives zero-leak-risk memory management with single deinit() teardown.
- **Line-by-line tag dispatch parser**: XSchem format is line-oriented with single-character tags (N, C, T, L, B, A, P). Existing parser works. No grammar/tokenizer framework needed.
- **Custom Tcl subset evaluator (TCL.zig)**: Real xschemrc files use `$env()`, `[file dirname [info script]]`, `set`, `append`, `if/else`. Cannot shell out to tclsh on WASM. Pure Zig evaluator is mandatory.
- **Comptime StaticStringMap (map.zig)**: O(1) lookup from XSchem symbol filenames to DeviceKind. Handles 80+ canonical symbols and aliases. Already solid.
- **BFS dependency walk**: Start from root schematic, discover children, queue unvisited symbols. Convert in topological order (leaves first). Already implemented in walkSchematic, but must be separated from conversion.

### Expected Features

**Must have (table stakes -- 19 features):**
- T1-T3: .sch/.sym parser, xschemrc Tcl evaluator, library path resolution
- T4-T8: DeviceKind classification, wire/instance/label/code-block translation
- T9-T10: Symbol data loading (pin positions, format, template) and companion .sym geometry merge
- T11-T15: File classification, dependency ordering, .chn serialization, Config.toml generation, PDK library conversion
- T16-T19: Property filtering, brace unescaping, backslash removal, graphical element translation

Most of these already have working implementations in the old codebase. The work is restructuring them into a maintainable pipeline, not writing from scratch.

**Should have (differentiators):**
- D1: Netlist roundtrip validation -- THE acceptance criterion. XSchem SPICE output vs Schemify SPICE output from converted files must match.
- D5: Structural validation report -- instance/wire/pin count summary, unresolved symbol warnings. Builds user trust.

**Defer (v1.1+):**
- D2: TCL generator symbol support (.tcl() scripts, requires tclsh at runtime)
- D3: Embedded symbol handling (inline [...] definitions, rare)
- D4: Bus wire expansion (multi-bit wire naming)
- D6: ABI v6 plugin GUI (interactive panel with progress)
- D7: CLI batch mode
- D8: Incremental PDK conversion (mtime-based skip)

### Architecture Approach

Five-stage batch pipeline with explicit dependency resolution before conversion. Each stage is its own file with clear input/output contracts. No Backend trait or Runtime union -- the converter is XSchem-specific and should be built as direct function calls without polymorphic abstraction.

**Major components:**
1. **XSchemRC** (XSchemRC.zig + TCL.zig) -- Parse xschemrc, expand Tcl variables, extract search paths and PDK root
2. **XSchem** (XSchem.zig) -- Parse .sch/.sym text into DOD struct-of-arrays
3. **DepTree** (DepTree.zig, NEW) -- Discover all reachable files, build dependency DAG, classify nodes, produce topological order
4. **Translator** (Translator.zig, NEW) -- Convert one XSchem struct into one Schemify schematic via FileIO builder functions. Creates a new FileIO(.schemify) and builds step-by-step, ensuring no XSchem quirks leak through. Includes device classification, property filtering, companion .sym merge, pin extraction
5. **ProjectConverter** (ProjectConverter.zig, NEW) -- Orchestrate: config parse -> discovery -> PDK convert -> project convert -> Config.toml gen
6. **PluginEntry** (plugin.zig, NEW) -- ABI v6 wrapper, GUI panel, CLI entry point
7. **map.zig** (existing) -- Comptime bidirectional map between symbol filenames and DeviceKind

### Critical Pitfalls

1. **Pin ordering is the #1 source of wrong netlists** -- XSchem has 5+ pin ordering mechanisms (B-box order, sim_pinnumber, format @@PIN tokens, spice_sym_def .subckt order, @pinlist creation order). Build a single PinOrderResolver with a documented priority chain. Test with netlist roundtrip comparison on every change.

2. **The god-file problem (2713-line impl.zig)** -- The old code grew unmaintainable because discovery, translation, symbol resolution, and pin extraction are interleaved in one file. Prevent by enforcing the five-stage pipeline with max 400 lines per file.

3. **Backend/Runtime union abstraction trap** -- The old code builds polymorphic dispatch for a single backend (Virtuoso variant is all `error.NotImplemented`). Build XSchem conversion as direct function calls. Add polymorphism later only when a second backend actually exists.

4. **Wire label vs label instance confusion** -- XSchem wire `lab=` attributes are display annotations, NOT authoritative net names. Net names come only from label instances (lab_pin.sym, ipin.sym, etc.). Strip net_name from all physical wires during translation.

5. **extra= pin filtering** -- Not all tokens in a symbol's `extra=` attribute are real pins; some are template variables. Use a single `isExtraTokenAPin(token, format_string)` predicate that checks for `@TOKEN` (single-@) in the format string.

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Parser Cleanup and Foundation

**Rationale:** All downstream work depends on correct parsing. The parsers (XSchem.zig, XSchemRC.zig, TCL.zig, map.zig) already exist and are proven. This phase cleans them up to DOD style, ensures the Tcl evaluator handles real-world xschemrc constructs (`source`, `[file dirname]`, `$env()`, `if/else`, `append`), and verifies against the sky130 xschemrc.
**Delivers:** Reliable file parsing and library path resolution -- the foundation everything else builds on.
**Addresses:** T1, T2, T3, T4, T16, T17, T18 (parsers, path resolution, property filtering, unescaping)
**Avoids:** Pitfall #6 (Tcl evaluation gaps), Pitfall #14 (system library path discovery), Pitfall #1 (god-file -- start with clean boundaries)

### Phase 2: Dependency Discovery (DepTree)

**Rationale:** Must know the complete file list and conversion order before converting anything. This is the core architectural improvement over the old code. Cannot report progress, detect cycles, or guarantee correct ordering without it.
**Delivers:** DepTree.zig -- file discovery, dependency DAG, topological sort, node classification (component/testbench/primitive). Testable in isolation.
**Addresses:** T11 (file classification), T12 (dependency ordering)
**Avoids:** Anti-Pattern #1 (interleaved discovery/conversion), enables cycle detection

### Phase 3: Single-File Translation (Translator)

**Rationale:** With parsers working and dependency order known, the core conversion logic can be built. This is the highest-risk phase because pin ordering and property mapping must be exactly correct. Dedicate a full phase to get this right.
**Delivers:** Translator.zig -- convert one XSchem struct to one Schemify schematic via FileIO builder functions (creates FileIO(.schemify), builds step-by-step). Includes instance classification, property filtering, companion .sym merge, pin extraction via PinOrderResolver.
**Addresses:** T5, T6, T7, T8, T9, T10, T19 (wire/instance/label/code-block/symbol/graphical translation)
**Avoids:** Pitfall #2 (pin ordering -- single PinOrderResolver with priority chain), Pitfall #4 (wire label confusion), Pitfall #5 (extra= filtering), Pitfall #10 (type=label post-hoc fixup via two-phase classification), Pitfall #13 (property field mismatch)

### Phase 4: Pipeline Orchestration and Output

**Rationale:** With individual files convertible, wire them into the full project conversion pipeline. Includes PDK conversion, Config.toml generation, and in-place file output with preserved directory structure.
**Delivers:** ProjectConverter.zig -- full project conversion from xschemrc to .chn output. Config.toml generation.
**Addresses:** T13, T14, T15 (.chn serialization, Config.toml, PDK library conversion)
**Avoids:** Pitfall #3 (no Backend union -- direct function calls), Pitfall #8 (flat directory collisions -- preserve directory structure), Pitfall #9 (memory allocation -- one arena per stage)

### Phase 5: Validation and Testing

**Rationale:** Netlist roundtrip testing is the acceptance criterion. It must validate that XSchem SPICE output matches Schemify SPICE output from converted projects. This phase also adds structural validation (instance/wire/pin count assertions) and golden file tests.
**Delivers:** Test suite with netlist roundtrip comparison, golden file tests, structural validation. Conversion report (D5).
**Addresses:** D1 (netlist roundtrip), D5 (structural validation report)
**Avoids:** All silent netlist correctness errors. This phase catches Pitfall #2 regressions.

### Phase 6: Plugin Entry Point and CLI

**Rationale:** Core pipeline must work before wrapping it in UI. Plugin GUI and CLI are thin wrappers around ProjectConverter.
**Delivers:** ABI v6 plugin with GUI panel (project path input, convert button, progress display, results log). CLI batch mode.
**Addresses:** D6 (plugin GUI), D7 (CLI batch mode)
**Avoids:** Pitfall #12 (blocking conversion on draw_panel -- convert on button click only), Pitfall #3 (no Backend union in plugin dispatch)

### Phase 7: Edge Cases and Polish (v1.1)

**Rationale:** Defer non-critical features that add complexity without affecting core correctness.
**Delivers:** TCL generator support (D2), embedded symbols (D3), bus wire expansion (D4), incremental PDK conversion (D8).
**Addresses:** D2, D3, D4, D8

### Phase Ordering Rationale

- **Phases 1-2 first** because every other phase depends on correct parsing and file discovery. The parsers are mostly proven code that needs cleanup, not invention.
- **Phase 3 is the highest-risk phase** and gets its own dedicated phase because pin ordering and property mapping are where silent bugs hide. All 5 critical pitfalls from the research affect this phase.
- **Phase 4 before Phase 5** because you need the full pipeline producing output before you can validate it with roundtrip tests.
- **Phase 6 last** because the plugin/CLI entry points are thin wrappers. The core pipeline is testable without them.
- **Phases group by architecture component**, matching the ARCHITECTURE.md component boundaries exactly: XSchemRC (Phase 1), XSchem (Phase 1), DepTree (Phase 2), Translator (Phase 3), ProjectConverter (Phase 4), PluginEntry (Phase 6).

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 1 (Tcl evaluator):** The existing TCL.zig handles basic constructs but needs validation against real sky130 xschemrc. May discover unsupported `proc`, `source`, or `foreach` patterns that block path resolution. Research needed to determine the minimal Tcl subset required.
- **Phase 3 (Pin ordering):** Pin ordering has 5+ mechanisms with underdocumented priority rules. The research identifies the priority chain but implementation will likely uncover edge cases. Research the XSchem C source code's `expandlabel.c` and `netlist.c` for the authoritative algorithm.

Phases with standard patterns (skip research-phase):
- **Phase 2 (DepTree):** BFS graph traversal with topological sort. Well-understood CS fundamentals, no domain-specific research needed.
- **Phase 4 (ProjectConverter):** Orchestration of known stages. Standard pipeline composition pattern.
- **Phase 5 (Validation):** Netlist comparison is specified in PROJECT.md. SPICE normalization and diff are straightforward string processing.
- **Phase 6 (Plugin/CLI):** ABI v6 protocol is fully documented in PluginIF.zig. Standard message handling pattern.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Zero discretionary choices. All technologies constrained by host project. Existing code proves viability. |
| Features | HIGH | Comprehensive catalog derived from XSchem official docs + existing codebase analysis + real-world xschemrc inspection. Feature dependency graph is well-understood. |
| Architecture | HIGH | Architecture derived from direct analysis of 2700-line old impl.zig + Schemify core data model. Five-stage pipeline is the natural decomposition. Component boundaries match existing module structure. |
| Pitfalls | HIGH | All critical pitfalls (pin ordering, god-file, wire labels, extra= filtering) are documented with specific line references in old code and concrete prevention strategies. Sourced from real bugs encountered in old implementation. |

**Overall confidence:** HIGH

### Gaps to Address

- **Tcl evaluator completeness for real PDK xschemrc**: The existing TCL.zig works for simple cases but has not been tested against complex PDK xschemrc files that use `proc`, `source`, and `switch`. Validate during Phase 1 by parsing the actual xschem_sky130 xschemrc and checking that all library paths resolve correctly. If gaps are found, implement the minimum Tcl commands needed for path resolution (not a full Tcl interpreter).

- **Pin ordering priority chain validation**: The research identifies 5 ordering mechanisms and their priority, but the exact algorithm was inferred from old code behavior and XSchem docs, not from reading XSchem's C source directly. During Phase 3 planning, read `expandlabel.c` from the XSchem C source to confirm the priority chain is correct.

- **Polygon translation**: XSchem.zig parses P-elements (polygons) but xschemToSchemify does not translate them yet. Need to determine during Phase 3 whether Schemify's line/arc primitives can approximate polygons or if a new primitive type is needed. Low priority since polygons are rare in practical schematics.

- **Large PDK conversion performance**: The research estimates 30+ seconds for 1000+ file PDK conversions. If this is unacceptable, Phase 4 may need per-tick chunking in the plugin (convert N files per schemify_process call). Measure actual performance during Phase 4 before optimizing.

## Sources

### Primary (HIGH confidence)
- [XSchem Developer Info / File Format](https://xschem.sourceforge.io/stefan/xschem_man/developer_info.html) -- Official format specification
- [XSchem Properties](https://xschem.sourceforge.io/stefan/xschem_man/xschem_properties.html) -- Property key documentation, pin ordering, format strings
- [XSchem Elements](https://xschem.sourceforge.io/stefan/xschem_man/xschem_elements.html) -- Element type catalog
- [XSchem Symbol Property Syntax](https://xschem.sourceforge.io/stefan/xschem_man/symbol_property_syntax.html) -- format strings, extra=, type= attribute
- [XSchem Netlisting](https://xschem.sourceforge.io/stefan/xschem_man/netlisting.html) -- @pinlist, @@PIN, spice_sym_def
- Existing codebase: `plugins/EasyImport/.cache/src_old/XSchem/impl.zig` (2713 lines), `XSchem.zig`, `XSchemRC.zig`, `TCL.zig`, `map.zig`, `mod.zig`, `lib.zig`
- Schemify core: `src/core/Schemify.zig`, `Types.zig`, `Devices.zig`, `Reader.zig`, `Writer.zig`
- `docs/Arch.md` -- .chn format specification
- `.planning/PROJECT.md` -- Project requirements

### Secondary (MEDIUM confidence)
- [xschem_sky130 xschemrc](https://github.com/StefanSchippers/xschem_sky130/blob/main/xschemrc) -- Real-world Tcl complexity example
- [XSchem Tutorial: Use Existing Subckt](https://xschem.sourceforge.io/stefan/xschem_man/tutorial_use_existing_subckt.html) -- spice_sym_def pin ordering behavior
- [XSchem Sky130 Integration Tutorial](https://xschem.sourceforge.io/stefan/xschem_man/tutorial_xschem_sky130.html) -- PDK integration patterns

### Tertiary (LOW confidence)
- [EasyEDA Export Guide](https://www.schemalyzer.com/en/blog/easyeda/export-import/export-easyeda-schematics) -- General EDA converter best practices (different tool, but pattern validation)
- [InnoFour Netlist Converter](https://www.innofour.com/solutions/electronic-system-design-products/netlist-converter/) -- Commercial converter feature reference

---
*Research completed: 2026-03-26*
*Ready for roadmap: yes*
