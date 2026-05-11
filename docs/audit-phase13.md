# Phase 13 - Code Quality Audit: Plugin API v1

**Date:** 2026-05-10
**Auditor:** Claude Opus 4.6
**Build status:** PASS (Zig 0.15.2, no warnings)
**Tests:** 2/2 pass (marketplace tests)

---

## Summary

The Plugin API v1 implementation is well-structured, consistent, and follows the documented design principles. The code is readable with good doc comments throughout. The main areas of concern are:

1. **CRITICAL:** `scheduler.zig:collectResults()` stores a slice to stack-local memory (`write_cmds`) in `self.last_results`, making the returned `write_commands` a dangling pointer after the function returns.
2. **WARNING:** `safety.zig:hashFile()` reads the entire plugin binary into memory (up to 64MB), which could be problematic for very large plugins.
3. **WARNING:** Several Zig SDK struct fields use `c_int` for booleans while the C header uses `schemify_bool` (typedef'd to `int`), creating a semantic mismatch.
4. **INFO:** Canvas command buffer stores raw `[*:0]const u8` pointers from plugin memory, which may become invalid after the plugin's next call.

---

## Issues by Severity

### CRITICAL

#### 1. `scheduler.zig:351-363` - Dangling pointer in collectResults()

```zig
var write_cmds: [WRITE_QUEUE_CAPACITY]WriteCommand = undefined;
var write_count: usize = 0;
while (self.write_queue.tryPop()) |cmd| { ... }

self.last_results = .{
    .panel_updates = panel_updates,
    .write_commands = if (write_count > 0) write_cmds[0..write_count] else &.{},
};
return self.last_results;
```

`write_cmds` is a stack-local array. The slice `write_cmds[0..write_count]` becomes invalid the moment `collectResults()` returns. Any caller reading `results.write_commands` gets undefined behavior.

**Suggested fix:** Allocate a persistent buffer in the `Scheduler` struct (e.g., `collected_writes: [WRITE_QUEUE_CAPACITY]WriteCommand`) and drain into that instead.

---

#### 2. `scheduler.zig:399-411` - Race condition: PluginSystem accessed from worker without synchronization

The worker thread calls `self.plugin_system.sendHtmlEvent(...)`, `self.plugin_system.renderPanel(...)`, etc. The `PluginSystem` struct has no thread safety ("Thread-safety: none" per lib.zig:38). If the main thread calls `activate()`, `deactivate()`, or modifies `plugins` concurrently, this is a data race.

**Suggested fix:** Either:
- Document that all dispatch calls to PluginSystem must happen exclusively on the worker (never from main thread simultaneously), OR
- Add a lock around `plugins` modification in activate/deactivate, OR
- Queue activate/deactivate as work items to the worker thread.

---

### WARNING

#### 3. `safety.zig:401-406` - hashFile reads entire file into memory

```zig
pub fn hashFile(alloc: std.mem.Allocator, path: []const u8) ![64]u8 {
    const file_bytes = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024) catch ...;
    defer alloc.free(file_bytes);
    return hashBytes(file_bytes);
}
```

For a 64MB plugin binary, this allocates 64MB on the heap. SHA-256 supports incremental hashing. This should stream the file in chunks.

**Suggested fix:** Use `Sha256.init()` + `.update(chunk)` + `.final()` with a fixed 4KB/64KB read buffer.

---

#### 4. `host_api.zig:91-93` - ReturnBuf aliasing risk

Three separate `ReturnBuf` instances exist for three different functions:
```zig
var buf_read_file: ReturnBuf = .{};
var buf_project_dir: ReturnBuf = .{};
var buf_plugin_data_dir: ReturnBuf = .{};
```

If a plugin calls `host->read_file(host->project_dir())`, the inner call to `project_dir()` returns a pointer into `buf_project_dir`, then `read_file` uses a different buffer. This is safe because each function has its own buffer.

However, if the same host function is called twice in sequence (e.g., `read_file("a"); read_file("b")`), the first result is clobbered. The API doc states "valid until the next call to the same function from the same plugin" -- so this is BY DESIGN but should be more prominently documented in the code comment.

**Status:** Design-acceptable, but add a more explicit warning comment at the declaration site.

---

#### 5. `host_api.zig:255-265` - Canvas text/image commands store raw plugin pointers

```zig
text: struct { ..., content: [*:0]const u8, ... },
image: struct { ..., data_uri: [*:0]const u8 },
```

These store raw pointers from plugin-owned memory. If the plugin frees/overwrites that memory before the GUI consumes the commands (which happens next frame), the pointers dangle.

**Suggested fix:** Copy the string data into a dedicated arena when appending canvas commands, or document that canvas commands must be consumed within the same call frame.

---

#### 6. `lib.zig:219-245` - renderPanel() allocates on heap

```zig
const duped = self.alloc.dupe(u8, html) catch continue;
self.panel_html.put(self.alloc, panel_id, duped) catch continue;
```

The `renderPanel()` path performs heap allocation (`dupe` + hashmap put). The audit checklist requires no heap allocs in this path.

**Mitigation:** This is the Phase 0 synchronous path. In the async path (scheduler), HTML is arena-buffered. The Phase 0 path is acceptable for the initial implementation but should be noted as deviating from the "zero allocs in hot path" principle.

---

#### 7. Zig SDK `SchemifyCanvas.rect` uses `c_int` for `filled` parameter

In `tools/plugins/zig/src/lib.zig:44`:
```zig
rect: ?*const fn (x: f32, y: f32, w: f32, h: f32, color: u32, filled: c_int) callconv(.c) void,
```

But in `src/plugins/types.zig:56`:
```zig
rect: ?*const fn (f32, f32, f32, f32, u32, bool) callconv(.c) void,
```

The host defines `filled` as `bool`, but the Zig SDK defines it as `c_int`. On most platforms `bool` in Zig's C ABI is 1 byte, while `c_int` is 4 bytes. This is an ABI mismatch.

**Suggested fix:** The Zig SDK should use `bool` to match the host, OR the host should use `c_int` to match C's `schemify_bool`. Since the C header uses `schemify_bool` (which is `int`), the host's `types.zig` should change `bool` to `c_int` for `filled` parameters.

---

#### 8. Rust SDK `SchemifyHost.canvas`/`schematic` are non-optional raw pointers

In `tools/plugins/rust/src/lib.rs:154-155`:
```rust
pub canvas: *const SchemifyCanvas,
pub schematic: *const SchemifySchematic,
```

But in the host (`src/plugins/types.zig:106-107`):
```zig
canvas: ?*const SchemifyCanvas = null,
schematic: ?*const SchemifySchematic = null,
```

The host uses optional (nullable) pointers. The Rust SDK declares them as non-null raw pointers. If the host ever passes null for these, the Rust side would have undefined behavior when dereferencing.

**Suggested fix:** Change Rust fields to `pub canvas: *const SchemifyCanvas` -> `pub canvas: Option<core::ptr::NonNull<SchemifyCanvas>>` or keep as raw `*const` and null-check in the `Host::canvas()` wrapper (which is already done correctly).

**Severity mitigation:** The `Host::canvas()` method does null-check `(*self.raw).canvas`, so in practice this is safe as long as users go through the wrapper. But `#[repr(C)]` struct layout could still be wrong if Rust doesn't treat the pointer field as nullable at the ABI level. Since in C ABI, a pointer is a pointer regardless of nullability annotation, this is **not actually a bug** -- the field will be 8 bytes (a pointer) either way. No real issue.

---

### INFO

#### 9. `lib.zig:1-10` - File-level doc comment mentions "Phase 0" but Phase 1 is done

The comment says "Phase 0: synchronous, single-threaded. All plugin calls happen on the calling thread. Async dispatch is deferred to Phase 1 (scheduler.zig)." But Phase 1 is implemented.

**Suggested fix:** Update comment to reflect current state.

---

#### 10. `loader_wasm.zig:87-88` - TODO comments for future work

Multiple TODOs exist. These are acceptable for a stub module but should be tracked.

---

#### 11. `InteractiveElements.zig:322-334` - formatEvent does not escape `id` or `tag` fields

```zig
fn formatEvent(..., id: []const u8, tag: []const u8, ...) []const u8 {
    var escaped_buf: [2048]u8 = undefined;
    const escaped = jsonEscape(value, &escaped_buf);
    const written = std.fmt.bufPrint(
        &self.json_buf,
        "{{\"type\":\"{s}\",\"id\":\"{s}\",\"tag\":\"{s}\",\"value\":\"{s}\"}}",
        .{ event_type, id, tag, escaped },
    ) catch return "";
    return written;
}
```

Only `value` is JSON-escaped. If an element ID contains a quote character (unlikely but possible), the JSON output would be malformed.

**Suggested fix:** Also escape `id` (or validate that IDs are restricted to safe characters at registration time).

---

#### 12. `Manifest.zig:237` - `parse()` function is 237 lines long (exceeds ~60 line guideline)

The function handles all TOML section types in a single large switch. This is readable due to the repetitive structure but exceeds the "no function exceeds ~60 lines" guideline.

**Suggested fix:** Extract per-section handlers into helper functions (e.g., `parsePluginSection`, `parsePanelEntry`).

---

#### 13. `lib.zig:416-422` - `listPlugins()` allocates and caller must free

```zig
pub fn listPlugins(self: *const PluginSystem) []const types.PluginInfo {
    const infos = self.alloc.alloc(types.PluginInfo, self.plugins.items.len) catch return &.{};
    ...
}
```

The caller must free the returned slice. This is a potential leak if callers forget. Consider returning a view into the existing items instead.

---

#### 14. `types.zig` - PanelDef defined in both types.zig and Manifest.zig

`types.zig:40-46` defines `PanelDef` and `Manifest.zig:18-25` also defines `PanelDef`. They have different fields. This could be confusing.

**Suggested fix:** Rename one (e.g., `Manifest.PanelDef` -> `ManifestPanelDef` or keep as-is with clear doc comments explaining the distinction).

---

## Checklist Results

### Clean code

| Item | Status | Notes |
|------|--------|-------|
| Every module has clear doc comments at file level | PASS | All 9 plugin files + 3 HTML2DVUI files + 4 GUI files have `//!` doc comments |
| No dead code, no commented-out blocks | PASS | No dead code found. TODOs in loader_wasm.zig are appropriate for a stub |
| Function names are self-documenting | PASS | Naming is clear and consistent |
| No function exceeds ~60 lines | WARN | `Manifest.parse()` is ~237 lines; `inspectElfBytes()` is ~115 lines |

### Data-oriented

| Item | Status | Notes |
|------|--------|-------|
| Struct layouts are cache-friendly | PASS | No pointer-heavy structs in hot paths |
| Scheduler's ring buffers are flat arrays | PASS | `SpscRing` uses fixed-size array with atomic head/tail |
| PanelRenderer's per-panel state is flat hashmap | PASS | Uses `std.StringHashMapUnmanaged(PanelState)` |

### Zero allocations in hot paths

| Item | Status | Notes |
|------|--------|-------|
| `renderPanel()` path: no heap allocs | WARN | Phase 0 path allocates via `alloc.dupe`. Async path (scheduler) is arena-only |
| `sendHtmlEvent()` path: no heap allocs | PASS | Uses stack buffers (`[4096:0]u8`) |
| `collectResults()`: no heap allocs | PASS | Reads from pre-allocated ring buffers (but has dangling pointer bug) |
| Canvas command buffer: fixed-size, no growth | PASS | `canvas_command_buf: [4096]CanvasCommand` is fixed |

### Deep modules

| Item | Status | Notes |
|------|--------|-------|
| `lib.zig` is single entry point for `src/plugins/` | PASS | All sub-modules re-exported through `lib.zig` |
| `PanelRenderer` is single entry point for HTML panel rendering | PASS | GUI imports `PanelRenderer` only |
| No shallow wrapper modules | PASS | `UIBridge.zig` is a stub but intentional |

### Specific bug-risk checks

| Item | Status | Notes |
|------|--------|-------|
| `scheduler.zig`: collectResults() write_commands dangling | FAIL | Stack memory escapes. See CRITICAL #1 |
| `host_api.zig`: ReturnBuf aliasing | PASS | Per-function buffers prevent cross-function aliasing |
| `InteractiveElements.zig`: JSON escaping | WARN | `value` is escaped; `id`/`tag` are not. See INFO #11 |
| `PanelRenderer.zig`: Document destroy paired with create | PASS | `deinitAndFree` destroys document; `removePanel` calls it; `deinit` iterates all |
| `safety.zig`: hashFile memory usage | WARN | Reads full file (up to 64MB). See WARNING #3 |
| All SDKs: struct field order matches | WARN | Zig SDK uses `c_int` for bool fields vs host's `bool`. See WARNING #7 |

---

## SDK Cross-Language Consistency

| Field | C | C++ | Zig SDK | Rust | Python | Go | Host (types.zig) |
|-------|---|-----|---------|------|--------|-----|-------------------|
| SchemifyHost field count | 16 | 16 (via C) | 16 | 16 | 16 | 16 | 16 |
| SchemifyCanvas field count | 9 | 9 (via C) | 9 | 9 | 9 | 9 | 9 |
| SchemifySchematic field count | 8 | 8 (via C) | 8 | 8 | 8 | 8 | 8 |
| Export symbols | 11 | 11 | 11 | 11 | 11 | 11 | 11 |
| `filled` param type | `schemify_bool`(int) | `schemify_bool`(int) | `c_int` | `c_int` | `c_int` | `C.int` | `bool` |

**Note:** The host uses Zig `bool` for the `filled` parameter in canvas/circle/rect. All SDKs use `int`-equivalent. This is a potential ABI mismatch (1 byte vs 4 bytes in the struct layout). Since `SchemifyCanvas` is `extern struct` in the host, Zig will use C ABI rules where `bool` is implementation-defined but typically 1 byte with specific padding. The C SDK uses `int` (4 bytes). **This is a real struct layout mismatch in the function pointer signatures.**

---

## Recommendations (Priority Order)

1. **Fix** the dangling pointer in `scheduler.zig:collectResults()` - use a struct-owned buffer
2. **Fix** the `bool` vs `c_int` mismatch for filled/bool parameters in canvas function pointer types
3. **Improve** `hashFile()` to use streaming SHA-256 instead of reading entire file
4. **Document** the thread-safety contract between scheduler worker and PluginSystem
5. **Consider** copying string data for canvas text/image commands
6. **Consider** extracting `Manifest.parse()` into smaller helper functions
