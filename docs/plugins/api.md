# API Reference

Complete reference for the Schemify Plugin SDK (ABI v6).  All types and
functions live in the `PluginIF` module (`@import("PluginIF")`) unless noted
otherwise.

---

## 1. Overview / Wire Format

Plugins are pure message-passing components.  The host calls one function —
`process` — every time it needs to communicate with the plugin.  The plugin
reads a batch of inbound messages from the host, then writes any number of
outbound messages back.  There are no callbacks, no vtables, and no shared
state between host and plugin.

### Wire format

Every message — in both directions — uses the same framing:

```
[u8  tag       ]   message type (Tag enum value)
[u16 payload_sz]   payload byte count, little-endian
[N   bytes     ]   payload (payload_sz bytes)
```

**String encoding** inside payloads: `[u16 len LE][N bytes]` (UTF-8, no null
terminator).  The maximum encoded length is 65535 bytes.

**f32 arrays** inside payloads: `[u32 count LE][count × 4 bytes LE]`.

**u8 arrays** inside payloads: `[u32 count LE][count bytes]`.

### Buffer sizing

`process` receives a caller-allocated output buffer.  If the plugin's response
does not fit, it returns `std.math.maxInt(usize)`.  The host doubles the buffer
and retries.  Otherwise the plugin returns the number of bytes written.

### Minimal plugin skeleton

```zig
const Plugin = @import("PluginIF");

var threshold: f32 = 0.5;

export fn schemify_process(
    in_ptr:  [*]const u8, in_len:  usize,
    out_ptr: [*]u8,       out_cap: usize,
) usize {
    var r = Plugin.Reader.init(in_ptr[0..in_len]);
    var w = Plugin.Writer.init(out_ptr[0..out_cap]);

    while (r.next()) |msg| {
        switch (msg) {
            .load => {
                w.registerPanel(.{
                    .id      = "demo",
                    .title   = "Demo Panel",
                    .vim_cmd = "demo",
                    .layout  = .right_sidebar,
                    .keybind = 'd',
                });
                w.setStatus("demo plugin loaded");
            },
            .draw_panel => {
                w.label("Threshold", 0);
                w.slider(threshold, 0, 1, 1);
            },
            .slider_changed => |ev| {
                if (ev.widget_id == 1) threshold = ev.val;
            },
            else => {},
        }
    }

    return if (w.overflow()) std.math.maxInt(usize) else w.pos;
}

export const schemify_plugin: Plugin.Descriptor = .{
    .name        = "demo",
    .version_str = "0.1.0",
    .process     = schemify_process,
};
```

---

## 2. Descriptor

Every plugin must export a symbol named `schemify_plugin` of type `Descriptor`.
The runtime locates it by looking up the name stored in `EXPORT_SYMBOL`.

```zig
pub const EXPORT_SYMBOL: [*:0]const u8 = "schemify_plugin";

pub const Descriptor = extern struct {
    name:        [*:0]const u8,
    version_str: [*:0]const u8,
    process:     ProcessFn,
};

/// Backward-compatible alias.
pub const PluginDescriptor = Descriptor;
```

`name` is the plugin's human-readable identifier.  `version_str` is a
free-form version string (e.g. `"1.2.0"`).  `process` is the single entry
point through which all host/plugin communication occurs.

Minimal export:

```zig
export const schemify_plugin: Plugin.Descriptor = .{
    .name        = "my-plugin",
    .version_str = "0.1.0",
    .process     = schemify_process,
};
```

---

## 3. ProcessFn

```zig
pub const ProcessFn = *const fn (
    in_ptr:  [*]const u8,
    in_len:  usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) usize;
```

| Parameter | Description |
|-----------|-------------|
| `in_ptr` / `in_len` | Read-only slice of host→plugin messages; valid only for the duration of the call |
| `out_ptr` / `out_cap` | Writable output buffer for plugin→host messages |
| **return** | Bytes written to `out_ptr`, or `std.math.maxInt(usize)` if `out_cap` was too small |

