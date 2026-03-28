# utility module architecture

This directory contains the shared support layer used across `src/core`, `src/plugins`, `src/commands`, and app state code.

## Public surface (`src/utility/lib.zig`)

- `Logger` -> `Logger.zig`
- `Vfs` -> `Vfs.zig`
- `platform` -> `Platform.zig`
- `simd` -> `Simd.zig`
- `UnionFind` -> `UnionFind.zig`

## Utilities

### `Logger.zig`

Fixed-capacity in-memory log ring (`Logger`) with level gating and optional native stderr mirroring.

- No allocator usage after init.
- Used by: app state, CLI, parser/writer flows, plugin runtime.
- Internal deps: `std`, `builtin`.

### `Vfs.zig`

Platform-agnostic filesystem API (`Vfs`) with native `std.fs` backend and wasm host-import backend.

- Primary operations used by the app: `readAlloc`, `writeAll`, `exists`, `makePath`, `isDir`, `listDir`.
- `listDir` returns `DirList` with ownership of both backing byte buffer and entry slice array.
- Internal deps: `std`, `builtin`.

### `Platform.zig`

Host/platform abstraction used for environment, process, URL, and HTTP integration.

- Compile-time backend select (`native` vs `wasm`) through exported aliases.
- Internal deps: `std`, `builtin`.
- Used by: plugin installer/runtime through `utility.platform` and `PluginIF.platform`.

### `Simd.zig`

SIMD-accelerated text helpers for hot parse/write paths.

- `findByte`: 16-byte vectorized byte search.
- `LineIterator`: low-overhead newline iterator used by CHN reader.
- `estimateCHNSize`: writer pre-allocation heuristic.
- Internal deps: `std`.

### `UnionFind.zig`

Disjoint-set union structure (`UnionFind`) backed by `std.AutoHashMapUnmanaged(u64, u64)`.

- Methods: `find`, `makeSet`, `unite`.
- Used by: connectivity/net building in `src/core/Schemify.zig`.
- Internal deps: `std`.

## Dependency relationships

### Internal imports

- `lib.zig` -> `Logger.zig`, `Vfs.zig`, `Platform.zig`, `Simd.zig`, `UnionFind.zig`
- `Logger.zig` -> `std`, `builtin`
- `Vfs.zig` -> `std`, `builtin`
- `Platform.zig` -> `std`, `builtin`
- `Simd.zig` -> `std`
- `UnionFind.zig` -> `std`

### External module usage

- `utility.Logger` used by: `src/state.zig`, `src/cli.zig`, core command/runtime paths.
- `utility.Vfs` used by: `src/state.zig`, `src/core/*`, `src/commands/*`, `src/plugins/*`, `src/toml.zig`.
- `utility.platform` used by: `src/plugins/installer.zig`, `src/PluginIF.zig` (and plugin runtime via PluginIF).
- `utility.simd` used by: `src/core/Reader.zig`, `src/core/Writer.zig`.
- `utility.UnionFind` used by: `src/core/Schemify.zig`.

## Removed as unused (verified)

The following utilities were removed because there are no references from other modules under `src/`:

- `SlotMap.zig`
- `SparseSet.zig`
- `RingBuffer.zig`
- `Pool.zig`
- `SmallVec.zig`
- `PerfectHash.zig`

Verification method: repository-wide grep in `src/` for symbol and file references.
