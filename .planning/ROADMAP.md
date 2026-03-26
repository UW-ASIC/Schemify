# Roadmap: EasyImport (XSchem Backend)

## Overview

EasyImport converts XSchem projects into Schemify's native .chn format. The roadmap decomposes a 2700-line monolithic converter into a clean five-stage pipeline: parse, discover, translate, orchestrate, validate. Phases follow the data flow -- parsers first (everything depends on correct parsing), then dependency discovery (must know what to convert before converting), then translation in two phases (core logic then harder symbol/pin work), then pipeline orchestration, validation, and finally the thin UI/CLI wrappers. Architecture constraints (DOD, no Backend union, arena-per-stage) are established in Phase 1 and enforced throughout.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Parser Foundation** - Clean up XSchem/XSchemRC parsers and Tcl evaluator to DOD style, verify against real sky130 xschemrc
- [ ] **Phase 2: Dependency Discovery** - Build DepTree module for BFS file discovery, classification, topological sort, and cycle detection
- [ ] **Phase 3: Core Translation** - Translate instances, wires, device classification, properties, and label semantics from XSchem IR to Schemify IR
- [ ] **Phase 4: Symbol Resolution and Geometry** - Handle graphical elements, SPICE code blocks, pin ordering, symbol data loading, companion .sym merge, and extra= filtering
- [ ] **Phase 5: Pipeline Orchestration** - Wire stages into full project conversion: xschemrc parse, discovery, PDK conversion, project conversion, Config.toml generation
- [ ] **Phase 6: Validation and Testing** - Structural validation, netlist roundtrip tests, golden file tests, and conversion reporting
- [ ] **Phase 7: Plugin and CLI Interface** - ABI v6 plugin entry point with GUI panel and CLI batch mode

## Phase Details

### Phase 1: Parser Foundation
**Goal**: All XSchem file formats parse correctly into DOD structs, and real-world xschemrc files resolve all library paths without errors
**Depends on**: Nothing (first phase)
**Requirements**: PARSE-01, PARSE-02, PARSE-03, PARSE-04, PARSE-05, PARSE-06, ARCH-01, ARCH-02, ARCH-03, ARCH-04
**Success Criteria** (what must be TRUE):
  1. A real sky130 xschemrc file parses and all library search paths resolve to valid directories
  2. Any XSchem .sch file from the examples directory parses into a struct-of-arrays with all element types (L, B, P, A, T, N, C) populated
  3. Any XSchem .sym file parses with K-block properties (type, format, template) extracted correctly
  4. Instance properties with brace escaping, backslash sequences, and quoted values round-trip through parse without data loss
  5. Each pipeline stage file is under 400 lines, uses arena allocators, and contains no OOP method chains or Backend/Runtime unions
**Plans:** 4 plans

Plans:
- [ ] 01-01-PLAN.md -- XSchem DOD types, Schematic container, and PropertyTokenizer
- [ ] 01-02-PLAN.md -- XSchem .sch/.sym reader with tag-dispatch parsing
- [ ] 01-03-PLAN.md -- Tcl subset evaluator (tokenizer, expression parser, evaluator, commands)
- [ ] 01-04-PLAN.md -- XSchemRC parser using Tcl evaluator, build.zig wiring, integration tests

### Phase 2: Dependency Discovery
**Goal**: Given a root schematic and resolved search paths, the complete set of reachable files is discovered, classified, and ordered for conversion
**Depends on**: Phase 1
**Requirements**: DISC-01, DISC-02, DISC-03, DISC-04
**Success Criteria** (what must be TRUE):
  1. Starting from a root .sch file, BFS discovers all transitively referenced .sch and .sym files across search path directories
  2. Each discovered file is classified as component (.sch+.sym pair), testbench (.sch alone), or primitive (.sym alone)
  3. Topological sort produces leaf-first ordering so children are always converted before parents
  4. A schematic with a circular reference produces a diagnostic error message instead of hanging or crashing
**Plans**: TBD

