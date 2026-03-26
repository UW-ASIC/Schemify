---
phase: 01-parser-foundation
plan: 01
subsystem: parser
tags: [zig, dod, xschem, tokenizer, arena-allocator, struct-of-arrays]

# Dependency graph
requires: []
provides:
  - "XSchem DOD types (Line, Rect, Arc, Circle, Wire, Text, Pin, Instance, Prop)"
  - "Schematic container with MultiArrayList storage and arena allocation"
  - "PropertyTokenizer for all XSchem property escaping variants"
  - "parseProps function for arena-backed property parsing"
affects: [01-02, 01-03, 01-04, phase-2, phase-3]

# Tech tracking
tech-stack:
  added: []
  patterns: [struct-of-arrays, arena-per-stage, free-functions-over-methods, DOD]

key-files:
  created:
    - plugins/EasyImport/src/XSchem/types.zig
    - plugins/EasyImport/src/XSchem/props.zig
    - plugins/EasyImport/src/XSchem/root.zig
    - plugins/EasyImport/test/test_props.zig
  modified: []

key-decisions:
  - "Free functions pinDirectionFromStr/pinDirectionToStr instead of enum methods per ARCH-04 DOD constraint"
  - "PropertyTokenizer returns raw slices (no allocation); parseProps handles escape processing and arena duplication"
  - "ArenaAllocator in tests matches real usage pattern (arena-per-stage) and avoids GPA leak detection noise"

patterns-established:
  - "DOD types: flat structs with no methods, free functions for behavior"
  - "Arena-per-stage: Schematic owns ArenaAllocator, single deinit tears down all memory"
  - "MultiArrayList for geometric element storage, ArrayListUnmanaged for props"
  - "Tokenizer/parser split: tokenizer is allocation-free, parser handles arena duplication"

requirements-completed: [ARCH-01, ARCH-02, ARCH-03, ARCH-04, PARSE-03]

# Metrics
duration: 5min
completed: 2026-03-26
---

# Phase 1 Plan 01: XSchem DOD Types and PropertyTokenizer Summary

**DOD struct-of-arrays types for all 9 XSchem element types plus PropertyTokenizer handling brace/backslash/quoted/single-quoted escaping with 14 passing tests**

## Performance

- **Duration:** 5 min
- **Started:** 2026-03-26T18:29:50Z
- **Completed:** 2026-03-26T18:34:45Z
- **Tasks:** 2
- **Files created:** 4

## Accomplishments
- All 9 XSchem element types (Line, Rect, Arc, Circle, Wire, Text, Pin, Instance, Prop) defined as flat DOD structs with no methods
- Schematic container using MultiArrayList for geometry and ArrayListUnmanaged for props, backed by arena-per-stage allocation
- PropertyTokenizer handles all 8 escaping rules: brace, quote, backslash, multi-line, single-quoted, bare, empty braces, name designator
- 14 test cases covering all specified edge cases plus additional boundary conditions, all passing

## Task Commits

Each task was committed atomically:

1. **Task 1: Create XSchem DOD types and Schematic container** - `d0fc628` (feat)
2. **Task 2: Create PropertyTokenizer (TDD RED)** - `79cf425` (test)
3. **Task 2: Implement PropertyTokenizer (TDD GREEN)** - `2cd0334` (feat)

_Note: Task 2 followed TDD cycle with separate RED and GREEN commits._

## Files Created/Modified
- `plugins/EasyImport/src/XSchem/types.zig` - All XSchem DOD element types, PinDirection enum, ParseError error set, free functions for direction conversion (146 lines)
- `plugins/EasyImport/src/XSchem/props.zig` - PropertyTokenizer struct and parseProps function with escape processing (213 lines)
- `plugins/EasyImport/src/XSchem/root.zig` - Public API module re-exporting types/props, Schematic container with MAL storage (82 lines)
- `plugins/EasyImport/test/test_props.zig` - 14 test cases for property tokenizer covering all escaping variants (162 lines)

## Decisions Made
- Used free functions (`pinDirectionFromStr`, `pinDirectionToStr`) rather than enum methods per ARCH-04 DOD constraint -- no methods on data types
- PropertyTokenizer returns raw slices without allocation; escape processing is deferred to `parseProps` which copies into the arena -- clean separation of tokenization from memory management
- Tests use ArenaAllocator backed by testing.allocator, matching the real arena-per-stage usage pattern and avoiding false-positive leak detection from GPA

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Known Stubs
None - all planned functionality is fully implemented.

## Next Phase Readiness
- types.zig and root.zig provide the data contracts that Plan 02 (XSchem reader) will parse into
- props.zig provides the PropertyTokenizer that Plan 02 will use for instance property parsing
- All files are under 400 lines, using arena allocators, with no OOP patterns

---
*Phase: 01-parser-foundation*
*Completed: 2026-03-26*
