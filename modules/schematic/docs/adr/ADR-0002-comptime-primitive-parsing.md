# ADR-0002: Comptime parsing of .chn_prim symbol definitions

## Status: accepted

## Context
Built-in symbols (resistor, nmos4, etc.) need geometry and pin positions for rendering and net resolution. Options: (a) hand-coded structs per device, (b) runtime file loading, (c) comptime parsing of a human-editable format.

## Decision
36 `.chn_prim` files are `@embedFile`'d and parsed at comptime into a `[36]PrimEntry` table. A second comptime pass builds LUTs (`prefix_lut`, `pins_lut`, etc.) indexed by `DeviceKind` enum ordinal.

## Consequences
- Zero runtime cost for primitive lookup -- all data is in `.rodata`.
- Adding a new primitive requires only a `.chn_prim` file and an entry in `embedded_files` -- no hand-coded struct.
- Comptime budget is large (`@setEvalBranchQuota(20_000_000)`) which slows initial compilation.
- Fixed-size arrays (`MAX_PINS=8`, `MAX_SEGS=48`) cap primitive complexity. Exceeding a limit silently truncates.
- The parser is a bespoke format, not TOML or JSON -- one more format to maintain.
