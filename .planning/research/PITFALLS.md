# Domain Pitfalls: XSchem-to-Schemify Converter

**Domain:** EDA schematic format converter (XSchem -> Schemify .chn)
**Researched:** 2026-03-26
**Sources:** Old impl.zig (2713 lines), XSchem official docs, Schemify core types, PROJECT.md

---

## Critical Pitfalls

Mistakes that cause wrong netlists, silent data corruption, or architectural rewrites.

### Pitfall 1: The God-File Problem (2713-line impl.zig)

**What goes wrong:** The old impl.zig grew to 2713 lines with 5 "sections" that are actually tightly coupled phases sharing mutable state. Functions like `loadCompanionPins` (310 lines) and `xschemToSchemify` (270 lines) became impenetrable because every bug fix touched multiple sections and added special-case branches.

**Why it happens:** The conversion pipeline has real coupling between stages (e.g., pin ordering depends on format strings, which depend on symbol data, which depends on search path resolution). Developers respond by putting everything in one file "because it all talks to each other."

**Consequences:** Every XSchem edge case (bus pins, extra= ports, TCL generators, spice_sym_def reordering) adds 20-50 lines of interleaved logic. The file becomes unmaintainable and new bugs are introduced by fixes to adjacent code.

**Warning signs:**
- Any single file exceeding 500 lines
- Functions with more than 3 levels of nesting
- Multiple `var` declarations scattered through a function (mutable state accumulation)
- Comments like "Bug A fix", "Bug B fix", "Bug C fix" in loadCompanionPins (lines 1667-1909)

**Prevention:**
- Each pipeline stage is its own file with a clear input struct and output struct
- No stage mutates Schemify directly; instead, stages return typed intermediate results
- Pipeline composition happens in a single orchestrator function (under 100 lines) that chains: parse -> classify -> translate -> resolve_symbols -> write
- Maximum file length: 400 lines. If approaching 400, split by responsibility.

**Detection:** `wc -l *.zig` in CI. Any file over 400 lines triggers review.

**Which phase should address it:** Phase 1 (Architecture). Define the pipeline stages and their data contracts before writing any conversion logic.

**Old code anti-patterns to avoid:**
```
// BAD: impl.zig Section 3 mutates sify in-place across 5 nested functions
loadSymbolData(sify, dirs, sym, alloc);  // mutates sify.sym_data, sify.props, sify.pins
mergeTemplateDefaults(sify, alloc);       // mutates sify.props again
loadCompanionPins(sa, alloc, sym, sify);  // replaces sify.pins entirely

// GOOD: each stage returns new data, orchestrator assembles
const sym_data = resolveSymbols(instances, search_dirs, alloc);
const merged_props = mergeDefaults(instances, sym_data, alloc);
const pins = extractPins(sym_path, sym_data, alloc);
// Then build final Schemify from all resolved data
```

---

### Pitfall 2: Pin Ordering is the #1 Source of Wrong Netlists

**What goes wrong:** XSchem has at least 5 different pin ordering mechanisms that interact in subtle ways. Getting the order wrong produces a SPICE netlist where pin A's net is connected to pin B's terminal. The circuit simulates but gives completely wrong results with no obvious error message.

**Why it happens:** XSchem's pin ordering rules are underdocumented and evolved over 20+ years:
1. **B-box declaration order** -- pins from `P` lines in .sym, in file order
2. **sim_pinnumber** -- explicit numeric ordering attribute on each pin
3. **format string @@PIN order** -- when format uses `@@D @@G @@S @@B` instead of `@pinlist`
4. **spice_sym_def .subckt order** -- when spice_sym_def references an external .subckt, pin order comes from that definition
5. **@pinlist creation order** -- pins in the order they were created in the symbol editor
6. **.sch ipin/opin/iopin C-instance order** -- for .sch references, internal port positions

The old code has 3 separate sort functions: `sortPinsByNameOrder`, `sortPinsByNameOrderInsensitive`, and format-order walking in `loadCompanionPins`. Each was added to fix a specific test case. This ad-hoc approach means new XSchem files can still trigger wrong ordering.

**Consequences:** Silent wrong netlist. The SPICE simulation runs but produces garbage because, e.g., MOSFET drain and source are swapped.

**Warning signs:**
- Netlist roundtrip test fails: XSchem netlist != Schemify netlist
- More than one "sort pins" function existing
- Pin ordering logic split across multiple functions

