# ADR-0001: SoA via MultiArrayList for all schematic elements

## Status: accepted

## Context
Schematic elements (instances, wires, geometry) are iterated in tight loops during rendering, hit-testing, net resolution, and bounding-box computation. Each loop typically touches only 2-3 fields out of 6-10. AoS layout (e.g., `ArrayList(Instance)`) pulls entire cache lines of untouched fields.

## Decision
All element collections in `Schemify` use `std.MultiArrayList(T)`. Properties, connections, nets, and other variable-length metadata use `ArrayListUnmanaged` (AoS) because they are accessed by slice range, not iterated field-by-field.

## Consequences
- Hot loops (bounds, resolve, render) iterate packed field slices -- better cache utilization for 200-2000 element counts typical in schematics.
- Random element access requires `.get(idx)` which reconstructs the full struct -- acceptable since single-element access is not a hot path.
- `swapRemove` is the only O(1) deletion strategy, which invalidates the last element's index. Callers must handle index invalidation (currently not fully correct for `prop_start`/`conn_start`).
- Adding a field to a type does not change the memory layout of other fields -- good for incremental evolution.
