# ADR-0003: Union-find net resolution rebuilt from scratch

## Status: accepted

## Context
Net connectivity must be resolved from wire endpoints and instance pin positions. Wires share a net when endpoints coincide or a T-junction is detected. The algorithm must handle arbitrary topologies including T-junctions on wire interiors.

## Decision
`resolveNets` uses a hash-map-based union-find on `u64` point keys (`(x << 32) | y`). It clears all net/conn data and rebuilds from scratch on every call. Wire net names provide user-assigned names; unnamed nets get auto-generated `netN` names.

## Consequences
- Correctness: full rebuild avoids incremental update bugs (stale merges, orphaned nets).
- Performance: O(W^2) for T-junction detection (every wire endpoint checked against every other wire's interior). Acceptable for typical schematic sizes (<1000 wires) but will not scale to very large flat designs.
- No incremental update: editing a single wire re-resolves all nets. A dirty flag for nets does not exist (only `prim_cache_dirty`).
- Net identity is ephemeral -- net IDs change between resolves. No persistent net handle survives an edit cycle.
