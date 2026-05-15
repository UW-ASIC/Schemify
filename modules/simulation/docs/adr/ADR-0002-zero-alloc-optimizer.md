# ADR-0002: Zero-allocation optimizer with fixed inline storage

## Status: accepted

## Context

The gm/Id optimizer needs to store problem definitions (transistors, specs), sweep observations, cubic spline knots, and results. The optimizer may run from the GUI hot path or from a plugin. Heap allocation in the optimizer would require an allocator parameter and complicate lifetime management.

## Decision

All optimizer types use fixed-capacity inline arrays:
- `FixedList(T, N)` replaces `std.BoundedArray` (removed in Zig 0.15).
- `CubicSpline` stores up to 1024 knots inline (`[1024]f64` x 3).
- `GmIdLookup` holds 6 splines inline (~150 KB per lookup).
- `SweepEngine` holds up to 16384 observations inline.
- `Problem` holds up to 64 transistors, 64 resistors, 64 parameters, 64 specs.

No function in `optimizer/` takes an `Allocator`.

## Consequences

- **No allocator needed.** Caller creates optimizer on stack or in an arena; no `deinit` required.
- **Predictable memory.** Total footprint is known at comptime.
- **Large stack frames.** `SweepEngine` is ~130 MB due to `[16384]Observation`. This will stack-overflow in default configurations. Must be heap-allocated by the caller or the limits must be reduced.
- **Hard capacity limits.** 64 design variables, 64 specs, 1024 LUT points. Exceeding them is a debug assert (release UB). No graceful error.
- **Serialization friction.** Fixed arrays with length fields don't map cleanly to JSON or other formats.
