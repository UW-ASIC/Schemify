# API Reference

Complete reference for the Schemify Plugin SDK.  All symbols live in the
`PluginIF` module (`@import("PluginIF")`) unless noted otherwise.

---

## Constants

### `ABI_VERSION: u32`

Current plugin ABI version.  Must be set in `Descriptor.abi_version`; the
runtime refuses to load plugins with a mismatched version.

```zig
pub const ABI_VERSION: u32 = 3;
```

### `EXPORT_SYMBOL: [*:0]const u8`

The C symbol name the runtime looks up in every `.so` / WASM export table.
Value: `"schemify_plugin"`.

---

## Descriptor

Every plugin **must** export a symbol of this type with the name
`schemify_plugin`:

```zig
pub const Descriptor = extern struct {
    abi_version: u32,
    name:        [*:0]const u8,
    version_str: [*:0]const u8,
    set_ctx:     SetCtxFn,      // always Plugin.setCtx
    on_load:     OnLoadFn,
    on_unload:   OnUnloadFn,
    on_tick:     ?OnTickFn,     // null for plugins with no per-frame work
};
```

Minimal declaration:

```zig
export const schemify_plugin: Plugin.Descriptor = .{
    .abi_version = Plugin.ABI_VERSION,
    .name        = "my-plugin",
    .version_str = "0.1.0",
    .set_ctx     = Plugin.setCtx,
    .on_load     = &onLoad,
    .on_unload   = &onUnload,
    .on_tick     = null,
};
```

### Lifecycle callbacks

| Field | Signature | Notes |
|-------|-----------|-------|
| `set_ctx` | `fn(?*Ctx) callconv(.c) void` | Always `Plugin.setCtx` |
| `on_load` | `fn() callconv(.c) void` | Called once after `dlopen` |
| `on_unload` | `fn() callconv(.c) void` | Called before `dlclose` |
| `on_tick` | `fn(dt: f32) callconv(.c) void` or `null` | Called every frame |

The runtime calls `set_ctx(&ctx)` before each callback and `set_ctx(null)`
after.  Only use host APIs **inside** a callback.

---

## Status & Logging

### `setStatus(msg: []const u8) void`

Set the one-line status bar text visible at the bottom of the editor window.

```zig
Plugin.setStatus("simulation complete");
```

### `logInfo(tag: []const u8, msg: []const u8) void`
### `logWarn(tag: []const u8, msg: []const u8) void`
### `logErr(tag: []const u8, msg: []const u8) void`

Emit a structured log entry at the given severity level.  `tag` is a short
identifier (e.g. the plugin name); `msg` is the message body.

```zig
Plugin.logInfo("sim", "starting ngspice");
Plugin.logWarn("sim", "convergence issues detected");
Plugin.logErr("sim",  "ngspice exited with code 1");
```

### `logAt(level: LogLevel, tag: []const u8, msg: []const u8) void`

Low-level variant that accepts an explicit `LogLevel`:

```zig
pub const LogLevel = enum(u8) { info = 0, warn = 1, err = 2 };
```

---

## Panels

### `Layout`

```zig
pub const Layout = enum(u8) {
    overlay       = 0,  // floating overlay / modal
    left_sidebar  = 1,  // docked to the left panel area
    right_sidebar = 2,  // docked to the right panel area
};
```

### `PanelDef`

Full panel definition passed to `registerPanel`:

```zig
pub const PanelDef = extern struct {
    id:       [*:0]const u8,  // unique identifier
    title:    [*:0]const u8,  // display title
    vim_cmd:  [*:0]const u8,  // vim-mode command string
    layout:   Layout,
    keybind:  u8,             // ASCII key shortcut
    draw_fn:  ?DrawFn,        // called every frame the panel is visible
};
```

### `OverlayDef`

Convenience definition for overlay-only panels.  `id`, `title`, and `vim_cmd`
all use the same `name` field:

```zig
pub const OverlayDef = extern struct {
    name:     [*:0]const u8,
    keybind:  u8,
    draw_fn:  ?DrawFn,
};
```

### `UiCtx`

A stable `extern struct` the host passes to every `draw_fn` call.  All
function pointers use C calling convention.

**Plugins must render UI exclusively through this struct — do not import
`dvui` directly.**  The host and the plugin each compile their own static
copy of dvui with separate internal state; bypassing `UiCtx` leads to
struct-layout mismatches and segfaults.

```zig
pub const UiCtx = extern struct {
    /// Render a text label. `id` must be unique within this panel frame.
    label:     *const fn (text: [*]const u8, len: usize, id: u32) callconv(.c) void,
    /// Render a button; returns true the frame the user clicks it.
    button:    *const fn (text: [*]const u8, len: usize, id: u32) callconv(.c) bool,
    /// Render a horizontal separator rule.
    separator: *const fn (id: u32) callconv(.c) void,
    /// Begin a horizontal row layout. Pair every call with end_row(same_id).
    begin_row: *const fn (id: u32) callconv(.c) void,
    /// End the horizontal row started with begin_row(id).
    end_row:   *const fn (id: u32) callconv(.c) void,
};
```

