# utility

Cross-cutting infrastructure used by all modules.

## Responsibility

- Logger: tagged logging with level filtering
- Platform: filesystem abstraction (native + WASM VFS), home/plugin config dirs, HTTP GET
- RingBuffer: lock-free ring buffer for cross-thread communication

## Boundaries

- Leaf module: zero internal dependencies
- Small, stable API surface

## Key Files

| File | Purpose |
|------|---------|
| `lib.zig` | Public API re-exports |
| `Logger.zig` | Tagged logger |
| `platform.zig` | OS/FS/HTTP helpers |
| `RingBuffer.zig` | Lock-free ring buffer |
