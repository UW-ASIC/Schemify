# Architecture Patterns: XSchem-to-Schemify Conversion Pipeline

**Domain:** EDA schematic format converter (XSchem .sch/.sym -> Schemify .chn/.chn_tb/.chn_prim)
**Researched:** 2026-03-26
**Confidence:** HIGH (analysis of existing codebase, not speculative)

## Recommended Architecture

The pipeline is a five-stage batch conversion with an explicit dependency resolution pass before any file translation begins. The old `impl.zig` interleaves discovery with conversion (walkSchematic discovers children *during* conversion), which works but makes it impossible to report progress, detect cycles, or order by dependency depth. The new architecture separates discovery from translation.

```
                    +------------------+
                    |  Entry Points    |
                    |  (ABI v6 / CLI)  |
                    +--------+---------+
                             |
                    +--------v---------+
                    |  1. Config Parse |  xschemrc -> search paths, PDK root, start_window
                    |     (XSchemRC)   |
                    +--------+---------+
                             |
                    +--------v---------+
                    |  2. Discovery    |  Scan all .sch/.sym files reachable from
                    |     (DepTree)    |  start_window or project root.
                    |                  |  Build dependency DAG. Classify each node.
                    +--------+---------+
                             |
              +--------------+---------------+
              |                              |
    +---------v----------+      +-----------v-----------+
    |  3a. PDK Convert   |      |  3b. Project Convert  |
    |  (leaf .sym only)  |      |  (topological order)  |
    +--------------------+      +--------+--------------+
              |                          |
              |     +--------------------+
              |     |
    +---------v-----v----+
    |  4. Serialize       |  Schemify.writeFile -> .chn bytes -> disk
    |     (Writer)        |
    +--------+------------+
             |
    +--------v------------+
    |  5. Config.toml Gen |  Glob patterns for converted files
    +---------------------+
```

### Component Boundaries

| Component | File(s) | Responsibility | Communicates With |
|-----------|---------|---------------|-------------------|
| **XSchemRC** | `XSchemRC.zig` + `TCL.zig` | Parse xschemrc, expand Tcl variables, extract search paths/PDK root/start_window | DepTree (provides search paths) |
| **XSchem** | `XSchem.zig` | Parse .sch/.sym text into DOD XSchem struct (SoA of lines, rects, wires, instances, pins, props) | Translator (provides parsed XSchem) |
| **DepTree** | `DepTree.zig` (new) | Discover all .sch/.sym files, resolve symbol references against search paths, build dependency DAG, classify nodes, produce topological order | XSchem (reads files to find instance references), XSchemRC (search paths) |
| **Translator** | `Translator.zig` (new, replaces xschemToSchemify + mergeSymbolData + loadCompanionPins + loadSymbolData) | Convert one XSchem struct into one Schemify IR. Includes instance classification (map.zig), property filtering, companion .sym merge, pin extraction | XSchem (input), map.zig (device classification), core.Schemify (output) |
| **SymbolResolver** | Part of Translator | Resolve symbol paths against search paths, load companion .sym for geometry/pin data, handle builtin fallbacks | DepTree (path resolution), XSchem (parse .sym files) |
| **ProjectConverter** | `ProjectConverter.zig` (new, replaces openXSchemProject/walkSchematic) | Orchestrate the full pipeline: config parse -> discovery -> PDK convert -> project convert -> Config.toml gen | All other components |
| **ConfigGen** | Part of ProjectConverter | Generate Config.toml with glob patterns for converted files | Filesystem |
| **PluginEntry** | `plugin.zig` (new) | ABI v6 schemify_process entry point, GUI panel for triggering conversion, progress reporting | ProjectConverter, PluginIF Reader/Writer |
| **map.zig** | `map.zig` (existing) | Comptime bidirectional map between XSchem sym filenames and DeviceKind | Translator |

### What is NOT a component

- **core.Schemify** -- the target IR. This is the *output data structure*, not a component of the converter. The converter populates it via its builder API (`addWire`, `addComponent`, `drawLine`, `drawPin`, etc.)
- **core.Reader/Writer** -- serialization of the .chn format. The converter calls `Schemify.writeFile()` and does not need to know the wire format.
- **core.Netlist** -- SPICE emission. Only used for validation tests (roundtrip netlist comparison), not during conversion itself.

