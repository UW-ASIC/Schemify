# utility

Leaf module. Zero internal dependencies. Provides logging, platform abstraction (native + WASM), and a fixed-capacity ring buffer. Consumed by every other module in the project.

## Public API

Exported through `lib.zig`:

| Export | Type | Description |
|--------|------|-------------|
| `Logger` | struct | Tagged logger with level filtering |
| `platform` | namespace | Filesystem, HTTP, directory helpers |
| `RingBuffer` | `fn(T, cap) type` | Comptime-sized overwriting ring buffer |

### Logger (Logger.zig)

| Symbol | Signature | Description |
|--------|-----------|-------------|
| `Level` | `enum(u2) { debug, info, warn, err }` | Log severity levels |
| `Level.label` | `fn(Level) []const u8` | Human-readable level name |
| `init` | `fn(Level) Logger` | Create logger with minimum level |
| `debug` | `fn(self, cat, fmt, args) void` | Emit debug message |
| `info` | `fn(self, cat, fmt, args) void` | Emit info message |
| `warn` | `fn(self, cat, fmt, args) void` | Emit warn message |
| `err` | `fn(self, cat, fmt, args) void` | Emit error message |

All log methods are `comptime cat` + `comptime fmt`. Output goes to stderr via `deprecatedWriter`. Messages below the configured level are no-ops.

### platform (platform.zig)

| Symbol | Signature | Description |
|--------|-----------|-------------|
| `fs` | `NativeFs` or `WasmFs` | Compile-time selected filesystem |
| `fs.cwd` | `fn() Dir` | Current working directory |
| `fs.stdout/stderr/stdin` | `fn() File` | Standard I/O handles |
| `httpGetSync` | `fn(Allocator, url) ![]u8` | Synchronous HTTP GET via curl (native only) |
| `pluginConfigDir` | `fn(Allocator) ![]u8` | Returns `$HOME/.config/Schemify` |
| `homeDir` | `fn() ?[]const u8` | Returns `$HOME` env var |

**NativeFs**: Thin wrappers around `std.fs`. File/Dir are `std.fs.File`/`std.fs.Dir`.

**WasmFs**: JS host VFS backed by IndexedDB. Provides `WasmDir` (readFileAlloc, writeFile, access, createFile, deleteTree, openDir, iterate) and `WasmFile` (writeAll, read, close). Uses 4 global file slots with 1 MB write buffers each. See ADR-0001.

### RingBuffer (RingBuffer.zig)

| Symbol | Signature | Description |
|--------|-----------|-------------|
| `RingBuffer` | `fn(T, cap) type` | Generic ring buffer; `cap` must be power of 2 |
| `.push` | `fn(*Self, T) void` | Push, overwriting oldest if full |
| `.tryPush` | `fn(*Self, T) error{Full}!void` | Push, error if full |
| `.pop` | `fn(*Self) ?T` | Pop oldest, null if empty |
| `.peek` | `fn(*const Self) ?T` | View oldest without removing |
| `.len` | `fn(*const Self) usize` | Current item count |
| `.full` | `fn(*const Self) bool` | Whether count == capacity |

No heap allocation. Stored inline. Uses bitmask indexing for O(1) push/pop.

## Internal Structure

| File | Lines | Role |
|------|-------|------|
| `lib.zig` | 9 | Re-exports; test runner |
| `Logger.zig` | 51 | Level-filtered stderr logger |
| `platform.zig` | 266 | Native/WASM fs, HTTP GET, directory helpers |
| `RingBuffer.zig` | 71 | Power-of-2 fixed-capacity ring buffer |

Total: ~397 LOC across 4 files.

## Dependencies

None. This is a leaf module.

**Depended on by:** schematic, simulation, commands, gui, cli, plugins, state, agent, marketplace (tests).

## Gaps

### Missing Features

Things a utility module for an EDA application would typically provide:

