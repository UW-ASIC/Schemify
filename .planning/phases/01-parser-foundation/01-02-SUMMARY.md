---
phase: 01-parser-foundation
plan: 02
subsystem: parser
tags: [xschem, zig, dod, parser, schematic, symbol]

requires:
  - phase: 01-parser-foundation-01
    provides: "DOD types (Line, Rect, Arc, Wire, Text, Pin, Instance, Prop), PropertyTokenizer, Schematic container"
provides:
  - "XSchem .sch/.sym file parser with tag-dispatch line parsing"
  - "Multi-line brace tracking for continuation blocks"
  - "K-block and G-block symbol property extraction"
  - "Pin creation from B layer-5 elements"
  - "Wire net_name extraction from lab= attribute"
  - "Instance property indexing via prop_start/prop_count"
  - "build.zig for EasyImport plugin test infrastructure"
affects: [01-parser-foundation-03, 01-parser-foundation-04, dependency-tree, xschem-conversion]

tech-stack:
  added: []
  patterns: [tag-dispatch, brace-depth-tracking, arena-per-parse, struct-of-arrays-append]

key-files:
  created:
    - plugins/EasyImport/src/XSchem/reader.zig
    - plugins/EasyImport/test/test_reader.zig
    - plugins/EasyImport/build.zig
  modified:
    - plugins/EasyImport/src/XSchem/root.zig
    - plugins/EasyImport/test/test_props.zig
    - plugins/EasyImport/test/test_tcl.zig

key-decisions:
  - "Inline test fixtures instead of @embedFile to avoid module boundary issues in Zig 0.14"
  - "Created build.zig for EasyImport enabling named module imports across test/src boundary"
  - "G-block parsing sets k_type and file_type=.symbol for backward compat with old XSchem format"
  - "Polygons (P tag) silently skipped -- deferred to Phase 4 per plan"

patterns-established:
  - "Tag-dispatch: switch on line[0] for element parsing, shared brace_depth accumulator for multi-line blocks"
  - "Module-based test imports via build.zig addModule/addImport instead of relative path @import"

requirements-completed: [PARSE-01, PARSE-02]

duration: 10min
completed: 2026-03-26
---

# Phase 01 Plan 02: XSchem Reader Summary

**Tag-dispatch .sch/.sym parser (316 lines) parsing all 7 element types into DOD Schematic with multi-line brace tracking, K/G-block extraction, and strict ParseError returns**

## Performance

- **Duration:** 10 min
- **Started:** 2026-03-26T18:33:24Z
- **Completed:** 2026-03-26T18:44:15Z
- **Tasks:** 1 (TDD: RED + GREEN)
- **Files modified:** 6

## Accomplishments
- XSchem .sch/.sym parser handles all element types: L (lines), B (rects/pins), A (arcs), T (text), N (wires), C (components)
- K-block and G-block property extraction for .sym files (type, format, template, extra)
- Multi-line brace-depth tracking prevents misparse of continuation blocks in C, T, N, K, G elements
- B layer-5 creates Pin entries with name, direction, pinnumber from attributes
- Instance properties indexed via prop_start/prop_count into flat Schematic.props array
- 16 passing tests covering all element types, file type detection, multi-line props, error handling
- Created build.zig for EasyImport enabling proper module-based test infrastructure

## Task Commits

Each task was committed atomically (TDD):

1. **Task 1 RED: Failing tests for XSchem reader** - `a7b8a66` (test)
2. **Task 1 GREEN: Implement tag-dispatch parser** - `3f178c3` (feat)

## Files Created/Modified
- `plugins/EasyImport/src/XSchem/reader.zig` - Tag-dispatch .sch/.sym parser (316 lines)
- `plugins/EasyImport/test/test_reader.zig` - 16 tests for reader covering all behaviors
- `plugins/EasyImport/build.zig` - Build system with xschem/tcl modules and test steps
- `plugins/EasyImport/src/XSchem/root.zig` - Added re-export of `parse` from reader.zig
- `plugins/EasyImport/test/test_props.zig` - Updated imports to use `xschem` named module
- `plugins/EasyImport/test/test_tcl.zig` - Updated imports to use `tcl` named module

## Decisions Made
- Used inline test fixtures (comptime string literals) instead of `@embedFile` to avoid Zig 0.14 module boundary restrictions that prevent embedding files outside the package path
- Created build.zig for the EasyImport plugin, establishing the pattern for all future test runs (`zig build test` from plugin directory)
- G-block parsing extracts type/format/template and sets file_type=.symbol, maintaining backward compatibility with old XSchem format files (e.g., nand2.sym uses G instead of K)
- Polygons (P tag) are silently skipped per plan -- deferred to Phase 4 for geometry handling

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Created build.zig for EasyImport plugin**
- **Found during:** Task 1 RED (test compilation)
- **Issue:** Zig 0.14 does not allow `@import` of files outside the module path; test files in `test/` cannot import `../src/` with relative paths, and existing tests (test_props.zig, test_tcl.zig) also had broken imports
- **Fix:** Created `plugins/EasyImport/build.zig` with named modules (xschem, tcl) and test steps. Updated all test files to use named module imports.
- **Files modified:** plugins/EasyImport/build.zig, test/test_reader.zig, test/test_props.zig, test/test_tcl.zig
- **Verification:** `zig build test` runs 30/30 reader+props tests passing
- **Committed in:** a7b8a66 (RED phase commit)

**2. [Rule 3 - Blocking] Used inline fixtures instead of @embedFile**
- **Found during:** Task 1 RED (test compilation)
- **Issue:** `@embedFile` with paths outside module boundary rejected by Zig 0.14 compiler ("embed of file outside package path")
- **Fix:** Created inline comptime string fixtures in test_reader.zig with representative XSchem content covering all element types, multi-line blocks, K/G blocks, and error cases
- **Files modified:** plugins/EasyImport/test/test_reader.zig
- **Verification:** All 16 tests pass with inline fixture data
- **Committed in:** a7b8a66 (RED phase commit)

---

**Total deviations:** 2 auto-fixed (2 blocking)
**Impact on plan:** Both fixes were necessary to make tests compilable. The build.zig is a positive addition that benefits all EasyImport tests.

## Issues Encountered
- Pre-existing TCL test compilation error (`*const fs.Dir` vs `*fs.Dir` in commands.zig:125) -- out of scope for this plan, logged to deferred items

## Known Stubs
None -- all parser functionality is fully implemented, no placeholder data.

## Next Phase Readiness
- Reader is complete and tested, ready for dependency tree builder (Plan 04) which will use `parse()` to load and analyze .sch/.sym files
- Root.zig re-exports `parse` making it available as `xschem.parse()` for downstream consumers
- The TCL evaluator (Plan 03, already complete) can be combined with the reader to resolve xschemrc paths and then parse discovered files

## Self-Check: PASSED

All files exist, all commits verified:
- `plugins/EasyImport/src/XSchem/reader.zig` - FOUND
- `plugins/EasyImport/test/test_reader.zig` - FOUND
- `plugins/EasyImport/build.zig` - FOUND
- `plugins/EasyImport/src/XSchem/root.zig` - FOUND
- Commit `a7b8a66` (test RED) - FOUND
- Commit `3f178c3` (feat GREEN) - FOUND

---
*Phase: 01-parser-foundation*
*Completed: 2026-03-26*