## Data Flow

### Stage 1: Config Parse

```
xschemrc file (bytes)
    |
    v
XSchemRC.parse(alloc, bytes, project_dir)
    |
    v
XSchemRC struct:
  .lib_paths:     [][]const u8   -- absolute search paths for .sym/.sch resolution
  .start_window:  ?[]const u8    -- entry point .sch file
  .pdk_root:      ?[]const u8    -- PDK root ($PDK_ROOT or derived)
  .netlist_dir:   ?[]const u8    -- where XSchem writes netlists
  .xschem_sharedir: []const u8   -- system XSchem library location
```

**TCL evaluator dependency:** Real xschemrc files use Tcl expressions like `[file dirname [info script]]`, `$env(HOME)`, `$PDK_ROOT`, `[pwd]`. The existing `TCL.zig` handles a subset. The full evaluator needs: variable substitution (`$var`, `${var}`), bracket commands (`[file dirname ...]`, `[file join ...]`, `[pwd]`), `$env()` array access, brace grouping, `lappend`, `append`, `set`, basic `if`/`else`. This is a self-contained component with no dependency on the rest of the pipeline.

### Stage 2: Discovery and Dependency Resolution

```
XSchemRC.lib_paths + start_window (or project dir scan)
    |
    v
DepTree.discover(start_paths, search_dirs, alloc)
    |
    Iterative process:
    1. Parse each .sch to extract instance symbol references
    2. Resolve each symbol reference against search paths (resolveRelPath)
    3. For each resolved .sym, check if companion .sch exists
    4. Add discovered files to processing queue
    5. Repeat until no new files discovered
    |
    v
DepTree struct:
  .nodes: []Node
    Node = { path, stem, classification, sym_companion, dependencies[] }
  .topo_order: []u32    -- indices into nodes, leaves first
  .pdk_nodes:  []u32    -- subset of nodes that are in PDK directories
  .project_nodes: []u32 -- subset of nodes that are in project directories
```

**Classification rules (per node):**

| Condition | Classification | Output Extension |
|-----------|---------------|-----------------|
| .sch exists AND .sym exists (same stem, same dir) | component | `.chn` |
| .sch exists, NO .sym with same stem | testbench | `.chn_tb` |
| .sym exists, NO .sch with same stem | primitive | `.chn_prim` |

**Dependency edges:** An edge from A to B means "A contains an instance whose symbol resolves to B." Edges are directional. The topological sort produces leaves-first order so that when converting A, all of A's dependencies (B, C, ...) have already been converted.

**Cycle detection:** XSchem schematics can technically have recursive hierarchy (A instantiates B which instantiates A). This is invalid but should be detected and reported, not cause infinite recursion. The old code uses a `visited` hash set which breaks cycles but silently skips files. The new code should explicitly detect and warn.

### Stage 3a: PDK Library Conversion

```
For each pdk_node in DepTree.pdk_nodes (in topo_order):
    |
    v
  XSchem.readFile(bytes)          -- parse .sch or .sym
    |
    v
  Translator.translate(xs, opts)  -- XSchem -> Schemify IR
    |                               opts.merge_sym = has companion .sym
    v
  Schemify.writeFile()            -- serialize to .chn/.chn_prim bytes
    |
    v
  Write to output path            -- alongside originals or in output dir
```

PDK conversion is the same pipeline as project conversion but operates on a well-defined set of files (the entire PDK xschem/ directory). PDK files are leaves in the dependency tree -- they reference models but not other schematics. They can be converted first in any order.

### Stage 3b: Project Conversion

```
For each project_node in DepTree.project_nodes (in topo_order):
    |
    v
  Same translate pipeline as 3a, but:
    - Symbol references (.sym -> .chn) are rewritten in instance paths
    - Companion .sym geometry is merged
    - Companion .sym pins become authoritative pin list
    - loadSymbolData resolves format/template/pin positions for netlisting
```

### Stage 4: Serialization

```
Schemify struct
    |
    v
  core.Writer.writeCHN(alloc, &sify, logger)
    |
    v
  []u8 (CHN format bytes)
    |
    v
  Vfs.writeAll(out_path, bytes)
```

This is a pure function call into core. No conversion logic lives here.

### Stage 5: Config.toml Generation

