# ADR-0001: Duck-typed model parameter in emitSpice/emitPySpice

## Status: accepted

## Context

`Netlist.emitSpice` needs access to the full `Schemify` model (instances MAL, pins MAL, props, conns, nets, sym_props, sym_data, etc.). However, `Schemify.zig` lives in the `schematic` module and itself imports `simulation` for `SpiceIF.Value`. A direct import of `Schemify` from `Netlist.zig` would create a circular dependency: `schematic -> simulation -> schematic`.

## Decision

`emitSpice` and `emitPySpice` accept `model: anytype` and access fields structurally. The comment on line 28 states: "This is intentionally a free function to avoid the circular import."

## Consequences

- **Circular dep avoided.** `simulation` depends on `schematic.types` and `schematic.devices` (leaf types), not on `Schemify` itself. Build graph stays acyclic.
- **No compile-time contract.** If `Schemify` renames a field, the error surfaces as a cryptic "no such field" deep inside `emitSpice`, not at the call site.
- **Not discoverable.** The required field layout is documented only in comments, not enforced by a type.
- **Mitigation path.** A `SchematicView` interface struct (read-only slices of the fields `emitSpice` needs) could replace `anytype` without introducing the circular dep. This is future work.
