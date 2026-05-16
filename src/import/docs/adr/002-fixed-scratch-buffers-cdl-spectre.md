# ADR-002: Fixed-Size Scratch Buffers in CDL/Spectre Parsers

## Status
Accepted (with known limitation)

## Context
`Virtuoso/oa.zig` parses CDL and Spectre netlists into `Subckt` structs containing ports, instances, nets, and parameters. The parser needs temporary storage during parsing before copying results to arena-allocated output.

Options:
1. **Dynamic ArrayLists** -- grow as needed, allocate from the arena.
2. **Fixed-size comptime arrays** -- bounded scratch buffers, no allocation during parse.
3. **Two-pass** -- first pass counts, second pass fills pre-sized arrays.

## Decision
Option 2: fixed-size scratch buffers. Current limits: 128 ports, 256 instances, 512 nets/pins, 256 params per subcircuit.

## Consequences

**Rationale:** CDL/Spectre parsing runs once per import, not in a hot loop. But the parser is called per-subcircuit, and foundry PDK files can contain thousands of subcircuits. Fixed buffers avoid per-subcircuit allocation overhead and keep the parser zero-alloc until the final copy-out step. The code is simpler: no error handling for intermediate allocations, no cleanup on parse errors.

**The problem:** Real foundry netlists can exceed these limits. A top-level chip integration subcircuit with 300+ instances will hit the 256-instance cap. When exceeded, the parser either silently truncates or panics (depending on the code path). This violates the project principle of narrow error sets and recoverable failures.

**Mitigation path:** The limits should be raised or replaced with `BoundedArray` that returns `error.Overflow` instead of panicking. The two-pass approach (option 3) would be ideal but doubles parse time for large files.

**Reversal cost:** Low. Changing buffer sizes is a one-line edit. Switching to dynamic allocation requires touching ~20 lines per buffer. The parser's output types (`Subckt`, `InstanceDef`) are arena-allocated slices, so the change is internal to the parser.
