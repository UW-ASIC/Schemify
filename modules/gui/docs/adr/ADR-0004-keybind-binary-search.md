# ADR-0004: Comptime-Sorted Keybind Table with Binary Search

## Status: accepted

## Context

Keybind dispatch happens on every key press. The table has ~40 entries. Options: linear scan, hash map, or sorted array with binary search.

## Decision

Keybinds are defined as a comptime array of `Keybind` structs. At comptime, the array is sorted by a composite key `(key_enum << 3 | ctrl << 2 | shift << 1 | alt)` using insertion sort. Lookup uses `std.sort.binarySearch` with O(log 40) ~ 5 comparisons.

## Consequences

- Zero runtime allocation. The table is baked into the binary.
- Adding a keybind is a one-line addition to the `static_keybinds` array — no registration ceremony.
- The composite key packing means each `(key, ctrl, shift, alt)` combination maps to at most one action. Duplicate bindings are a silent comptime bug (last one wins after sort).
- Plugin keybinds use a separate linear scan over a dynamic list, not this table. The two systems are independent.
- User-configurable keybinds would require replacing this table with a runtime-populated structure. The current design is hardcoded.
