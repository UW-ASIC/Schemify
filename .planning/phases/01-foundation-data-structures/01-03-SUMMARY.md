---
phase: 01-foundation-data-structures
plan: 03
subsystem: utility
tags: [zig, smallvec, perfect-hash, chd, gperf, comptime, data-structures]

requires:
  - phase: 01-01
    provides: SlotMap.zig (Handle, SlotMap, SecondaryMap)
  - phase: 01-02
    provides: SparseSet.zig, RingBuffer.zig, Pool.zig
provides:
  - SmallVec(T, N) inline+spill vector for small collections
  - PerfectHash comptime zero-collision lookup (gperf-style, <100 keys)
  - ChdHash comptime zero-collision lookup (CHD, larger key sets)
  - utility/lib.zig re-exports all 9 Phase 1 types
  - build.zig test_defs entry for `zig build test_utility`
affects: [phase-02-core-data-model, phase-03-state-queue, phase-05-commands]

tech-stack:
  added: [std.hash.Wyhash, std.mem.Allocator]
  patterns: [comptime-only hash tables, inline-to-heap spill, brute-force seed search, two-level hash-and-displace]

key-files:
  created:
    - src/utility/SmallVec.zig
    - src/utility/PerfectHash.zig
    - src/utility/lib.zig
  modified:
    - build.zig

key-decisions:
  - "SmallVec uses flat fields (heap_ptr/heap_cap/len) over tagged union for simplicity"
  - "PerfectHash stores parallel keys array for unknown-key rejection (no false positives)"
  - "ChdHash uses fixed seeds (0x517cc1b727220a95, 0x6c62272e07bb0142) and n/4 buckets"
  - "lib.zig includes existing pre-Phase-1 re-exports for merge compatibility"

patterns-established:
  - "Comptime-only data structures: no Allocator, all tables built at compile time"
  - "Inline-to-heap spill pattern: buf[N] inline, heap_ptr for overflow, double on grow"

requirements-completed: [DS-05, DS-06]

duration: 9min
completed: 2026-03-27
---

# Phase 01 Plan 03: SmallVec, PerfectHash, lib.zig Wiring Summary

**SmallVec inline+spill vector and PerfectHash comptime lookup (gperf + CHD), with all 9 Phase 1 types re-exported via utility module and build.zig test entry**

## Performance

- **Duration:** 9 min
- **Started:** 2026-03-27T22:27:26Z
- **Completed:** 2026-03-27T22:36:04Z
- **Tasks:** 3
- **Files modified:** 4

## Accomplishments
- SmallVec stores <=N items inline with zero heap allocation, spills to heap on overflow with double-capacity growth
- PerfectHash provides comptime-generated zero-collision lookup for small key sets via brute-force seed search
- ChdHash provides comptime-generated zero-collision lookup for larger key sets (51+ keys tested) via two-level hash-and-displace
- All 9 Phase 1 data structure types importable via `@import("utility")`
- build.zig wired for `zig build test_utility` -- 42 tests across all 6 data structure files

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement SmallVec** - `8b2a728` (feat) - TDD: 7 tests, 167 LOC
2. **Task 2: Implement PerfectHash** - `0143c73` (feat) - TDD: 5 tests, 247 LOC
3. **Task 3: Wire lib.zig and build.zig** - `6a949e6` (chore) - 9 re-exports + test block + test_defs entry

## Files Created/Modified
- `src/utility/SmallVec.zig` - Inline+spill vector: init, deinit, append, items, itemsMut, pop, get, clear, capacity
- `src/utility/PerfectHash.zig` - gperf-style PerfectHash + CHD ChdHash, both comptime-only
- `src/utility/lib.zig` - Re-exports all 9 Phase 1 types + test block importing all 6 files
- `build.zig` - Added utility test_defs entry for `zig build test_utility`

## Decisions Made
- SmallVec uses flat fields (heap_ptr, heap_cap, len) rather than a tagged union -- simpler code, works well with Zig's optional pointer semantics
- PerfectHash stores a parallel `keys` array alongside `vals` so unknown keys are properly rejected (no false positives from hash collisions)
- ChdHash uses fixed seeds for the two hash levels and n/4 buckets with insertion-sort for greedy largest-first bucket processing
- lib.zig includes the existing pre-Phase-1 re-exports (Logger, Vfs, platform, simd, UnionFind) to maintain merge compatibility with main branch
- SmallVec heap growth: double capacity starting at N*2 on first spill, using allocator.realloc for subsequent grows

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- Worktree does not contain pre-existing utility files (Logger.zig, Vfs.zig, etc.) since they are untracked in the main branch. lib.zig was created with all re-exports (both existing and new) for merge compatibility. Direct `zig test src/utility/lib.zig` was verified in the main repo context where all files exist (42/42 tests pass). The worktree-local verification was done per-file (`zig test src/utility/SmallVec.zig`, `zig test src/utility/PerfectHash.zig`).
- PerfectHash.zig initially came to 270 LOC; extracted shared CHD test entries as a constant to reduce to 247 LOC (under 250 budget).

## User Setup Required
None - no external service configuration required.

## Known Stubs
None.

## Next Phase Readiness
- All 6 foundation data structures complete: SlotMap, SparseSet, RingBuffer, Pool, SmallVec, PerfectHash
- Phase 1 success criteria satisfied: all files under 250 LOC, comprehensive tests, `@import("utility")` re-exports all types
- Ready for Phase 2 (Core Data Model: SlotMap for entities), Phase 3 (State: RingBuffer/SparseSet), Phase 5 (Commands: PerfectHash dispatch)

## Self-Check: PASSED

All files verified present on disk:
- src/utility/SmallVec.zig
- src/utility/PerfectHash.zig
- src/utility/lib.zig
- build.zig

All commits verified in git log:
- 8b2a728 (SmallVec)
- 0143c73 (PerfectHash)
- 6a949e6 (lib.zig + build.zig wiring)

---
*Phase: 01-foundation-data-structures*
*Completed: 2026-03-27*
