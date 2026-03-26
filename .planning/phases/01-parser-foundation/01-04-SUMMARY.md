---
phase: 01-parser-foundation
plan: 04
subsystem: parser
tags: [tcl, xschemrc, pdk, sky130, zig]

# Dependency graph
requires:
  - phase: 01-parser-foundation plan 01
    provides: DOD XSchem types and Schematic container
  - phase: 01-parser-foundation plan 02
    provides: .sch/.sym reader with PropertyTokenizer
  - phase: 01-parser-foundation plan 03
    provides: Tcl evaluator with variable substitution, if/else, source, file commands
provides:
  - XSchemRC parser (parseRc) that fully evaluates xschemrc through Tcl evaluator
  - RcResult struct with lib_paths, pdk_root, start_window, netlist_dir, project_dir
  - Colon-separated library path splitting and resolution
  - Graceful handling of source command failures (PDK not installed)
  - test_all.zig umbrella test wiring all 4 test modules
affects: [02-dependency-tree, 03-translation, pdk-conversion]

# Tech tracking
tech-stack:
  added: []
  patterns: [tcl-eval-first xschemrc parsing, arena-per-result ownership, inline test fixtures]

key-files:
  created:
    - plugins/EasyImport/src/XSchem/xschemrc.zig
    - plugins/EasyImport/test/test_xschemrc.zig
    - plugins/EasyImport/test/test_all.zig
    - plugins/EasyImport/examples/xschem_core_examples/xschemrc
    - plugins/EasyImport/examples/xschem_sky130/xschemrc
    - plugins/EasyImport/examples/sky130_schematics/xschemrc
  modified:
    - plugins/EasyImport/build.zig
    - plugins/EasyImport/src/XSchem/root.zig
    - plugins/EasyImport/src/TCL/evaluator.zig
    - plugins/EasyImport/src/TCL/commands.zig

key-decisions:
  - "Tcl-eval-first approach: evaluate entire xschemrc through Tcl evaluator then read resolved variables, not line-by-line pattern matching"
  - "Inline test fixtures instead of @embedFile for Zig 0.14 module boundary compatibility"
  - "Single test_all.zig umbrella test replaces per-file test steps in build.zig"
  - "Graceful error recovery: catch UnsupportedConstruct and all Tcl errors to allow partial evaluation"

patterns-established:
  - "Tcl-eval-first: xschemrc parsing runs full Tcl evaluation, then reads variable table"
  - "Arena-per-result: RcResult owns its ArenaAllocator, caller calls deinit()"
  - "Umbrella test: test_all.zig comptime-imports all test modules for single build step"

requirements-completed: [PARSE-04, PARSE-06]

# Metrics
duration: 6min
completed: 2026-03-26
---

# Phase 01 Plan 04: XSchemRC Parser Summary

**XSchemRC parser using full Tcl evaluation to extract library paths, PDK root, and config from real-world xschemrc files including sky130**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-26T19:18:22Z
- **Completed:** 2026-03-26T19:24:18Z
- **Tasks:** 2
- **Files modified:** 10

## Accomplishments
- XSchemRC parser (184 lines) that fully evaluates xschemrc through the Tcl evaluator and extracts lib_paths, pdk_root, start_window, netlist_dir
- 9 integration tests validating all 3 fixture xschemrc files (core_examples, xschem_sky130, sky130_schematics)
- Unified build.zig with test_all.zig umbrella wiring all 58 tests across 4 test modules
- Fixed bracket depth tracking bug in Tcl evaluator that prevented [command] substitution in bare words

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement XSchemRC parser using Tcl evaluator** - `b68b9d8` (feat)
2. **Task 2: Wire all new modules and tests into build.zig** - `4187b55` (chore)

## Files Created/Modified
- `plugins/EasyImport/src/XSchem/xschemrc.zig` - XSchemRC parser: parseRc, RcResult, seedDefaults, extractLibPaths
- `plugins/EasyImport/test/test_xschemrc.zig` - 9 integration tests for xschemrc parsing
- `plugins/EasyImport/test/test_all.zig` - Umbrella test importing all 4 test modules
- `plugins/EasyImport/examples/xschem_core_examples/xschemrc` - Core examples fixture
- `plugins/EasyImport/examples/xschem_sky130/xschemrc` - Sky130 PDK xschemrc fixture
- `plugins/EasyImport/examples/sky130_schematics/xschemrc` - Sky130 schematics fixture with source command
- `plugins/EasyImport/build.zig` - Simplified to single test_all.zig entry point with TCL->XSchem module wiring
- `plugins/EasyImport/src/XSchem/root.zig` - Added re-exports for parseRc and RcResult
- `plugins/EasyImport/src/TCL/evaluator.zig` - Fixed bracket depth tracking in parseAndExpand bare word scanner
- `plugins/EasyImport/src/TCL/commands.zig` - Fixed const-correctness in isDirExists for Zig 0.14

## Decisions Made
- **Tcl-eval-first approach:** Evaluate the entire xschemrc file through the Tcl evaluator, then read resolved variables from the variable table. This handles all real-world xschemrc complexity (nested if/else, variable expansion, bracket commands) that line-by-line pattern matching cannot.
- **Inline test fixtures:** Used Zig multiline string literals instead of @embedFile because Zig 0.14 module boundaries prevent embedding files from directories outside the test module's package path.
- **Single umbrella test:** Replaced 4 separate test build steps with one test_all.zig that comptime-imports all test modules, simplifying build.zig.
- **Graceful error recovery:** The parseRc function catches all Tcl evaluation errors (including UnsupportedConstruct for proc/switch) and continues with partial results, because the path-relevant variables are typically set before the DRC helper procs.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed bracket depth tracking in Tcl evaluator parseAndExpand**
- **Found during:** Task 1 (test compilation)
- **Issue:** The bare word scanner in `parseAndExpand` did not track bracket `[]` depth, causing `[command arg]` substitutions to be split across multiple words. This broke all bracket command tests and prevented the xschemrc parser from evaluating `[file dirname [info script]]`.
- **Fix:** Added `bracket_depth` tracking alongside existing `brace_depth` in the bare word scanner loop.
- **Files modified:** plugins/EasyImport/src/TCL/evaluator.zig
- **Verification:** All 19 Tcl tests pass (previously 9 failed), all 9 xschemrc tests pass.
- **Committed in:** b68b9d8 (Task 1 commit)

**2. [Rule 1 - Bug] Fixed const-correctness in isDirExists**
- **Found during:** Task 1 (test compilation)
- **Issue:** `isDirExists` in commands.zig declared `const dir` but `dir.close()` requires `*Dir` (mutable). Zig 0.14 enforces this.
- **Fix:** Changed `const dir` to `var dir`.
- **Files modified:** plugins/EasyImport/src/TCL/commands.zig
- **Verification:** Build compiles without errors.
- **Committed in:** b68b9d8 (Task 1 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs)
**Impact on plan:** Both fixes were necessary for correct compilation and test execution. No scope creep.

## Issues Encountered
- Zig 0.14 module boundary prevents @embedFile from reaching `../examples/` directory from test files -- resolved by using inline multiline string literals for fixture content.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Phase 01 parser foundation is complete: all 4 plans delivered
- XSchem types, reader, Tcl evaluator, and xschemrc parser are all wired and tested
- Ready for Phase 02 (dependency tree builder) which will use parseRc to discover library paths and then scan for .sch/.sym files

## Self-Check: PASSED

All 6 created files verified present on disk. Both commit hashes (b68b9d8, 4187b55) verified in git log.

---
*Phase: 01-parser-foundation*
*Completed: 2026-03-26*