| Feature | Why useful |
|---------|-----------|
| **String interning** | Schematic data repeats net names, pin names, device types millions of times. An intern pool would cut memory and speed up comparisons. |
| **Arena pool / scratch allocator** | Reusable thread-local scratch arenas for per-frame or per-command transient allocations. Currently each caller manages its own. |
| **Memory tracking / stats** | Wrapping allocator that tracks peak usage, allocation counts, leak detection in debug builds. Essential for a long-running GUI app. |
| **Structured logging with sinks** | Current logger is stderr-only with no sink abstraction. No file logging, no ring-buffer log for in-app console, no JSON output for tooling. |
| **Profiling helpers** | Scoped timer / trace macros for measuring layout, render, netlist generation. Even a simple `defer scopeTimer("label")` pattern. |
| **Temp directory management** | Simulation and export create temp files. No centralized temp dir creation/cleanup. |
| **Configuration file watcher** | Settings module would benefit from inotify/kqueue-based file change detection. |
| **Crash reporting / panic handler** | Custom panic handler that dumps state (open file, last command, undo stack depth) before aborting. |
| **Thread pool** | Simulation, DRC, netlist generation are parallelizable. No shared thread pool exists. |
| **Async I/O helpers** | WASM fetch is async, native curl is blocking. A unified async-get abstraction would let callers not care. |

### API Issues

| Issue | Detail |
|-------|--------|
| **`Vfs` alias missing** | Multiple consumers import `utility.Vfs` but `lib.zig` does not export it. Likely a stale reference or a needed `pub const Vfs = platform.fs;` alias. Build may work if consumers use `utility.platform.fs` instead, but `Vfs` references will be broken imports. |
| **`deprecatedWriter` in Logger** | `std.fs.File.deprecatedWriter()` is a Zig stdlib deprecation shim. Will break on a future Zig version. Should switch to the current writer API. |
| **Logger not thread-safe** | `emit` writes to stderr without synchronization. Concurrent log calls from multiple threads can interleave mid-line. |
| **Logger has no `Writer` interface** | Cannot redirect log output to a buffer, file, or in-app console. Hardcoded to stderr. |
| **`httpGetSync` shells out to `curl`** | Assumes `curl` is on `$PATH`. No timeout, no retry, no status code reporting, no error detail. Fails silently on WASM. |
| **`httpGetSync` reads unbounded** | `readToEndAlloc` with `maxInt(usize)` limit. A malicious or broken server can OOM the process. |
| **WasmFs `openDir` returns dangling prefix** | `openDir` copies path into a stack-local `owned` buffer, then returns a `WasmDir` whose `.prefix` slice points at that now-dead stack frame. Use-after-return bug. |
| **WasmFs `iterate` uses `page_allocator`** | Allocates from page allocator but never frees (no `deinit` on iterator). Leaks on every directory listing. |
| **WasmFs `createFile` global mutable state** | 4 global `WasmFileSlot`s are not thread-safe and limit concurrent open files. |
| **`homeDir` is Linux/macOS only** | Returns `$HOME` via `std.posix.getenv`. No Windows `%USERPROFILE%` / `FOLDERID_Profile` fallback. |
| **`pluginConfigDir` hardcodes XDG path** | Uses `$HOME/.config/Schemify` directly instead of `$XDG_CONFIG_HOME`. Non-compliant with XDG Base Directory spec on Linux. |
| **No error types** | Module defines zero named error sets. `httpGetSync` uses `error.HttpRequestFailed` inline. No `UtilityError` or structured error reporting. |
| **RingBuffer naming** | `push` overwrites, `tryPush` errors. The silent-overwrite default is surprising; many ring buffer APIs make overwrite the explicit variant. |
| **No `clear` / `reset` on RingBuffer** | Cannot empty the buffer without popping every element. |
| **No `toSlice` / iteration on RingBuffer** | Cannot iterate contents without destructive pops. Useful for debug inspection. |
