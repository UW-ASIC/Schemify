# Plugin API Reference

Complete reference for the Schemify Plugin SDK (ABI v6). All types live in `@import("PluginIF")`.

## Wire Format

Every message uses the same framing:

```
[u8  tag       ]   message type
[u16 payload_sz]   payload byte count, little-endian
[N   bytes     ]   payload
```

**Strings inside payloads:** `[u16 len LE][N bytes]` (UTF-8, no null terminator)

**f32 arrays:** `[u32 count LE][count × 4 bytes LE]`

## Descriptor

Every plugin must export `schemify_plugin`:

```zig
pub const Descriptor = extern struct {
    abi_version: u32 = ABI_VERSION,   // must equal 6
    name:        [*:0]const u8,
    version_str: [*:0]const u8,
    process:     ProcessFn,
};

export const schemify_plugin: Plugin.Descriptor = .{
    .name        = "my-plugin",
    .version_str = "0.1.0",
    .process     = schemify_process,
};
```

## ProcessFn

```zig
pub const ProcessFn = *const fn (
    in_ptr:  [*]const u8,
    in_len:  usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) usize;
```

Return bytes written, or `maxInt(usize)` if output buffer too small (host will retry with doubled buffer).

## Reader / InMsg

```zig
var r = Plugin.Reader.init(in_ptr[0..in_len]);
while (r.next()) |msg| {
    switch (msg) { ... }
}
```

### Lifecycle Messages

| Variant | Payload | Description |
|---------|---------|-------------|
| `.load` | — | Register panels and keybinds here |
| `.unload` | — | Release resources |
| `.tick` | `dt: f32` | Per-frame tick; `dt` = elapsed seconds |

### UI Events

| Variant | Payload | Description |
|---------|---------|-------------|
| `.draw_panel` | `panel_id: u16` | Emit UI widgets for this panel |
| `.button_clicked` | `panel_id`, `widget_id: u32` | Button was clicked |
| `.slider_changed` | `panel_id`, `widget_id`, `val: f32` | Slider value changed |
| `.text_changed` | `panel_id`, `widget_id`, `text: []const u8` | Text input changed |
| `.checkbox_changed` | `panel_id`, `widget_id`, `val: u8` | Checkbox toggled |

### Schematic Events

| Variant | Payload | Description |
|---------|---------|-------------|
| `.schematic_changed` | — | Active schematic modified |
| `.selection_changed` | `instance_idx: i32` | Selected instance changed; `-1` = none |
| `.instance_data` | `idx`, `name`, `symbol` | One instance from `queryInstances` |
| `.net_data` | `idx`, `name` | One net from `queryNets` |

## Writer Commands

```zig
var w = Plugin.Writer.init(out_ptr[0..out_cap]);
// ... write messages ...
return if (w.overflow()) std.math.maxInt(usize) else w.pos;
```

### Panel & Status

```zig
w.registerPanel(.{
    .id      = "waveform",
    .title   = "Waveform Viewer",
    .vim_cmd = "wv",
    .layout  = .bottom_bar,
    .keybind = 'w',
});

w.setStatus("simulation complete");
```

### Logging

```zig
w.log(.info, "sim", "starting ngspice");
w.log(.warn, "sim", "convergence issues detected");
w.log(.err,  "sim", "ngspice exited with code 1");
```

### Schematic Editing

```zig
w.placeDevice("sky130_fd_pr__nfet_01v8", "M1", 100, 200);
w.addWire(100, 200, 100, 300);
w.setInstanceProp(3, "W", "2u");
```

### Queries (async — responses arrive next tick)

```zig
w.queryInstances();  // → .schematic_snapshot, .instance_data, .instance_prop
w.queryNets();       // → .schematic_snapshot, .net_data
```

### Persistent State

```zig
w.setState("last_file", path);
w.getState("last_file");
// → .state_response next tick
```

### Keybinds

```zig
w.registerKeybind('r', 0, "run-simulation");
// → .command { .tag = "run-simulation" } when pressed
```

## UI Widgets

Emit during `.draw_panel`. `id` must be unique within one draw call.

```zig
w.label("Threshold:", 0);
w.slider(threshold, 0.0, 1.0, 1);
w.button("Run Simulation", 2);
w.separator(3);
w.checkbox(show_labels, "Show net labels", 4);
w.progress(sim_progress, 5);
w.plot("Vout vs Time", time_arr, voltage_arr, 6);
w.image(rgba_data, 256, 256, 7);

// Horizontal layout
w.beginRow(8);
w.label("W:", 9);
w.button("2u", 10);
w.endRow(8);

// Collapsible section
w.collapsibleStart("Advanced", false, 11);
w.slider(gain, 0, 10, 12);
w.collapsibleEnd(11);
```

## PanelLayout

```zig
pub const PanelLayout = enum(u8) {
    overlay       = 0,   // floating overlay / modal
    left_sidebar  = 1,   // docked left
    right_sidebar = 2,   // docked right
    bottom_bar    = 3,   // docked bottom
};
```

## Vfs — Virtual Filesystem

Platform-agnostic FS API. Works identically on native and WASM.

```zig
const data = try Plugin.Vfs.readAlloc(alloc, "config.toml");
defer alloc.free(data);

try Plugin.Vfs.writeAll("output/result.json", json_bytes);
try Plugin.Vfs.makePath("my-plugin/cache");

if (!Plugin.Vfs.exists("cache/index.json")) {
    try buildIndex(alloc);
}

const listing = try Plugin.Vfs.listDir(alloc, "pdk/sky130A/libs.ref/");
defer listing.deinit(alloc);
for (listing.entries) |name| { ... }
```

## LogLevel

```zig
pub const LogLevel = enum(u8) { info = 0, warn = 1, err = 2 };
```