```
ConvertResult { chn_paths, chn_tb_paths, chn_prim_paths, pdk_chn_paths }
    |
    v
  Generate Config.toml with:
    [paths]
    chn = ["**/*.chn"]
    chn_tb = ["**/*.chn_tb"]
    chn_prim = ["**/*.chn_prim"]

    [pdk]
    root = "<converted PDK dir>"

    [simulation]
    spice_include_paths = [<from xschemrc lib_paths>]
```

## Patterns to Follow

### Pattern 1: Separate Discovery from Conversion

**What:** Build the complete file list and dependency tree BEFORE converting any files.

**When:** Always. This is the core architectural improvement over the old code.

**Why:** The old `walkSchematic` interleaves parsing (to discover children) with conversion (to emit .chn). This means:
- No progress reporting (you don't know total file count)
- No cycle detection (just a visited set)
- No ordering guarantee (you convert parents before children, which means symbol data for children may not be available)
- Error in a child aborts the parent's traversal

**Example:**
```zig
// Discovery pass (no file writes)
var tree = try DepTree.discover(rc.lib_paths, rc.start_window, project_dir, alloc);
defer tree.deinit();

// Report: "Found 147 files to convert (12 PDK, 135 project)"

// Conversion pass (reads and writes, in dependency order)
for (tree.topo_order) |idx| {
    const node = tree.nodes[idx];
    try convertOneFile(node, &tree, alloc);
}
```

### Pattern 2: Single Translation Function per File

**What:** One function that takes an XSchem struct + options and returns a Schemify struct.

**When:** Every file conversion.

**Why:** The old code has `xschemToSchemify` + `mergeSymbolData` + `loadCompanionPins` + `loadSymbolData` as separate calls that must be invoked in the right order. This creates coupling between the caller and the internal ordering. A single `translate(xs, opts)` function encapsulates the correct sequence.

**Example:**
```zig
pub const TranslateOpts = struct {
    sym_companion: ?[]const u8 = null,   // path to companion .sym
    search_dirs: []const []const u8 = &.{}, // for symbol resolution
    classification: Classification,       // .component / .testbench / .primitive
};

pub fn translate(xs: *const XSchem, opts: TranslateOpts, alloc: Allocator) !Schemify {
    var sify = try xschemToSchemify(xs, alloc);
    if (opts.sym_companion) |sym_path| {
        mergeSymbolData(alloc, sym_path, &sify);
        loadCompanionPins(sify.alloc(), alloc, sym_path, &sify);
    }
    sify.setStype(opts.classification.toSifyType());
    try loadSymbolData(&sify, opts.search_dirs, opts.sym_companion, alloc);
    return sify;
}
```

### Pattern 3: Arena Allocator per Conversion Unit

**What:** Each file conversion gets its own arena. The XSchem parse arena is freed after translation. The Schemify arena is freed after serialization.

**When:** Every file conversion.

**Why:** Memory locality. A 1000-file PDK conversion should not accumulate all intermediate XSchem structs in memory. Parse, translate, serialize, free. The only persistent output is the .chn bytes on disk.

**Example:**
```zig
fn convertOneFile(node: DepTree.Node, tree: *const DepTree, alloc: Allocator) !void {
    // Parse XSchem (temporary)
    var xs = XSchem.readFile(bytes, alloc, null);
    defer xs.deinit();  // frees parse arena

    // Translate to Schemify (temporary)
    var sify = try Translator.translate(&xs, .{ ... }, alloc);
    defer sify.deinit();  // frees sify arena

    // Serialize and write (the bytes are written to disk, then freed)
    const chn_bytes = sify.writeFile(alloc, null) orelse return error.WriteFailed;
    defer alloc.free(chn_bytes);
    try Vfs.writeAll(node.output_path, chn_bytes);
}
```

### Pattern 4: Deterministic Symbol Resolution

**What:** Symbol path resolution follows XSchem's exact search order: (1) directory of the referencing .sch, (2) XSCHEM_LIBRARY_PATH entries in order, (3) recursive subdirectory search within each lib path, (4) system library directories.

**When:** During discovery (DepTree) and during translation (SymbolResolver).

**Why:** XSchem has a specific path resolution algorithm. If we diverge, symbols resolve to different files, producing different netlists. The resolution must be deterministic and match XSchem's behavior exactly.

## Anti-Patterns to Avoid

### Anti-Pattern 1: Interleaved Discovery/Conversion (the old walkSchematic)

**What:** Recursively converting files as you discover them.

**Why bad:** Cannot report total progress, cannot detect cycles before they cause problems, ordering is parent-first (wrong for dependency resolution), error recovery is poor.

**Instead:** Two-pass architecture. Discovery builds the DAG. Conversion traverses in topological order.

### Anti-Pattern 2: Backend Trait / Runtime Union Dispatch

**What:** The old `lib.zig` has a `Runtime` union with `xschem` and `virtuoso` variants, dispatching every call through a tagged union switch. The `EasyImport` struct tries to enforce a trait via comptime checks.

**Why bad:** The converter is XSchem-specific. Cadence Virtuoso is out of scope for this milestone. The Runtime union adds a layer of indirection for zero benefit. Comptime trait checking on a union that only has one working variant is ceremony.

**Instead:** Direct function calls into the XSchem pipeline. When Virtuoso is added later, it gets its own pipeline. The plugin entry point can dispatch between them based on detected project type, but the conversion pipelines should not share an interface.

### Anti-Pattern 3: Global Mutable State in Plugin Entry Point

**What:** The old `impl.zig` uses module-level `var` for `g_result`, `g_converted`, `g_project_dir`, `g_log_head`, etc.

**Why bad:** Makes the plugin non-reentrant, complicates testing, creates implicit coupling between `schemify_process` calls.

**Instead:** Store conversion state in a struct that is allocated on `.load` and freed on next `.load` or plugin unload. Pass it through the pipeline explicitly.

### Anti-Pattern 4: Flat Output Directory

**What:** The old code puts ALL converted .chn files in a single `.temp_schemify/` directory, losing the original directory structure.

**Why bad:** Name collisions (two `inv.sch` in different directories produce one `inv.chn`). Harder to map back to originals. Config.toml paths become ambiguous.

**Instead:** Preserve the directory structure. `project_dir/sub/inv.sch` becomes `project_dir/sub/inv.chn` (in-place conversion, as specified in PROJECT.md).

## Component Dependency Graph (Build Order)

```
TCL.zig (standalone, no deps)
    |
    v
XSchemRC.zig (depends on TCL.zig)

XSchem.zig (standalone, no deps except core.simd for LineIterator)

map.zig (depends on core.Devices.DeviceKind)

DepTree.zig (depends on XSchem.zig for instance extraction, XSchemRC for search paths)
    |
    v
Translator.zig (depends on XSchem.zig, map.zig, core.Schemify)
    |
    v
ProjectConverter.zig (depends on DepTree.zig, Translator.zig, XSchemRC.zig)
    |
    v
plugin.zig (depends on ProjectConverter.zig, PluginIF)
```

### Suggested Build Order (phases)

**Phase 1: Parsers (no conversion, just read/understand files)**
- Clean up `TCL.zig` -- ensure full Tcl subset evaluator works for real xschemrc files
- Clean up `XSchemRC.zig` -- uses TCL, must produce correct search paths
- Clean up `XSchem.zig` -- DOD parser for .sch/.sym, already solid
- Clean up `map.zig` -- comptime device mapping, already solid

These are the foundation. All existing and already proven. Cleanup means: DOD style, remove dead code, add any missing Tcl commands needed for real-world xschemrc files.

**Phase 2: Discovery (DepTree)**
- New file: `DepTree.zig`
- Depends on: XSchem.zig (parse to extract instance refs), XSchemRC (search paths)
- Delivers: file list, dependency DAG, topological order, classification
- Testable in isolation: give it a project dir, verify it finds all files

**Phase 3: Translation**
- New file: `Translator.zig` (replaces the 500+ line xschemToSchemify + helpers from old impl.zig)
- Depends on: XSchem.zig, map.zig, core.Schemify
- Delivers: XSchem struct -> Schemify struct
- Testable in isolation: convert one .sch, compare output Schemify struct

**Phase 4: Pipeline Orchestration**
- New file: `ProjectConverter.zig`
- Depends on: XSchemRC, DepTree, Translator, core.Writer
- Delivers: full project conversion (all stages)
- Testable: convert a project, verify all .chn files produced

**Phase 5: Config.toml + Output**
- Config.toml generation with glob patterns
- In-place file output (alongside originals)
- Verify Config.toml can be loaded by Schemify

**Phase 6: Plugin + CLI Entry Points**
- ABI v6 plugin wrapper (schemify_process)
- CLI argument parsing for batch mode
- GUI panel with progress bar

**Phase 7: Validation**
- Netlist roundtrip tests: XSchem netlist vs Schemify netlist from converted project
- Structural validation: instance count, wire count, pin count match

## How the Plugin ABI v6 Entry Point Wraps the Pipeline

The plugin entry point (`schemify_process`) is a thin wrapper. It translates between the binary message protocol and the conversion pipeline:

```
schemify_process(in_ptr, in_len, out_ptr, out_cap) -> usize
    |
    Reader.init(in_ptr[0..in_len])
    Writer.init(out_ptr[0..out_cap])
    |
    Message loop:
      .load -> {
          Store project_dir from event
          Allocate ConversionState
          w.registerPanel(...)
      }
      .draw_panel -> {
          if not started: show "Convert" button
          if converting: show progress (N/M files)
          if done: show results (file lists, errors)
      }
      .button_clicked (WID_CONVERT) -> {
          // Kick off conversion (synchronous in v1, could be async later)
          state.result = ProjectConverter.convert(state.project_dir, alloc)
          // Result is stored in state, displayed on next draw_panel
      }
    |
    return w.pos (or maxInt on overflow)
```

The conversion itself is synchronous within a single `schemify_process` call. For large projects (1000+ files), this could block the UI. A future enhancement could split conversion across multiple ticks using the `.tick` message, converting N files per tick.

**State management:**
```zig
const ConversionState = struct {
    project_dir: []const u8,
    phase: enum { idle, discovering, converting, done, failed },
    tree: ?DepTree,
    result: ?ConvertResult,
    progress: struct { current: u32, total: u32 },
    log_ring: [64]LogEntry,  // circular buffer for UI display
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *ConversionState) void {
        if (self.tree) |*t| t.deinit();
        if (self.result) |*r| r.deinit();
        self.arena.deinit();
    }
};
```

## Scalability Considerations

| Concern | Small project (10 files) | Medium project (100 files) | Large PDK (1000+ files) |
|---------|--------------------------|---------------------------|------------------------|
| Memory | Arena per file, ~1MB peak | Arena per file, ~5MB peak | Arena per file, ~5MB peak (same -- only one file in memory at a time) |
| Conversion time | <1s, synchronous fine | ~5s, synchronous tolerable | ~30s+, needs progress reporting; consider per-tick chunking |
| Disk I/O | Negligible | Moderate (200 files read+written) | Significant (2000+ files); batch writes |
| Discovery | Instant | <1s | 2-5s (recursive dir scan + parse for instance refs) |
| Dependency DAG | Trivial | Moderate depth (~10 levels) | Shallow for PDK (mostly leaves), deep for digital designs |

## Sources

All analysis derived from direct code inspection of:
- `plugins/EasyImport/.cache/src_old/XSchem/impl.zig` -- old pipeline implementation (2600+ lines)
- `plugins/EasyImport/.cache/src_old/XSchem/mod.zig` -- old backend interface
- `plugins/EasyImport/src/XSchem/impl.zig` -- current pipeline (same as cached, being rewritten)
- `plugins/EasyImport/src/XSchem/XSchem.zig` -- XSchem DOD parser
- `plugins/EasyImport/src/XSchem/XSchemRC.zig` -- xschemrc parser
- `plugins/EasyImport/src/TCL.zig` -- Tcl subset evaluator
- `plugins/EasyImport/src/XSchem/map.zig` -- device kind mapping
- `plugins/EasyImport/src/lib.zig` -- multi-backend entry (Runtime union)
- `src/core/Schemify.zig` -- target IR (DOD struct-of-arrays)
- `src/core/Types.zig` -- core schematic types
- `src/core/FileIO.zig` -- FileIO comptime backend pattern
- `src/core/Reader.zig` -- .chn format reader
- `src/core/Writer.zig` -- .chn format writer
- `src/core/Devices.zig` -- device kind enum and PDK model
- `plugins/EasyImport/docs/Page.md` -- spec document
- `.planning/PROJECT.md` -- project requirements
- `docs/Arch.md` -- .chn format specification
