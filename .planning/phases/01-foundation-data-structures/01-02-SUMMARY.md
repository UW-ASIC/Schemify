---
phase: 01-foundation-data-structures
plan: 02
subsystem: utility
tags: [sparse-set, ring-buffer, pool-allocator, dod, zig, comptime, data-structures]

# Dependency graph
requires:
  - phase: 01-01
    provides: "SlotMap + Handle + SecondaryMap (style reference for utility/ convention)"
provides:
  - "SparseSet generic container (O(1) add/remove/contains, O(k) dense iteration)"
  - "RingBuffer generic container (O(1) push/pop, power-of-two branchless FIFO)"
  - "Pool fixed-size block allocator (O(1) alloc/free via intrusive free list)"
affects: [01-03, 03-selection, 03-command-queue, 05-undo-history]

# Tech tracking
tech-stack:
  added: []
  patterns: [comptime-sized-containers, intrusive-free-list, two-array-sparse-set, unbounded-head-tail-ring]

key-files:
  created:
    - src/utility/SparseSet.zig
    - src/utility/RingBuffer.zig
    - src/utility/Pool.zig
  modified: []

key-decisions:
  - "SparseSet uses ArrayListUnmanaged for both dense and sparse arrays (matches SlotMap convention)"
  - "RingBuffer and Pool are comptime-sized with no Allocator (fixed capacity inline arrays)"
  - "Pool uses @ptrCast between *T and *FreeNode for intrusive free list (comptime assertion guards @sizeOf)"

patterns-established:
  - "Comptime-only containers: RingBuffer(T, capacity) and Pool(T, max_count) need no allocator"
  - "Intrusive free list: reinterpret unused block memory as FreeNode linked list"
  - "Two-array membership: dense[sparse[id]] == id with sentinel gap-fill"

requirements-completed: [DS-02, DS-03, DS-04]

# Metrics
duration: 4min
completed: 2026-03-27
---

# Phase 01 Plan 02: SparseSet, RingBuffer, and Pool Summary

**Three DOD data structures: O(1) SparseSet with dense iteration, power-of-two RingBuffer, and intrusive-free-list Pool allocator**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-27T22:11:26Z
- **Completed:** 2026-03-27T22:15:26Z
- **Tasks:** 3
- **Files created:** 3

## Accomplishments
- SparseSet with O(1) add/remove/contains/isEmpty/count and O(k) denseSlice iteration (163 LOC, 8 tests)
- RingBuffer with O(1) push/pop, pushOverwrite eviction, power-of-two branchless wrap (143 LOC, 6 tests)
- Pool allocator with O(1) alloc/free via intrusive free list, comptime-sized (123 LOC, 6 tests)

## Task Commits

Each task was committed atomically (TDD: tests written first, then implementation):

1. **Task 1: Implement SparseSet** - `dcb053f` (feat)
2. **Task 2: Implement RingBuffer** - `9b7d771` (feat)
3. **Task 3: Implement Pool allocator** - `c798932` (feat)

## Files Created/Modified
- `src/utility/SparseSet.zig` - Two-array sparse set: dense packed IDs + sparse index array with sentinel gap-fill
- `src/utility/RingBuffer.zig` - Power-of-two FIFO ring buffer with unbounded head/tail and mask-on-index
- `src/utility/Pool.zig` - Fixed-size block allocator with intrusive FreeNode linked list

## Decisions Made
- SparseSet uses `std.ArrayListUnmanaged(u32)` for both dense and sparse arrays, matching the SlotMap convention
- RingBuffer and Pool are comptime-sized inline arrays with no Allocator (matches CONTEXT.md "caller-provided memory or comptime-sized buffers")
- Pool uses `@ptrCast`/`@alignCast` between `*T` and `*FreeNode` with a comptime `@sizeOf` guard
- SparseSet clear() is O(1) by just resetting dense.items.len -- stale sparse entries handled by contains() check

## Deviations from Plan

None - plan executed exactly as written.

## Known Stubs

None - all three data structures are fully functional with no placeholder code.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- All three data structures ready for consumption by Phase 3 (Selection uses SparseSet, CommandQueue uses RingBuffer) and Phase 5 (undo snapshots use Pool)
- Still need Plan 03 (SmallVec + PerfectHash) to complete the Phase 01 data structure set
- lib.zig re-exports not yet wired (will be done when all utility files exist)

## Self-Check: PASSED

- All 3 created files exist
- All 3 commit hashes verified in git log
- All 20 tests pass (8 + 6 + 6)
- All files under 250 LOC (163 + 143 + 123 = 429 total)

---
*Phase: 01-foundation-data-structures*
*Completed: 2026-03-27*