**Prevention:**
- Single `PinOrderResolver` module that encodes the full priority chain:
  1. Check if spice_sym_def exists -> parse .subckt header for pin order
  2. Check if format has explicit @@PIN tokens -> use format-string walk order
  3. Check if sim_pinnumber attributes exist on all pins -> sort by sim_pinnumber
  4. Fallback: B-box declaration order (file order)
- This module is tested independently with known-good XSchem .sym files
- Every priority override is a documented, tested code path -- not a "fixup" added later

**Detection:** Netlist roundtrip test (XSchem netlist vs Schemify netlist from converted project) catches this immediately. This test must run on every change.

**Which phase should address it:** Phase 3 (Symbol resolution and pin extraction). Pin ordering must be correct before any netlist testing is possible.

**Old code anti-patterns to avoid:**
```
// BAD: Multiple sort functions, each fixing one case
sortPinsByNameOrder(sa, tmp_alloc, &pins, sym_pin_order.items);        // line 1346
sortPinsByNameOrderInsensitive(sa, tmp_alloc, &pins, spice_pin_order); // line 1563
// Plus 120 lines of format-string walking in loadCompanionPins

// GOOD: Single function, clear priority chain
const ordered_pins = PinOrderResolver.resolve(.{
    .bbox_pins = bbox_pins,
    .format_str = format_str,
    .spice_sym_def = spice_sym_def,
    .sim_pinnumbers = sim_pinnumbers,
});
```

---

### Pitfall 3: The Backend/Runtime Union Abstraction Trap

**What goes wrong:** The old code builds a `Runtime` tagged union dispatching between `XSchem.Backend` and `Virtuoso.Backend`, with comptime-checked interface conformance. This creates the illusion of polymorphism but adds indirection, makes debugging harder, and couples the XSchem implementation to an interface contract designed for a backend that doesn't exist yet (Virtuoso).

**Why it happens:** Developers anticipate future backends and design for extensibility upfront. In the EDA domain, there are many schematic formats (KiCad, Cadence, Altium), so it "feels right" to abstract.