When the plugin returns `maxInt(usize)`, the host doubles the output buffer
and calls `process` again with the same input.  The plugin must be prepared
to replay its full output — do not emit side-effects before checking
`w.overflow()`.

---

## 4. Reader / InMsg

### `Reader`

```zig
pub const Reader = struct {
    buf: []const u8,
    pos: usize,

    pub fn init(buf: []const u8) Reader;
    pub fn next(self: *Reader) ?InMsg;
};
```

`Reader.init` wraps the inbound buffer.  `Reader.next` decodes and returns the
next message, advancing the internal cursor.  Returns `null` at end-of-buffer
or on a malformed frame.  Unknown and plugin→host tags are skipped
transparently.

```zig
var r = Plugin.Reader.init(in_ptr[0..in_len]);
while (r.next()) |msg| {
    switch (msg) { ... }
}
```

### `InMsg`

`InMsg` is a tagged union covering all host→plugin message variants.  Only the
meaningful variants carry payload fields; the rest are `void`.

#### Lifecycle

| Variant | Payload | Description |
|---------|---------|-------------|
| `.load` | — | Plugin is being loaded; register panels and keybinds here |
| `.unload` | — | Plugin is being unloaded; release any resources |
| `.tick` | `dt: f32` | Per-frame tick; `dt` is elapsed seconds since last tick |

#### UI events

| Variant | Payload fields | Description |
|---------|----------------|-------------|
| `.draw_panel` | `panel_id: u16` | Host requests panel UI output for the given panel |
| `.button_clicked` | `panel_id: u16`, `widget_id: u32` | User clicked a button |
| `.slider_changed` | `panel_id: u16`, `widget_id: u32`, `val: f32` | Slider value changed |
| `.text_changed` | `panel_id: u16`, `widget_id: u32`, `text: []const u8` | Text input changed |
| `.checkbox_changed` | `panel_id: u16`, `widget_id: u32`, `val: u8` | Checkbox toggled (`0`/`1`) |

#### Commands and state

| Variant | Payload fields | Description |
|---------|----------------|-------------|
| `.command` | `tag: []const u8`, `payload: []const u8` | Dispatched host or keybind command |
| `.state_response` | `key: []const u8`, `val: []const u8` | Reply to a prior `getState` call |
| `.config_response` | `key: []const u8`, `val: []const u8` | Reply to a prior `getConfig` call |

#### Schematic events

| Variant | Payload fields | Description |
|---------|----------------|-------------|
| `.schematic_changed` | — | Active schematic was modified |
| `.selection_changed` | `instance_idx: i32` | Selected instance changed; `-1` means no selection |
| `.schematic_snapshot` | `instance_count: u32`, `wire_count: u32`, `net_count: u32` | Summary counts after a `queryInstances`/`queryNets` |
| `.instance_data` | `idx: u32`, `name: []const u8`, `symbol: []const u8` | One instance entry from a `queryInstances` response |
| `.instance_prop` | `idx: u32`, `key: []const u8`, `val: []const u8` | One property entry for an instance |
| `.net_data` | `idx: u32`, `name: []const u8` | One net entry from a `queryNets` response |

String slices returned in `InMsg` payloads (e.g. `text`, `key`, `val`, `name`,
`symbol`) are zero-copy views into the inbound buffer and are valid only for
the duration of the `process` call.  Copy them if you need to retain the data.

---

## 5. Writer Commands

### `Writer`

```zig
pub const Writer = struct {
    buf: []u8,
    pos: usize,

    pub fn init(buf: []u8) Writer;
    pub fn overflow(self: Writer) bool;
    // ... methods below
};
```

`Writer.init` wraps the output buffer.  `overflow()` returns `true` if any
write was silently dropped due to the buffer being full.  Check `overflow()`
before returning and signal the retry protocol if needed:

