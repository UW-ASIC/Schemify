# ADR-0004: Circular dependency between schematic and simulation

## Status: accepted (technical debt)

## Context
`Schemify.emitSpice()` needs `simulation.Netlist` to generate SPICE netlists. `Devices.zig` re-exports `simulation.SpiceIF.Value` and related types. Meanwhile, `simulation` imports `schematic` for all domain types. This creates a build-level circular dependency.

## Decision
Both modules list each other as build dependencies in `build.zig`. Zig's module system handles this because the imports resolve to concrete types without initialization-order issues.

## Consequences
- Works in practice with Zig 0.15.2 but couples two modules that should have a unidirectional relationship.
- `Schemify` has a method (`emitSpice`) that belongs in the simulation layer. It is a convenience shortcut that leaks the simulation concern into the domain model.
- `Devices.zig` re-exports SPICE types (`Value`, `SpiceComponent`, `ParamOverride`, `emitComponent`), making the device catalog depend on the simulation wire format.
- To break the cycle: move `emitSpice` to a caller-side function, and have `Devices.zig` define its own value types that simulation maps from.