### Phase 3: Core Translation
**Goal**: Individual XSchem schematics convert to Schemify IR with correct instances, wires, device classification, properties, and net naming
**Depends on**: Phase 2
**Requirements**: XLAT-01, XLAT-02, XLAT-03, XLAT-04, XLAT-05, XLAT-06
**Success Criteria** (what must be TRUE):
  1. An XSchem schematic with resistors, capacitors, and MOSFETs converts to Schemify instances with correct DeviceKind, position, rotation, and flip
  2. All XSchem wires (N-elements) appear as Schemify wires with identical endpoints
  3. Label instances (lab_pin, ipin, opin, iopin) set authoritative net names, and wire lab= attributes are ignored for connectivity
  4. XSchem meta-properties (highlight, color, flags) are stripped; circuit-relevant properties (value, model, W, L) are preserved
**Plans**: TBD

### Phase 4: Symbol Resolution and Geometry
**Goal**: Converter handles all remaining XSchem constructs -- graphical elements, SPICE code blocks, pin ordering, symbol data loading, and companion symbol merge
**Depends on**: Phase 3
**Requirements**: XLAT-07, XLAT-08, XLAT-09, XLAT-10, XLAT-11, XLAT-12, XLAT-13
**Success Criteria** (what must be TRUE):
  1. Graphical elements (lines, rects, arcs, circles) and text elements translate to Schemify shapes with correct position, rotation, and layer
  2. SPICE code block instances (type=subcircuit with value= containing directives) convert to Schemify SPICE directive elements
  3. PinOrderResolver produces correct pin ordering using the priority chain (sim_pinnumber > format @@PIN > B-box order) for sky130 standard cells
  4. Companion .sym geometry (shapes, pins) merges into component .chn files
  5. Extra= pin tokens that are template variables (not real pins) are filtered out correctly
**Plans**: TBD

### Phase 5: Pipeline Orchestration
**Goal**: Full project conversion runs end-to-end: xschemrc parse through to .chn output files and Config.toml, including PDK library conversion
**Depends on**: Phase 4
**Requirements**: PROJ-01, PROJ-02, PROJ-03, PROJ-04, PROJ-05
**Success Criteria** (what must be TRUE):
  1. Running conversion on a sky130 project produces .chn files alongside original .sch files (in-place output)
  2. PDK library conversion walks the PDK xschem/ directory and produces .chn_prim files preserving the original directory structure
  3. A Config.toml is generated with correct glob patterns referencing all converted files
  4. A real sky130 PDK project converts end-to-end without errors
**Plans**: TBD

### Phase 6: Validation and Testing
**Goal**: Converted projects produce identical SPICE netlists to the originals, verified by automated tests
**Depends on**: Phase 5
**Requirements**: VALID-01, VALID-02, VALID-03, VALID-04
**Success Criteria** (what must be TRUE):
  1. Structural validation reports instance count, wire count, and pin count -- all matching between original and converted schematics
  2. SPICE netlist generated from a converted project matches the SPICE netlist generated by XSchem from the original project (netlist roundtrip)
  3. Golden file tests pass for cmos_inv, poweramp, and at least one sky130 standard cell
  4. Conversion produces a report listing any warnings (unresolved symbols, skipped elements, property mismatches)
**Plans**: TBD

### Phase 7: Plugin and CLI Interface
**Goal**: Users can trigger conversion from within the Schemify GUI or from the command line
**Depends on**: Phase 6
**Requirements**: IFACE-01, IFACE-02, IFACE-03
**Success Criteria** (what must be TRUE):
  1. The plugin loads in Schemify and registers a panel via ABI v6 schemify_process entry point
  2. User can enter a project path in the GUI panel, click Convert, and see a results log with success/failure status
  3. Running the CLI with a project path argument converts the project and exits with appropriate status code
**Plans**: TBD
**UI hint**: yes

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Parser Foundation | 0/4 | Planning complete | - |
| 2. Dependency Discovery | 0/? | Not started | - |
| 3. Core Translation | 0/? | Not started | - |
| 4. Symbol Resolution and Geometry | 0/? | Not started | - |
| 5. Pipeline Orchestration | 0/? | Not started | - |
| 6. Validation and Testing | 0/? | Not started | - |
| 7. Plugin and CLI Interface | 0/? | Not started | - |