```zig
return if (w.overflow()) std.math.maxInt(usize) else w.pos;
```

---

### Panel and status

#### `registerPanel(def: PanelDef) void`

Register a panel with the host.  Call during `.load`.

```zig
w.registerPanel(.{
    .id      = "waveform",
    .title   = "Waveform Viewer",
    .vim_cmd = "wv",
    .layout  = .bottom_bar,
    .keybind = 'w',
});
```

#### `setStatus(msg: []const u8) void`

Set the one-line status bar text at the bottom of the editor window.

```zig
w.setStatus("simulation complete");
```

---

### Logging

#### `log(level: LogLevel, tag: []const u8, msg: []const u8) void`

Emit a structured log entry.  `tag` is a short identifier (e.g. the plugin
name); `msg` is the message body.

```zig
w.log(.info, "sim",  "starting ngspice");
w.log(.warn, "sim",  "convergence issues detected");
w.log(.err,  "sim",  "ngspice exited with code 1");
```

---

### Command dispatch

#### `pushCommand(tag: []const u8, payload: []const u8) void`

Push a named command into the host's command queue.  The host dispatches it on
the next frame; the plugin may receive it back as a `.command` message.

```zig
w.pushCommand("open-netlist", "/path/to/top.cir");
```

---

### Persistent state

State is persisted by the host across sessions.  All reads are asynchronous:
the plugin calls `getState`, then handles the `.state_response` message on a
future tick.

#### `setState(key: []const u8, val: []const u8) void`

Store a key/value pair.

```zig
w.setState("last_file", path);
```

#### `getState(key: []const u8) void`

Request a value.  The reply arrives as `.state_response` next tick.

```zig
w.getState("last_file");
// ... later in a future process call:
// .state_response => |ev| { if (std.mem.eql(u8, ev.key, "last_file")) ... }
```

---

### Configuration

TOML-backed per-plugin configuration, keyed by plugin ID.

#### `setConfig(plugin_id: []const u8, key: []const u8, val: []const u8) void`

Write a config value.

```zig
w.setConfig("my-plugin", "threshold", "0.75");
```

#### `getConfig(plugin_id: []const u8, key: []const u8) void`

Request a config value.  The reply arrives as `.config_response` next tick.

```zig
w.getConfig("my-plugin", "threshold");
```

---

### Host interaction

#### `requestRefresh() void`

Ask the host to schedule a UI repaint on the next animation frame.  Useful
after background work completes.

```zig
w.requestRefresh();
```

#### `registerKeybind(key: u8, mods: u8, cmd_tag: []const u8) void`

Register a global keyboard shortcut.  When pressed, the host fires a
`.command` message with the given `cmd_tag`.

```zig
w.registerKeybind('r', 0, "run-simulation");
```

---

### Schematic editing

#### `placeDevice(sym: []const u8, name: []const u8, x: i32, y: i32) void`

Place a device instance in the active schematic at grid coordinates `(x, y)`.

```zig
w.placeDevice("sky130_fd_pr__nfet_01v8", "M1", 100, 200);
```

#### `addWire(x0: i32, y0: i32, x1: i32, y1: i32) void`

Add a wire segment between two grid coordinates.

```zig
w.addWire(100, 200, 100, 300);
```

#### `setInstanceProp(idx: u32, key: []const u8, val: []const u8) void`

Set a property on the instance at `idx`.

```zig
w.setInstanceProp(3, "W", "2u");
```

---

### Schematic queries

Queries are asynchronous.  The plugin sends the request, then handles the
response messages on the next tick.

#### `queryInstances() void`

Request all instance data.  The host replies with a sequence of
`.schematic_snapshot`, `.instance_data`, and `.instance_prop` messages.

```zig
w.queryInstances();
```

#### `queryNets() void`

Request all net data.  The host replies with `.schematic_snapshot` followed by
`.net_data` messages.

```zig
w.queryNets();
```

