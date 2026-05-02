# Plugin API Reference

Complete reference for the Schemify Plugin SDK (ABI v6).

SDK bindings for each language live in `tools/api/<language>/`. Copy the SDK file for your language into your project — no package manager needed.

## Wire Format

Every message uses the same framing:

```
[u8  tag       ]   message type
[u16 payload_sz]   payload byte count, little-endian
[N   bytes     ]   payload
```

**Strings inside payloads:** `[u16 len LE][N bytes]` (UTF-8, no null terminator)

**f32 arrays:** `[u32 count LE][count x 4 bytes LE]`

## Descriptor

Every plugin must export a `schemify_plugin` symbol:

**Zig:**
```zig
const sp = @import("schemify");

fn process(in: []const u8, out: []u8) usize { ... }

export const schemify_plugin = sp.descriptor("my-plugin", "0.1.0", process);
```

**C:**
```c
#include "lib.h"

static size_t my_process(const uint8_t* in, size_t in_len,
                          uint8_t* out, size_t out_cap) { ... }

SCHEMIFY_PLUGIN("my-plugin", "0.1.0", my_process)
```

**Rust:**
```rust
schemify::export_plugin!("my-plugin", "0.1.0", MyPlugin);
```

The underlying C struct:

```c
typedef struct {
    uint32_t          abi_version;   // must equal 6
    const char*       name;
    const char*       version_str;
    SchemifyProcessFn process;
} SchemifyDescriptor;
```

## ProcessFn

```c
typedef size_t (*SchemifyProcessFn)(
    const uint8_t* in_ptr,  size_t in_len,
    uint8_t*       out_ptr, size_t out_cap
);
```

Return bytes written, or `maxInt(usize)` / `(size_t)-1` if output buffer too small (host will retry with doubled buffer).

## Reader / Incoming Messages

**Zig:**
```zig
var r = sp.Reader.init(in);
while (r.next()) |msg| {
    switch (msg) { ... }
}
```

**C:**
```c
SpReader r = sp_reader_init(in_ptr, in_len);
SpMsg msg;
while (sp_reader_next(&r, &msg)) {
    switch (msg.tag) { ... }
}
```

**Rust:**
```rust
let mut r = schemify::Reader::new(in_buf);
while let Some(msg) = r.next() {
    match msg { ... }
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

**Zig:**
```zig
var w = sp.Writer.init(out);
// ... write messages ...
return w.finish() catch ~@as(usize, 0);
```

**C:**
```c
SpWriter w = sp_writer_init(out_ptr, out_cap);
// ... write messages ...
return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
```

### Panel & Status

```zig
w.registerPanel("waveform", "Waveform Viewer", "wv", .bottom_bar, 'w');
w.setStatus("simulation complete");
```

### Logging

```zig
w.log(0, "sim", "starting ngspice");     // info
w.log(1, "sim", "convergence issues");   // warn
w.log(2, "sim", "ngspice exited code 1"); // err
```

### Schematic Editing

```zig
w.placeDevice("sky130_fd_pr__nfet_01v8", "M1", 100, 200);
w.addWire(100, 200, 100, 300);
w.setInstanceProp(3, "W", "2u");
```

### Queries (async — responses arrive next tick)

```zig
w.queryInstances();  // -> .schematic_snapshot, .instance_data, .instance_prop
w.queryNets();       // -> .schematic_snapshot, .net_data
```

### Persistent State

```zig
w.setState("last_file", path);
w.getState("last_file");
// -> .state_response next tick
```

### Virtual Filesystem (DVUI.fs)

Plugins access files through the host's DVUI.fs abstraction — works identically on native (real disk) and web (browser virtual FS / IndexedDB). No direct disk access needed.

```zig
// Request a file read (async — response arrives next tick as .file_response)
w.fileReadRequest("config.toml");

// Write a file (fire-and-forget)
w.fileWrite("output/result.json", json_bytes);
```

The `.file_response` message delivers the data:
```zig
.file_response => |resp| {
    // resp.path = "config.toml"
    // resp.data = file contents as []const u8
},
```

This ensures plugins are portable across native and web without conditional compilation.

### Keybinds

```zig
w.registerKeybind('r', 0, "run-simulation");
// -> .command { .tag = "run-simulation" } when pressed
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
pub const Layout = enum(u8) {
    overlay       = 0,   // floating overlay / modal
    left_sidebar  = 1,   // docked left
    right_sidebar = 2,   // docked right
    bottom_bar    = 3,   // docked bottom
};
```

C equivalent:
```c
SP_LAYOUT_OVERLAY       = 0
SP_LAYOUT_LEFT_SIDEBAR  = 1
SP_LAYOUT_RIGHT_SIDEBAR = 2
SP_LAYOUT_BOTTOM_BAR    = 3
```

## Message Tag Reference

Full tag definitions in `tools/api/c/inc/lib.h` (header-only, self-contained C99).

| Range | Direction | Purpose |
|-------|-----------|---------|
| `0x01–0x1F` | Host -> Plugin | Lifecycle, UI events, schematic events |
| `0x80–0x9F` | Plugin -> Host | Commands (register panel, set status, etc.) |
| `0xA0–0xBF` | Plugin -> Host | UI widget emissions |
