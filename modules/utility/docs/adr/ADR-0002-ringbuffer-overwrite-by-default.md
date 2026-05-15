# ADR-0002: RingBuffer overwrites oldest on push by default

## Status: accepted

## Context

The RingBuffer is used for the command queue (`commands/Queue.zig`) and potentially for log buffering. Two behaviors are possible when the buffer is full: (a) silently overwrite the oldest entry, or (b) return an error / block.

The primary consumer is the command dispatch queue, where dropping the oldest unprocessed command is acceptable — the user will retry — and blocking the GUI thread is not.

## Decision

`push()` overwrites the oldest entry when full (no error, no indication). `tryPush()` is provided as the checked alternative that returns `error.Full`.

Capacity is comptime and must be a power of 2 (enforced by `comptime assert`). This enables bitmask indexing instead of modulo, which matters at the scale this buffer operates (small, hot, per-frame).

## Consequences

- Silent data loss on overflow via `push()`. Callers who care must use `tryPush()` or check `.full()` first. The overwrite-by-default name is surprising to users expecting the common convention where `push` fails and `force_push` overwrites.
- Power-of-2 constraint wastes up to ~50% of capacity for non-round sizes (e.g., wanting 5 slots requires allocating 8). Acceptable because all current uses choose round powers (4, 16, 64).
- No `clear()`, `reset()`, or iteration API. Consumers needing those must pop in a loop.