---

## 6. Writer UI Widgets

UI widgets are emitted during a `.draw_panel` message.  The `id` parameter
must be unique within a single draw call for a given panel; a simple
sequential counter works.

The host renders the widget list top-to-bottom.  Stateful widgets
(buttons, sliders, checkboxes) generate events that arrive as
`button_clicked`, `slider_changed`, etc. on subsequent ticks.

### `label(text: []const u8, id: u32) void`

Render a text label.

```zig
w.label("Threshold:", 0);
```

### `button(text: []const u8, id: u32) void`

Render a push button.  A `button_clicked` event arrives the tick the user
clicks it.

```zig
w.button("Run Simulation", 1);
```

### `separator(id: u32) void`

Render a horizontal separator rule.

```zig
w.separator(2);
```

### `beginRow(id: u32) void` / `endRow(id: u32) void`

Begin and end a horizontal layout row.  Widgets placed between matching
`beginRow`/`endRow` calls are arranged side by side.  Both calls use the
same `id`.

```zig
w.beginRow(3);
w.label("W:", 4);
w.button("2u", 5);
w.endRow(3);
```

### `slider(val: f32, min: f32, max: f32, id: u32) void`

Render a horizontal slider at current value `val` in range `[min, max]`.
`slider_changed` events carry the new value.

```zig
w.slider(threshold, 0.0, 1.0, 6);
```

### `checkbox(val: bool, text: []const u8, id: u32) void`

Render a labeled checkbox at current state `val`.  `checkbox_changed` events
carry the new state.

```zig
w.checkbox(show_labels, "Show net labels", 7);
```

### `progress(fraction: f32, id: u32) void`

Render a progress bar.  `fraction` is clamped to `[0.0, 1.0]`.

```zig
w.progress(sim_progress, 8);
```

### `plot(title: []const u8, xs: []const f32, ys: []const f32, id: u32) void`

Render a 2D line chart.  `xs` and `ys` must have the same length.

```zig
w.plot("Vout vs Time", time_arr, voltage_arr, 9);
```

### `image(pixels: []const u8, w: u32, h: u32, id: u32) void`

Render a bitmap image.  `pixels` must be RGBA8 packed row-major,
`pixels.len == w * h * 4`.

```zig
w.image(rgba_data, 256, 256, 10);
```

### `collapsibleStart(label: []const u8, open: bool, id: u32) void` / `collapsibleEnd(id: u32) void`

Begin and end a collapsible section.  `open` is the initial expanded state.
Both calls use the same `id`.

```zig
w.collapsibleStart("Advanced Options", false, 11);
w.slider(gain, 0, 10, 12);
w.collapsibleEnd(11);
```

---

## 7. PanelDef / PanelLayout / LogLevel

### `PanelLayout`

Controls where the panel is docked in the host UI.

```zig
pub const PanelLayout = enum(u8) {
    overlay       = 0,   // floating overlay / modal
    left_sidebar  = 1,   // docked to the left panel area
    right_sidebar = 2,   // docked to the right panel area
    bottom_bar    = 3,   // docked to the bottom bar
};

/// Backward-compatible alias.
pub const Layout = PanelLayout;
```

### `PanelDef`

Passed to `Writer.registerPanel()` during `.load`.

```zig
pub const PanelDef = struct {
    id:      []const u8,   // unique panel identifier
    title:   []const u8,   // display title in the host UI
    vim_cmd: []const u8,   // vim-mode command string to toggle the panel
    layout:  PanelLayout,
    keybind: u8,           // ASCII key shortcut (0 = none)
};
```

Example:

```zig
w.registerPanel(.{
    .id      = "optimizer",
    .title   = "Optimizer",
    .vim_cmd = "opt",
    .layout  = .right_sidebar,
    .keybind = 'o',
});
```

### `LogLevel`

```zig
pub const LogLevel = enum(u8) { info = 0, warn = 1, err = 2 };
```