The `id` parameter on every call must be **unique within a single frame**
for that panel.  A simple sequential counter works:

```zig
pub fn draw(ctx: *const Plugin.UiCtx) callconv(.c) void {
    ctx.label("Hello", 5, 0);
    ctx.separator(1);
    ctx.begin_row(2);
    ctx.label("key:", 4, 3);
    if (ctx.button("click me", 8, 4)) doSomething();
    ctx.end_row(2);
}
```

### `DrawFn`

```zig
pub const DrawFn = *const fn (ctx: *const UiCtx) callconv(.c) void;
```

The draw callback is called by the host during its rendering pass.
Render all UI through the provided `ctx`; the `UiCtx` pointer is valid only
for the duration of the call.

### `registerPanel(def: *const PanelDef) bool`

Register a panel with full control over layout and vim command.  Returns
`true` on success.

```zig
_ = Plugin.registerPanel(&.{
    .id      = "my-panel",
    .title   = "My Panel",
    .vim_cmd = "my-panel",
    .layout  = .right_sidebar,
    .keybind = 'm',
    .draw_fn = &draw,
});
```

### `registerOverlay(def: *const OverlayDef) bool`

Shorthand for registering an overlay panel:

```zig
_ = Plugin.registerOverlay(&.{
    .name    = "my-overlay",
    .keybind = 'o',
    .draw_fn = &draw,
});
```

---

## Project context

### `getProjectDir(buf: []u8) []const u8`

Copy the current project directory path into `buf` and return the written
slice.  Returns an empty slice if no project is open.

```zig
var buf: [512]u8 = undefined;
const dir = Plugin.getProjectDir(&buf);
Plugin.logInfo("plugin", dir);
```

### `getActiveSchematicName(buf: []u8) ?[]const u8`

Copy the active schematic name into `buf`.  Returns `null` when no schematic
is open.

```zig
var buf: [256]u8 = undefined;
if (Plugin.getActiveSchematicName(&buf)) |name| {
    Plugin.setStatus(name);
}
```

### `requestRefresh() void`

Ask the host to schedule a UI redraw on the next animation frame.  Call this
from `on_tick` or an async callback when your plugin's state changes.

---

## Memory

### `allocator() std.mem.Allocator`

Returns the host-backed allocator.

- **Native** — backed by the host's GPA via `host_alloc` / `host_realloc` / `host_free`
- **WASM** — returns `std.heap.wasm_allocator`

Use this for all plugin allocations instead of creating your own allocator.

```zig
const alloc = Plugin.allocator();
const buf   = try alloc.alloc(u8, 4096);
defer alloc.free(buf);
```

### `rawState() ?*anyopaque`

**First-party only.**  Returns a pointer to the host's `AppState`.  Only valid
on native builds, only inside a lifecycle callback, and only when the plugin
shares the same source tree as the host.  Returns `null` on WASM.

---

## Vfs

Imported as `Plugin.Vfs` or `@import("core").Vfs`.  All functions work
identically on native and WASM.

### `readAlloc(allocator, path: []const u8) ![]u8`

Read the entire file at `path` into a new allocation.  Caller must free the
returned slice.

```zig
const data = try Plugin.Vfs.readAlloc(alloc, "project.chn");
defer alloc.free(data);
```

**Errors:** `error.FileNotFound`, `error.ReadError`, `std.fs.File.ReadError`

### `writeAll(path: []const u8, data: []const u8) !void`

Write `data` to `path`, creating or overwriting the file.

```zig
try Plugin.Vfs.writeAll("output/result.json", json_bytes);
```

**Errors:** `error.WriteError`, `std.fs.File.WriteError`

### `delete(path: []const u8) !void`

Delete a file.

```zig
try Plugin.Vfs.delete("tmp/scratch.bin");
```

**Errors:** `error.DeleteError`, `std.fs.Dir.DeleteFileError`

### `exists(path: []const u8) bool`

Return `true` if the path exists as a file or directory.

```zig
if (!Plugin.Vfs.exists("cache/index.json")) {
    try buildIndex(alloc);
}
```

### `makePath(path: []const u8) !void`

Create `path` as a directory, creating all missing parent components.

```zig
try Plugin.Vfs.makePath("my-plugin/cache");
```

**Errors:** `error.MakePathFailed`, `std.fs.Dir.MakeError`

### `listDir(allocator, path: []const u8) !DirList`