**Consequences:**
- Every XSchem-specific function signature must satisfy the Backend interface (e.g., `convertFiles` takes generic `search_dirs` even though Virtuoso wouldn't have XSchem-style search paths)
- The Runtime union adds a `switch(self.*) { inline else => |*b| b.foo() }` dispatch at every call site -- 8 such dispatches in lib.zig/mod.zig
- The Virtuoso variant is `error.BackendNotImplemented` everywhere -- dead code that still constrains the API

**Warning signs:**
- Any union variant that returns `error.NotImplemented`
- `comptime` interface checks that enforce methods across backends when only one backend is being built
- More than 2 levels of indirection between entry point and actual logic

**Prevention:**
- Build XSchem conversion as a direct, standalone module. No trait, no union, no Backend struct.
- Entry point: `pub fn convert(project_dir, alloc) !ConvertResult`
- If Cadence Virtuoso support is added later, it gets its own module with its own entry point. The plugin can dispatch at the top level with a simple if/else.
- Follow YAGNI: the rewrite scope explicitly states "XSchem-only for v1"

**Detection:** Code review. If you see `union(SomeEnum)` with methods, ask "do we have 2+ real implementations today?"

**Which phase should address it:** Phase 1 (Architecture). The module boundary decision must be made before any code is written.

**Old code anti-patterns to avoid:**
```
// BAD (lib.zig): Runtime union with dispatch
pub const Runtime = union(BackendKind) {
    xschem: XS.Backend,
    virtuoso: Virtuoso.Backend,
    pub fn convertProject(self: *const Runtime, ...) !?ConvertResult {
        return switch (self.*) {
            .xschem => |*b| b.convertProject(...),
            .virtuoso => |_| error.BackendNotImplemented,  // dead code
        };
    }
};

// GOOD: Direct function, no indirection
pub fn convertProject(project_dir: []const u8, alloc: Allocator) !ConvertResult {
    // ... direct XSchem conversion logic
}
```

---

### Pitfall 4: XSchem Net Naming from Wire Labels vs Label Instances

**What goes wrong:** XSchem wires can have a `lab=` attribute (display annotation from the GUI) AND there can be `lab_pin.sym` / `ipin.sym` / `opin.sym` / `iopin.sym` instances that define authoritative net names. A naive converter uses wire `lab=` attributes for net naming, which causes disconnected wire segments with the same display label to appear as one net, or worse, overrides the true connectivity.

**Why it happens:** When `show_pin_net_names` is enabled in XSchem, the GUI writes `lab=VDD` onto wires touching VDD pins. This is a display convenience, not a connectivity declaration. But it looks like a net name in the parsed data.

**Consequences:** Nets that should be separate get merged (false short), or nets that should be named VDD get an auto-generated name. Both produce wrong simulation results.

**Warning signs:**
- Wires with `lab=` attributes being used for `net_name` in the Schemify wire
- Netlists showing unexpected net merging

**Prevention:**
- Strip `net_name` from ALL physical wires during translation (the old code correctly does this at line 133-137)
- Net names come ONLY from label instances: `vdd.sym`, `gnd.sym`, `lab_pin.sym`, `ipin.sym`, `opin.sym`, `iopin.sym`
- For each label instance, create a zero-length wire at the instance position with the authoritative net name
- Let `resolveNets()` (union-find on wire endpoints) handle the rest
- Document this rule prominently: "wire lab= is DISPLAY ONLY, label instances are AUTHORITATIVE"

**Detection:** Test case: schematic with `show_pin_net_names` enabled. Verify converted netlist matches XSchem netlist exactly.

**Which phase should address it:** Phase 2 (XSchem -> Schemify translation). This is a core data translation decision.

---

### Pitfall 5: The `extra=` Pin Filtering Problem

**What goes wrong:** XSchem's `extra=` property in a symbol's K block lists tokens that should be treated as additional pins on the .subckt interface. But NOT every token in `extra=` is a real pin -- some are template variables (like `prefix`, `modeln`, `modelp`) that happen to be listed there for parameter passing purposes. Treating them as pins adds bogus ports to the .subckt header.

**Why it happens:** The `extra=` attribute was designed for power pin inheritance (hidden VDD/VSS connections). But XSchem also uses it for parameter passing in some symbol styles. The only way to distinguish real pins from template variables is to check whether the token appears as `@TOKEN` (single-@, property substitution) in the format string, which means it is used in the SPICE line and therefore must be a port.

**Consequences:** Extra bogus pins in .subckt header cause LVS failures and simulation mismatches.

**Warning signs:**
- .subckt header contains tokens like `prefix` or `modeln` as ports
- Old code has 3 separate "Bug A/B/C fix" comments around extra= handling (lines 1667, 1701, 1904)

**Prevention:**
- Single predicate function: `isExtraTokenAPin(token, format_string) bool`
- Returns true only if the token appears as `@TOKEN` (single-@, not `@@`) in the format string
- Apply this filter consistently in ONE place, not scattered across multiple functions
- Test with sky130 symbols that use extra= for power pins (e.g., `sky130_fd_sc_hd__inv_1.sym`)

**Detection:** Compare .subckt headers between XSchem and converted netlists.

**Which phase should address it:** Phase 3 (Symbol resolution). The extra= filtering is part of pin extraction.

---

## Moderate Pitfalls

### Pitfall 6: Tcl Expression Evaluation in xschemrc

**What goes wrong:** Real-world xschemrc files use Tcl constructs beyond simple `set VAR value`: `[file dirname [info script]]`, `$env(HOME)`, conditional `if {[file isdir ...]}` blocks, and `expr` for math. A naive string-substitution parser handles only the simple cases and silently returns wrong paths for everything else.

**Why it happens:** xschemrc is a full Tcl script. The sky130 xschemrc uses `[file dirname [file normalize [info script]]]` to compute its own directory, conditional PDK_ROOT detection with fallback chains, and `append XSCHEM_LIBRARY_PATH` with colon separators.

**Prevention:**
- The old XSchemRC.zig parser handles basic `set` and `$var` expansion. Verify it handles:
  - `[file dirname ...]` and `[file normalize ...]` (path operations)
  - `$env(VAR)` (environment variable access)
  - `append VAR :value` (string append with separators)
  - `if {[file isdir ...]} { set ... }` (conditional blocks)
- If it doesn't handle all of these, implement them. They appear in every real xschemrc.
- Test with the actual sky130 xschemrc from xschem_sky130 repository

**Detection:** Parse the sky130 xschemrc and verify all lib_paths resolve to real directories.

**Which phase should address it:** Phase 1 or early Phase 2. Incorrect search paths cause all subsequent symbol resolution to fail.

---

### Pitfall 7: TCL Generator Symbols (.tcl scripts)

**What goes wrong:** XSchem supports symbols defined by Tcl scripts (e.g., `sky130_tests/res.tcl(@value\\)`). The script generates a .sym definition dynamically based on instance parameters. Without executing the script, the converter cannot know the symbol's pins or format string.

**Why it happens:** Some PDKs use parametric symbol generators for device variants.

**Prevention:**
- The old code (lines 487-613) shells out to `tclsh` to execute generator scripts. This is the correct approach but creates a runtime dependency.
- Treat this as an optional capability: if `tclsh` is available, execute generators; otherwise, classify as `.annotation` (non-electrical) and log a warning
- Do NOT block the entire conversion on a missing tclsh -- convert everything else first
- This is a later-phase concern; basic conversion works without it

**Detection:** Check if any instances reference `.tcl(` symbols. Log count of unresolved generators.

**Which phase should address it:** Phase 4 or later. This is an edge case that can be deferred.

---

### Pitfall 8: Flat Output Directory Collisions

**What goes wrong:** The old code writes ALL converted .chn files into a single `.temp_schemify/` directory. If two different XSchem libraries have a symbol with the same filename (e.g., `inv.sym` in both the project directory and a PDK library), the second write silently overwrites the first.

**Why it happens:** Using `std.fs.path.basename()` to derive output filenames loses directory structure information.

**Prevention:**
- Preserve relative directory structure in output. If the source is at `<lib_dir>/digital/inv.sym`, write to `.temp_schemify/digital/inv.chn_prim`
- Use the full relative path from the project root (or library root) as the output path
- Config.toml can use `**/*.chn` glob patterns as specified in the requirements

**Detection:** Test with a project that has same-named symbols in different directories.

**Which phase should address it:** Phase 4 (Project conversion pipeline). This is a file-output concern, not a data translation concern.

---

### Pitfall 9: Memory Allocation Strategy Mismatch

**What goes wrong:** The old code mixes two allocators (`alloc` and `sa = sify.alloc()` / arena allocator `ra`) throughout functions, making ownership unclear. Some data is allocated on temporary allocators and then referenced from long-lived structures. Other data is duplicated unnecessarily when it could share an arena.

**Why it happens:** Zig's explicit allocation requires careful ownership tracking. The old code evolved iteratively, and each fix added allocations without a clear ownership model.

**Warning signs in old code:**
- Functions taking both `alloc` and `sa` (or `tmp_alloc`) parameters
- `defer alloc.free(x)` followed later by `sa.dupe(u8, x)` -- double allocation for the same data
- `resolved_sym_owned` flag tracking whether a pointer needs freeing (line 67-84 of mod.zig)

**Prevention:**
- Each pipeline stage uses ONE arena allocator for all its output. The arena is owned by the stage's result struct.
- Temporary allocations within a stage use a scratch `ArenaAllocator` that is freed at stage end.
- No mixing of allocator ownership within a function. Clear rule: input data is borrowed (const slices), output data is owned by the result arena.
- DOD pattern: result structs own their arena; `deinit()` frees everything.

**Which phase should address it:** Phase 1 (Architecture). Define the allocator ownership model before writing code.

---

### Pitfall 10: type=label Symbols as Net Labels (Post-hoc Fixup)

**What goes wrong:** XSchem allows any symbol with `type=label` in its K block to act as a net label (same role as `lab_pin.sym`). During initial translation, these are classified as `.unknown` and become components. Only AFTER symbol data is loaded (a later pipeline stage) can we discover they are labels and retroactively add zero-length wires for net resolution.

The old code handles this in a "post-pass" (lines 694-721 of impl.zig) that re-scans all instances after symbol loading. This violates the pipeline model and creates a temporal coupling between stages.

**Prevention:**
- Make a two-phase classification:
  1. **Initial classification** by symbol filename (map.zig handles known symbols)
  2. **Refined classification** after symbol data is loaded (checks `type=` attribute from sym K block)
- The refined classification should produce a complete classification result before any Schemify IR is built
- This means: parse all .sym files first, classify all instances, THEN build the Schemify IR

**Which phase should address it:** Phase 2-3 (Translation + Symbol resolution). The pipeline order matters.

---

## Minor Pitfalls

### Pitfall 11: Backslash Escaping in XSchem Paths and Values

**What goes wrong:** XSchem uses `\\` in symbol paths (e.g., `sky130_fd_sc_hd\\__inv_1.sym`) and `\{` / `\}` in property values. Forgetting to unescape produces wrong file paths and wrong property values.

**Prevention:** Unescape functions exist in the old code (`unescapeBraces`, the `clean_sym_buf` loop). Consolidate into a single `unescape(input) -> output` utility. Apply it once at parse time, not scattered through translation.

**Which phase should address it:** Phase 2. Part of the translation layer.

---

### Pitfall 12: Conversion Triggering During draw_panel

**What goes wrong:** The old plugin code (line 2631-2634) triggers the full project conversion inside `draw_panel` on the first render. This blocks the UI thread for the entire conversion duration (potentially seconds for large projects).

**Prevention:** Conversion should be triggered by an explicit button click, not by first render. The draw_panel handler should only render current state. If background conversion is needed, use the ABI v6 message queue to defer work.

**Which phase should address it:** Phase 5 (Plugin UI). This is the last phase.

---

### Pitfall 13: Property Key/Value Field Name Mismatch

**What goes wrong:** XSchem's parsed `Prop` struct uses `.key` and `.value`, while Schemify's `Prop` struct uses `.key` and `.val`. The old code has two separate lookup functions (`findPropValue` vs `findSifyPropValue`) and it's easy to use the wrong one, causing silent failures where a property lookup returns null because the wrong field is accessed.

**Prevention:** Use a single prop-lookup utility that is generic over the struct type, or normalize property structs at the boundary between XSchem data and Schemify data.

**Which phase should address it:** Phase 2. Part of the translation layer data model.

---

### Pitfall 14: XSchem System Library Path Discovery

**What goes wrong:** The old code (mod.zig lines 156-248) probes for XSchem's share directory by spawning `sh -c "command -v xschem"`, parsing the output, walking up the directory tree, and falling back to `/usr/share/xschem`. This is brittle, slow (subprocess spawn), and fails in Nix/Guix environments where XSchem is in a non-standard prefix.

**Prevention:**
- Check `$XSCHEM_SHAREDIR` environment variable first (XSchem sets this when installed correctly)
- Check common paths: `/usr/share/xschem`, `/usr/local/share/xschem`, `$HOME/.nix-profile/share/xschem`
- Never spawn a subprocess for path discovery. If the share dir can't be found, warn and continue without system symbols.
- System symbols are a fallback; project/PDK symbols are primary.

**Which phase should address it:** Phase 1 or Phase 2. Search path resolution is foundational.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|---|---|---|
| Pipeline architecture | God-file accumulation (#1), Backend abstraction trap (#3) | Define stage boundaries and data contracts in Phase 1. No file over 400 lines. No polymorphism for single backend. |
| XSchem parsing | Already works (keep old XSchem.zig + XSchemRC.zig) | Clean up to match DOD style but do not rewrite. The parsers are proven. |
| Translation (XSchem -> Schemify) | Wire label vs label instance confusion (#4), backslash escaping (#11), property field mismatch (#13) | Strip wire lab=, label instances are authoritative. Single unescape utility. Normalize Prop structs at boundary. |
| Symbol resolution | Pin ordering (#2), extra= filtering (#5), type=label post-hoc fixup (#10) | Single PinOrderResolver with priority chain. Single isExtraTokenAPin predicate. Two-phase classification. |
| Project conversion | Tcl evaluation (#6), flat directory collisions (#8), memory allocation (#9) | Test with real sky130 xschemrc. Preserve directory structure. One arena per stage. |
| Plugin UI | Blocking conversion on draw (#12) | Conversion on button click only. |
| Testing / validation | All silent netlist errors | Netlist roundtrip test (XSchem vs Schemify) must run on every change. |

## Sources

- Old impl.zig: `/home/omare/Documents/UWASIC/Schemify/plugins/EasyImport/.cache/src_old/XSchem/impl.zig` (2713 lines, direct analysis)
- Old mod.zig: `/home/omare/Documents/UWASIC/Schemify/plugins/EasyImport/.cache/src_old/XSchem/mod.zig`
- Old lib.zig: `/home/omare/Documents/UWASIC/Schemify/plugins/EasyImport/.cache/src_old/lib.zig`
- Schemify core: `/home/omare/Documents/UWASIC/Schemify/src/core/Schemify.zig`
- [XSchem Symbol Property Syntax](https://xschem.sourceforge.io/stefan/xschem_man/symbol_property_syntax.html) -- format strings, extra=, type= attribute
- [XSchem Properties](https://xschem.sourceforge.io/stefan/xschem_man/xschem_properties.html) -- pin ordering, sim_pinnumber
- [XSchem Netlisting](https://xschem.sourceforge.io/stefan/xschem_man/netlisting.html) -- @pinlist, @@PIN, spice_sym_def
- [xschem_sky130 xschemrc](https://github.com/StefanSchippers/xschem_sky130/blob/main/xschemrc) -- real-world Tcl complexity
- [XSchem Tutorial: Use Existing Subckt](https://xschem.sourceforge.io/stefan/xschem_man/tutorial_use_existing_subckt.html) -- spice_sym_def and pin ordering