---

## 8. Vfs

`Plugin.Vfs` (re-exported from `core`) provides a platform-agnostic filesystem
API.  All functions work identically on native and WASM builds.

### `readAlloc(allocator, path: []const u8) ![]u8`

Read the entire file at `path` into a new allocation.  Caller must free the
returned slice.

```zig
const data = try Plugin.Vfs.readAlloc(alloc, "config.toml");
defer alloc.free(data);
```

### `writeAll(path: []const u8, data: []const u8) !void`

Write `data` to `path`, creating or overwriting the file.

```zig
try Plugin.Vfs.writeAll("output/result.json", json_bytes);
```

### `delete(path: []const u8) !void`

Delete a file.

```zig
try Plugin.Vfs.delete("tmp/scratch.bin");
```

### `exists(path: []const u8) bool`

Return `true` if the path exists as a file or directory.

```zig
if (!Plugin.Vfs.exists("cache/index.json")) {
    try buildIndex(alloc);
}
```

### `makePath(path: []const u8) !void`

Create `path` as a directory, including all missing parent components.

```zig
try Plugin.Vfs.makePath("my-plugin/cache");
```

### `listDir(allocator, path: []const u8) !DirList`

List all entries in `path`.  Returns a `DirList` that must be freed with
`deinit`.

```zig
const listing = try Plugin.Vfs.listDir(alloc, "pdk/sky130A/libs.ref/");
defer listing.deinit(alloc);

for (listing.entries) |name| {
    if (std.mem.endsWith(u8, name, ".sym")) { ... }
}
```

### `DirList`

```zig
pub const DirList = struct {
    buf:     []u8,
    entries: [][]const u8,   // bare filenames (not full paths)

    pub fn deinit(self: DirList, allocator: std.mem.Allocator) void;
};
```

Entry names are bare filenames.  To construct a full path:

```zig
const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry });
defer alloc.free(full);
```

---

## 9. Build Helper

`tools/sdk/build_plugin_helper.zig` is imported via the `schemify_sdk`
dependency.  It handles target selection, module wiring, and install steps for
every supported language.

```zig
// plugin build.zig
const helper = @import("schemify_sdk").build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);
    // ...
}
```

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

### `setup(b, sdk_dep) PluginContext`

Resolves the build target, optimize mode, and dvui dependency (through the
SDK's own dependency graph — external plugin repos do not need a `dvui` entry
in their `build.zig.zon`).  Creates and wires the `core`, `PluginIF`, and
`sdk` modules.

### `addNativePluginLibrary(b, ctx, name, root_source_file) *Compile`

Create a native dynamic-library plugin.  Named imports `"PluginIF"`, `"dvui"`,
and `"sdk"` are wired in automatically.  Returns the compile step so you can
add extra C sources, include paths, or system libraries before calling
`b.installArtifact`.

```zig
const lib = helper.addNativePluginLibrary(b, ctx, "MyPlugin", "src/main.zig");
lib.linkSystemLibrary("ngspice");
b.installArtifact(lib);
```

### `addWasmPlugin(b, ctx, name, root_source_file) void`

Create a WASM plugin executable and install it to
`zig-out/plugins/<name>.wasm`.  Named imports `"PluginIF"`, `"dvui"`, and
`"sdk"` are wired in automatically.

```zig
helper.addWasmPlugin(b, ctx, "MyPlugin", "src/main.zig");
```

### `addCPlugin(b, ctx, sdk_dep, name, c_src) *Compile`

Create a native C plugin dynamic library.  Compiles `c_src` as C11 against
`schemify_plugin.h` (header-only; no shim file required in ABI v6).
Also generates `compile_flags.txt` alongside the source so clangd resolves
the header automatically.

```zig
const lib = helper.addCPlugin(b, ctx, sdk_dep, "CHello", "src/main.c");
b.installArtifact(lib);
```

