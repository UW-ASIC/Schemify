---
phase: 01-parser-foundation
plan: 03
subsystem: parser
tags: [tcl, evaluator, expression-parser, tokenizer, xschemrc]

requires:
  - phase: none
    provides: first implementation of Tcl evaluator

provides:
  - Tcl tokenizer (braces, quotes, variables, brackets, comments, backslash-newline continuation)
  - Tcl expression parser with eq/ne string comparison, arithmetic, logical, ternary operators
  - Tcl evaluator with variable table, command dispatch, source file loading with loop guard
  - Built-in commands (file, info, string, puts no-op, set, append, lappend, if/elseif/else)
  - Public API via Tcl struct (init/deinit/eval/getVar/setVar/setScriptPath)

affects: [01-04-xschemrc-parser, 02-dependency-discovery]

tech-stack:
  added: []
  patterns: [arena-per-evaluator, StaticStringMap-dispatch, segment-scanner-for-tcl-commands]

key-files:
  created:
    - plugins/EasyImport/src/TCL/tokenizer.zig
    - plugins/EasyImport/src/TCL/expr.zig
    - plugins/EasyImport/src/TCL/evaluator.zig
    - plugins/EasyImport/src/TCL/commands.zig
    - plugins/EasyImport/src/TCL/root.zig
    - plugins/EasyImport/test/test_tcl.zig
  modified: []

key-decisions:
  - "Split Tcl evaluator into 5 files (tokenizer, expr, evaluator, commands, root) instead of monolithic TCL.zig -- each under 400 lines"
  - "Moved parsing helpers (SegmentScanner, findMatchingBrace/Bracket, parseBlocks) into commands.zig to keep evaluator.zig under 400 lines"
  - "Used arena allocator per evaluator instance -- all string allocations go through arena, deallocated in bulk on deinit"
  - "Unsupported constructs (proc, switch, foreach, etc.) produce hard error with diagnostic -- fail fast, do not silently ignore"
  - "Source command uses visited-set loop guard to prevent infinite recursion when xschemrc files source each other"

patterns-established:
  - "Arena-per-evaluator: all intermediate strings allocated from evaluator's arena, bulk-freed on deinit"
  - "StaticStringMap dispatch: command lookup uses comptime-initialized StaticStringMap for O(1) dispatch"
  - "SegmentScanner: splits Tcl scripts into individual commands respecting brace/bracket/quote nesting"

requirements-completed: [PARSE-05]

duration: 9min
completed: 2026-03-26
---

# Phase 1 Plan 3: Tcl Subset Evaluator Summary

**Tcl subset evaluator with tokenizer, expression parser (eq/ne/arithmetic/ternary), variable substitution ($VAR/${VAR}/$env()), source file loading with loop guard, and full if/elseif/else control flow for sky130 xschemrc parsing**

## Performance

- **Duration:** 9 min
- **Started:** 2026-03-26T18:29:58Z
- **Completed:** 2026-03-26T18:38:44Z
- **Tasks:** 2
- **Files created:** 6

## Accomplishments
- Complete Tcl tokenizer handling braces (depth tracking), quotes (escape processing), variables ($name/${name}/$env(NAME)), bracket commands ([cmd] with nesting), comments (# at command position), and backslash-newline continuation
- Expression parser with full precedence chain: unary (!/-/+), multiplicative (*//%/), additive (+/-), comparison (</>/<=/>=), equality (==/!=/eq/ne), logical (&&/||), ternary (?:) -- eq/ne do string comparison critical for sky130 xschemrc
- Evaluator with StaticStringMap command dispatch, arena allocation, $VAR/${VAR}/$env(NAME) substitution, [cmd] bracket command evaluation
- Built-in commands: set/append/lappend, if/elseif/else with multi-line brace bodies, file (dirname/normalize/join/isdir/isfile/tail/extension), info (exists/script), string (equal/tolower/length/is), source with visited-set loop guard, puts as no-op
- 19 test cases covering all required constructs including edge cases

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Tcl tokenizer and expression parser** - `c781167` (feat)
2. **Task 2: Create Tcl evaluator, commands, root module, and tests** - `3d6c744` (feat)

## Files Created/Modified
- `plugins/EasyImport/src/TCL/tokenizer.zig` - Tcl tokenizer producing tokens from source text (279 lines)
- `plugins/EasyImport/src/TCL/expr.zig` - Tcl expression parser with arithmetic, comparison, string operators (397 lines)
- `plugins/EasyImport/src/TCL/evaluator.zig` - Core evaluator with variable table and command dispatch (385 lines)
- `plugins/EasyImport/src/TCL/commands.zig` - Built-in command implementations (file, info, string, source) and parsing helpers (217 lines)
- `plugins/EasyImport/src/TCL/root.zig` - Public API: Tcl struct with init/deinit/eval (34 lines)
- `plugins/EasyImport/test/test_tcl.zig` - 19 tests covering all required Tcl constructs

## Decisions Made
- Split old monolithic TCL.zig into 5 files with clear responsibilities per file, each under 400 lines per PITFALLS.md guidance
- Moved SegmentScanner and brace/bracket matching helpers into commands.zig to keep evaluator.zig within the 400-line budget
- Used arena allocator for all evaluator string storage -- simple bulk deallocation, no per-string tracking
- Unsupported Tcl constructs produce hard errors with diagnostic output rather than silent skip -- fail-fast ensures users know what is not supported
- Source command records visited file paths to prevent infinite recursion from circular source references in xschemrc chains

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Known Stubs
None - all functionality is fully wired.

## Next Phase Readiness
- Tcl evaluator is ready for use by plan 01-04 (XSchemRC parser)
- The evaluator handles all 15 constructs identified in RESEARCH as required for sky130 xschemrc
- build.zig module wiring for the new TCL directory structure will be done in plan 01-04

## Self-Check: PASSED

All 6 created files verified present. Both task commits (c781167, 3d6c744) verified in git log.

---
*Phase: 01-parser-foundation*
*Completed: 2026-03-26*
