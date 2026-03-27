---
phase: 01-foundation-data-structures
plan: 01
subsystem: utility
tags: [slotmap, generational-handles, ecs, data-structures, zig]

requires:
  - phase: none
    provides: first data structure in utility/

provides:
  - Handle (packed u32: 20-bit index + 12-bit generation)
  - SlotMap(T) dense variant with O(1) insert/remove/lookup
  - SecondaryMap(T) companion container with generation-checked access

affects: [02-sparse-set, 03-ring-buffer-pool, core-data-model, commands-undo]

tech-stack:
  added: []
  patterns: [dense-slotmap-swap-remove, generational-handle-aba-safety, secondary-map-sparse-parallel-array]

key-files:
  created:
    - src/utility/SlotMap.zig
  modified: []

key-decisions:
  - "Dense parallel array variant for SecondaryMap (simpler, fits 250 LOC budget)"
  - "Generation starts at 1 so Handle.invalid (gen=0) never matches a live slot"
  - "Free list sentinel is maxInt(u20) with ?u20 free_head for end-of-list"
  - "SecondaryMap stale handle test uses reinsert pattern (not just remove) to demonstrate generation mismatch"

patterns-established:
  - "Packed u32 Handle with 20/12 bit split for index/generation"
  - "std.ArrayListUnmanaged for all internal growable arrays (no hand-rolled growth)"
  - "Wrapping generation increment (+%=) for 4096-cycle wrap safety"

requirements-completed: [DS-01]

duration: 6min
completed: 2026-03-27
---

# Phase 01 Plan 01: SlotMap Summary

**Dense SlotMap with packed u32 generational handles and SecondaryMap companion in 246 LOC**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-27T21:50:31Z
- **Completed:** 2026-03-27T21:56:22Z
- **Tasks:** 2
- **Files created:** 1

## Accomplishments
- Handle packed struct (4 bytes) with eql, toRaw/fromRaw, invalid constant
- Dense SlotMap(T) with sparse-dense indirection, swap-remove, free list slot reuse
- SecondaryMap(T) with generation-checked sparse parallel array
- 9 test blocks covering all behaviors (handle basics, insert/remove, swap-remove back-refs, slot reuse, generation wrap, getPtr mutation, contiguity, secondary map stale rejection)

## Task Commits

Each task was committed atomically (TDD: RED then GREEN):

1. **Task 1: Handle + Dense SlotMap(T)**
   - `93b0dd4` (test: failing tests for Handle + Dense SlotMap - TDD RED)
   - `e94d578` (feat: implement Handle + Dense SlotMap with generational safety - TDD GREEN)

2. **Task 2: SecondaryMap(T)**
   - `4776c8f` (test: failing tests for SecondaryMap - TDD RED)
   - `c9bb878` (feat: implement SecondaryMap + refactor to 246 LOC - TDD GREEN)

## Files Created/Modified
- `src/utility/SlotMap.zig` - Handle, SlotMap(T), SecondaryMap(T) with 9 test blocks (246 LOC)

## Decisions Made
- Dense parallel array variant for SecondaryMap (simpler than hash-based, fits LOC budget, matches primary SlotMap's sparse array pattern)
- Generation starts at 1 for newly created slots, so Handle.invalid (index=0, gen=0) never matches a live slot
- Free list uses maxInt(u20) as sentinel with ?u20 free_head for clean end-of-list detection
- SecondaryMap stale handle detection works via generation mismatch after slot reuse (not via primary SlotMap reference)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed SecondaryMap stale handle test logic**
- **Found during:** Task 2 (SecondaryMap GREEN phase)
- **Issue:** Original test expected sec.get(h) to return null after sm.remove(h), but SecondaryMap has no reference to primary -- stored generation still matches old handle
- **Fix:** Changed test to verify stale rejection via reinsert pattern: remove + reinsert gives new handle with bumped generation, SecondaryMap correctly rejects new handle against old entry
- **Files modified:** src/utility/SlotMap.zig (test block)
- **Verification:** All 9 tests pass
- **Committed in:** c9bb878

---

**Total deviations:** 1 auto-fixed (1 bug in test specification)
**Impact on plan:** Test now correctly validates SecondaryMap's actual stale handle rejection mechanism. No scope creep.

## Issues Encountered
- nix develop shell fails (SDL3 package missing from nixpkgs) -- worked around by using Zig 0.15.2 binary directly from nix store at `/nix/store/9ljn49hx3a2lhha1anl3agivwb3z0ga1-zig-0.15.2/bin/zig`
- Worktree does not have src/utility/ directory (only exists as untracked in main repo) -- created it in worktree

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- SlotMap.zig is self-contained with comprehensive tests, ready for lib.zig re-export wiring
- Handle type is the foundation for all subsequent entity storage (instances, wires, pins)
- SecondaryMap enables optional per-entity data (selection flags, plugin metadata) in later phases

## Self-Check: PASSED

- [x] src/utility/SlotMap.zig exists (246 LOC)
- [x] Commit 93b0dd4 found (TDD RED - Task 1)
- [x] Commit e94d578 found (TDD GREEN - Task 1)
- [x] Commit 4776c8f found (TDD RED - Task 2)
- [x] Commit c9bb878 found (TDD GREEN - Task 2)
- [x] All 9 tests pass via zig test

---
*Phase: 01-foundation-data-structures*
*Completed: 2026-03-27*