List all entries in `path`.  Returns a `DirList` that must be freed with
`deinit`.

```zig
const listing = try Plugin.Vfs.listDir(alloc, "pdk/sky130A/libs.ref/");
defer listing.deinit(alloc);

for (listing.entries) |name| {
    if (std.mem.endsWith(u8, name, ".sym")) {
        // ...
    }
}
```

**Errors:** `error.DirNotFound`, `std.fs.Dir.OpenError`

### `DirList`

```zig
pub const DirList = struct {
    buf:     []u8,         // flat buffer; entries point into it
    entries: [][]const u8, // bare filenames (not full paths)

    pub fn deinit(self: DirList, allocator: std.mem.Allocator) void;
};
```

Entry names are bare filenames.  To construct a full path:

```zig
const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry });
defer alloc.free(full);
```

---

## Build helper (`tools/sdk/build_plugin_helper.zig`)

Imported in plugin `build.zig` via `@import("schemify_sdk").build_plugin_helper`.

### `Backend`

```zig
pub const Backend = enum { native, web };
```

### `PluginContext`

```zig
pub const PluginContext = struct {
    backend:   Backend,
    is_web:    bool,
    optimize:  std.builtin.OptimizeMode,
    target:    std.Build.ResolvedTarget,
    dvui_mod:  *std.Build.Module,
    core_mod:  *std.Build.Module,
    plugin_if: *std.Build.Module,
    sdk_mod:   *std.Build.Module,
};
```

### `setup(b: *std.Build, sdk_dep: *std.Build.Dependency) PluginContext`

Resolves target, optimize, dvui (from the SDK's own dependency graph), and
creates the `core`, `PluginIF`, and `sdk` modules.

```zig
const sdk_dep = b.dependency("schemify_sdk", .{});
const ctx     = helper.setup(b, sdk_dep);
```

### `addNativePluginLibrary(b, ctx, name, root_source_file) *Compile`

Create a native dynamic-library plugin.  Returns the compile step so you can
add extra C sources, include paths, or system libraries before calling
`b.installArtifact`.

Named imports automatically added: `"PluginIF"`, `"dvui"`, `"sdk"`.

### `addWasmPlugin(b, ctx, name, root_source_file) void`

Create a WASM plugin executable, install it to `zig-out/plugins/<name>.wasm`,
and register it with the install step.

Named imports automatically added: `"PluginIF"`, `"dvui"`, `"sdk"`.

### `addInstallFiles(b, install_dir, files: []const []const u8) void`

Install a list of files (relative to the plugin root) into `install_dir`.
Useful for Python scripts, TOML configs, and other assets.

```zig
helper.addInstallFiles(b, .lib, &.{
    "plugin.toml",
    "src/worker.py",
    "requirements.txt",
});
```

### `addNativeAutoInstallRunStep(b, plugin_dir_name, sdk_dep, log_label) void`

Register a `zig build run` step that:

1. Copies `zig-out/lib/*` into `~/.config/Schemify/<plugin_dir_name>/`
2. Runs `zig build run` in the Schemify host repo

For in-repo plugin development only.  External SDK consumers should write
their own install step or use the manual install workflow.

---

## SDK runtime module (`tools/sdk/root.zig`)

Available as `@import("sdk")` inside plugin source files (the build helper
adds it as a named import automatically).

```zig
pub const PluginIF = @import("PluginIF");
pub const core     = @import("core");
```

Using the SDK module is optional — `@import("PluginIF")` and `@import("core")`
remain the canonical imports.  The `sdk` module is a convenience for authors
who prefer a single import point.

```zig
// Equivalent ways to access PluginIF:
const Plugin  = @import("PluginIF");     // direct import
const sdk     = @import("sdk");
const Plugin2 = sdk.PluginIF;            // via sdk module
```

---

## Type index

| Type | Module | Description |
|------|--------|-------------|
| `Descriptor` | `PluginIF` | Plugin export struct |
| `Layout` | `PluginIF` | Panel layout enum |
| `PanelDef` | `PluginIF` | Full panel registration |
| `OverlayDef` | `PluginIF` | Overlay-only registration |
| `UiCtx` | `PluginIF` | Host-provided UI toolkit (passed to `draw_fn`) |
| `DrawFn` | `PluginIF` | Draw callback type |
| `LogLevel` | `PluginIF` | `info` / `warn` / `err` |
| `Ctx` | `PluginIF` | Host context (internal) |
| `VTable` | `PluginIF` | Host dispatch table (internal) |
| `Vfs` | `core` / `PluginIF` | Platform-agnostic filesystem |
| `Vfs.DirList` | `core` | Directory listing result |
| `Backend` | `build_plugin_helper` | `native` / `web` |
| `PluginContext` | `build_plugin_helper` | Build context returned by `setup` |
