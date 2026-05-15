# ADR-0001: Synchronous binary protocol over shared buffer

## Status: accepted

## Context

Plugins need to communicate with the host. Options considered:
1. Function-pointer vtable (plugin calls host functions directly)
2. Async message passing (channels, queues)
3. Synchronous binary protocol: host serializes messages into a flat buffer, calls a single `process(in_ptr, in_len, out_ptr, out_cap) -> out_len` function, deserializes the response

Option 1 couples plugin ABI to every host type (layouts, widgets, state structs). Option 2 requires threading or coroutines and complicates frame timing.

## Decision

Single-function synchronous binary protocol. The plugin exports one `process` function with C calling convention. The host owns both buffers. Messages use a `[u8 tag][u16 payload_len][payload]` framing. Plugin-to-host and host-to-plugin tags occupy disjoint ranges (0x01-0x14 vs 0x80-0xAE).

## Consequences

- **ABI surface is minimal**: one extern struct (`Descriptor`) with version + name + process pointer. Adding features means adding tags, not changing function signatures.
- **Deterministic**: no reentrancy, no threading concerns, no callback ordering issues. Plugin runs exactly when the host calls it.
- **WASM-portable**: the same `process` signature works for both native dlopen and a future WASM runtime.
- **Payload size capped at u16 (65535 bytes)**: large data (images, plots, file contents) can overflow. Writer sets an overflow flag and drops the message silently.
- **Latency**: every interaction is request-response within a single frame. Plugins cannot do async work or push unsolicited messages; they can only respond when called.
- **Output buffer retry**: if the plugin overflows its output buffer, the host doubles it (up to 64K) and retries once. This means `process` may be called twice per tick for the same input.