### `addCppPlugin(b, ctx, sdk_dep, name, cpp_src) *Compile`

Same as `addCPlugin` but compiles `cpp_src` as C++17 and links `libstdc++`.

```zig
const lib = helper.addCppPlugin(b, ctx, sdk_dep, "CppHello", "src/main.cpp");
b.installArtifact(lib);
```

### `addCWasmPlugin(b, sdk_dep, name, c_src) void`

Compile a C plugin to WASM via Emscripten (`emcc`).
Output: `zig-out/plugins/<name>.wasm`.

```zig
helper.addCWasmPlugin(b, sdk_dep, "CHelloWasm", "src/main.c");
```

### `addCppWasmPlugin(b, sdk_dep, name, cpp_src) void`

Compile a C++ plugin to WASM via Emscripten (`em++`).
Output: `zig-out/plugins/<name>.wasm`.

```zig
helper.addCppWasmPlugin(b, sdk_dep, "CppHelloWasm", "src/main.cpp");
```

### `addRustPlugin(b, rust_dir, lib_name) void`

Invoke `cargo build --release` in `rust_dir` and copy the resulting shared
library to `zig-out/lib/lib<lib_name>.so`.

```zig
helper.addRustPlugin(b, "rust/my-plugin", "my_plugin");
```

### `addGoPlugin(b, go_dir, install_name) void`

Invoke TinyGo to build a native shared library from `go_dir` and place it at
`zig-out/lib/lib<install_name>.so`.

```zig
helper.addGoPlugin(b, "go/my-plugin", "go_plugin");
```

### `addPythonPlugin(b, plugin_dir_name, sdk_dep, py_files, requirements, log_label) void`

Deploy Python scripts to
`~/.config/Schemify/SchemifyPython/scripts/<plugin_dir_name>/`.
If `requirements` is non-null, runs `pip install -r <requirements>` first.
Registers a `zig build run` step that deploys and then launches Schemify.

```zig
helper.addPythonPlugin(b, "MyPyPlugin", sdk_dep,
    &.{ "src/plugin.py", "src/worker.py" },
    "requirements.txt",
    "MyPyPlugin",
);
```

### `addNativeAutoInstallRunStep(b, plugin_dir_name, sdk_dep, log_label) void`

Register a `zig build run` step that copies `zig-out/lib/*` into
`~/.config/Schemify/<plugin_dir_name>/` and then runs `zig build run` in the
Schemify host repo.  Intended for in-repo plugin development only.

### `addWasmAutoServeStep(b, sdk_dep, name, log_label) void`

Register a `zig build run -Dbackend=web` step that builds the Schemify host
in web mode, copies `<name>.wasm` into the host's output, patches
`plugins.json`, and serves the result at `http://localhost:8080`.

---

## Type Index

| Type | Module | Description |
|------|--------|-------------|
| `Descriptor` | `PluginIF` | Plugin export struct |
| `PluginDescriptor` | `PluginIF` | Alias for `Descriptor` |
| `ProcessFn` | `PluginIF` | Plugin entry point function type |
| `PanelLayout` | `PluginIF` | Panel placement enum |
| `Layout` | `PluginIF` | Alias for `PanelLayout` |
| `PanelDef` | `PluginIF` | Panel registration data |
| `LogLevel` | `PluginIF` | `info` / `warn` / `err` |
| `Tag` | `PluginIF` | Message tag enum (host→plugin and plugin→host) |
| `InMsg` | `PluginIF` | Tagged union of host→plugin messages |
| `Reader` | `PluginIF` | Inbound message decoder |
| `Writer` | `PluginIF` | Outbound message encoder |
| `Vfs` | `core` / `PluginIF` | Platform-agnostic filesystem |
| `Vfs.DirList` | `core` | Directory listing result |
| `Backend` | `build_plugin_helper` | `native` / `web` |
| `PluginContext` | `build_plugin_helper` | Build context returned by `setup` |
