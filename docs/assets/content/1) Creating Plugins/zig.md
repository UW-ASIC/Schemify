# Zig Plugin Guide

Zig is the same language Schemify is built with. The SDK is a single file — copy it alongside your plugin. No `build.zig.zon` needed, no package fetching.

> **Consider HTML first.** For complex layouts, `w.html()` sends HTML directly to dvui (the same UI library Schemify uses internally). See [HTML Layout](html-layout).

---

## Setup

```
my-plugin/
  src/main.zig
  schemify.zig      <-- copy from tools/plugins/zig/src/lib.zig
  plugin.toml       <-- manifest (required for v9)
  build.zig
```

Copy the SDK:
```sh
cp tools/plugins/zig/src/lib.zig my-plugin/schemify.zig
```

---

## Plugin Manifest

Every plugin needs a `plugin.toml` manifest:

```toml
[plugin]
id = "my-plugin"
name = "My Plugin"
version = "0.1.0"
author = "Your Name"
description = "A demo plugin"
abi = 9

[capabilities]
file_read_project = true
schematic_mutate = true

[[panels]]
id = "demo"
title = "Demo"
layout = "left_sidebar"
vim_command = "demo"

[[commands]]
tag = "demo_apply"
name = "Demo: Apply"
description = "Apply current settings"

[activation]
events = ["onPanel:demo"]

[build]
binary = "libmy_plugin.so"
```

---

## Minimal Plugin

```zig
const sp = @import("schemify");

var slider_val: f32 = 50.0;

fn process(in: []const u8, out: []u8) usize {
    var r = sp.Reader.init(in);
    var w = sp.Writer.init(out);

    while (r.next()) |msg| {
        switch (msg) {
            .load => {
                w.registerPanel(.{
                    .id = "demo", .title = "Demo",
                    .vim_cmd = "demo", .layout = .left_sidebar, .keybind = 0,
                });
                w.setStatus("Plugin loaded");
            },
            .draw_panel => {
                w.label("Resistance (kOhm)", 1);
                w.slider(slider_val, 0.0, 100.0, 2);
                w.button("Apply", 3);
            },
            .slider_changed => |ev| {
                if (ev.widget_id == 2) slider_val = ev.val;
            },
            .button_clicked => |ev| {
                if (ev.widget_id == 3) w.setStatus("Applied!");
            },
            else => {},
        }
    }

    return w.finish() catch ~@as(usize, 0);
}

export const schemify_plugin = sp.descriptor("my-plugin", "0.1.0", process);
```

---

## Using HTML Layout

```zig
.draw_panel => |ev| {
    w.html(ev.panel_id,
        \\<div style="padding: 8px;">
        \\  <h3>MOSFET Sizing</h3>
        \\  <table>
        \\    <tr><td>W</td><td>10u</td></tr>
        \\    <tr><td>L</td><td>180n</td></tr>
        \\    <tr><td>Vth</td><td>0.45V</td></tr>
        \\  </table>
        \\  <hr/>
        \\  <button id="optimize">Optimize</button>
        \\</div>
    );
},
```

Zig's multiline string literals (`\\`) make HTML embedding clean.

---

## Provider Pattern

Register as a provider to respond to host queries on demand:

```zig
.load => {
    w.registerPanel(.{ .id = "drc", .title = "DRC", .vim_cmd = "drc",
                       .layout = .right_sidebar, .keybind = 0 });
    w.registerProvider("hover_info");
    w.registerProvider("validation");
},
.provide_hover_info => |ev| {
    // ev.world_x, ev.world_y, ev.element_type, ev.element_idx
    w.hoverInfoResult("Net: VDD\nFanout: 12");
},
.provide_validation => {
    w.validationResult(1, "Missing bulk connection", 100, 200, "fix_bulk");
},
```

---

## Canvas Drawing

Draw overlays on the schematic canvas:

```zig
.load => {
    w.registerPanel(.{ .id = "annotate", .title = "Annotate", .vim_cmd = "annotate",
                       .layout = .left_sidebar, .keybind = 0 });
    w.subscribeEvents(0x04); // EVENT_CANVAS
},
.draw_panel => {
    // Layer 16 = first plugin overlay layer
    w.canvasRect(16, 100, 200, 50, 30, 0xFF000040, 0xFF0000FF, 2.0);
    w.canvasText(16, 105, 195, 0xFFFFFFFF, 12.0, "Critical Path");
    w.canvasLine(16, 150, 230, 300, 230, 0xFF0000FF, 2.0);
},
.canvas_click => |ev| {
    // ev.world_x, ev.world_y, ev.button, ev.mods
    w.setStatus("Canvas clicked");
},
```

---

## Schematic Mutation

Full CRUD with batch undo:

```zig
// Generate circuit in a single undo step
w.beginBatch();
w.placeDevice("nmos", "M1", 100, 200);
w.placeDevice("pmos", "M2", 100, 100);
w.addWire(120, 200, 120, 100);
w.setInstanceProp(0, "W", "1u");
w.setInstanceProp(0, "L", "180n");
w.endBatch();

// Other mutation operations
w.deleteInstance(0);
w.moveInstance(1, 50, 0);
w.rotateInstance(1, 1);
w.mirrorInstance(1, 0);
w.renameNet(0, "VDD");
w.duplicateInstance(1, 200, 0);
```

---

## Inter-Plugin Communication

```zig
// Publisher
w.publishMessage("my_plugin.data_ready", &result_bytes);

// Subscriber — handle in the message loop
.plugin_message => |ev| {
    // ev.sender, ev.topic, ev.payload
    if (std.mem.eql(u8, ev.topic, "my_plugin.data_ready")) {
        // handle message
    }
},
```

---

## build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const sdk = b.createModule(.{
        .root_source_file = b.path("schemify.zig"),
    });

    const lib = b.addLibrary(.{
        .name = "my-plugin",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.root_module.addImport("schemify", sdk);
    b.installArtifact(lib);

    // Install step: copy .so to ~/.config/Schemify/my-plugin/
    const copy = b.addSystemCommand(&.{ "sh", "-c",
        "mkdir -p \"$HOME/.config/Schemify/my-plugin\";" ++
        "cp zig-out/lib/*.so \"$HOME/.config/Schemify/my-plugin/\";" ++
        "echo \"Installed my-plugin\"",
    });
    copy.step.dependOn(b.getInstallStep());
    b.step("install-plugin", "Install .so to ~/.config/Schemify/").dependOn(&copy.step);
}
```

Build and install:
```sh
zig build                  # builds .so
zig build install-plugin   # copies to Schemify plugin dir
```

### WASM build

```zig
// Add this to build.zig for -Dbackend=web support
const Backend = enum { native, web };
const backend = b.option(Backend, "backend", "native or web") orelse .native;

if (backend == .web) {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    // ... add executable with wasm_target
}
```

```sh
zig build -Dbackend=web    # builds .wasm
```

---

## Reader API

```zig
var r = sp.Reader.init(input_buffer);
while (r.next()) |msg| {
    switch (msg) {
        // Lifecycle
        .load => |ev| { /* ev.project_dir: []const u8 */ },
        .unload => {},
        .tick => |ev| { /* ev.dt: f32 */ },
        .poll => { /* async work poll */ },

        // Panel UI
        .draw_panel => |ev| { /* ev.panel_id: u16 */ },
        .button_clicked => |ev| { /* ev.panel_id, ev.widget_id */ },
        .slider_changed => |ev| { /* ev.panel_id, ev.widget_id, ev.val: f32 */ },
        .checkbox_changed => |ev| { /* ev.panel_id, ev.widget_id, ev.val: u8 */ },
        .text_changed => |ev| { /* ev.panel_id, ev.widget_id, ev.text: []const u8 */ },

        // Commands & state
        .command => |ev| { /* ev.tag, ev.payload */ },
        .state_response => |ev| { /* ev.key, ev.val */ },
        .config_response => |ev| { /* ev.key, ev.val */ },

        // Schematic events
        .schematic_changed => {},
        .selection_changed => |ev| { /* ev.instance_idx: i32 */ },
        .instance_data => |ev| { /* ev.idx, ev.name, ev.symbol */ },
        .hover => |ev| { /* ev.world_x, ev.world_y, ev.element_name */ },
        .key_event => |ev| { /* ev.key, ev.mods, ev.action */ },

        // Provider requests (v9)
        .provide_hover_info => |ev| { /* ev.world_x, ev.world_y, ev.element_type, ev.element_idx */ },
        .provide_completions => |ev| { /* ev.context, ev.prefix */ },
        .provide_diagnostics => |ev| { /* ev.path */ },
        .provide_actions => |ev| { /* ev.element_type, ev.element_idx */ },
        .provide_tooltip => |ev| { /* ev.element_type, ev.element_idx */ },
        .provide_decoration => |ev| { /* ev.instance_idx */ },
        .provide_netlist_hook => |ev| { /* ev.format */ },
        .provide_validation => {},

        // Canvas events (v9)
        .canvas_click => |ev| { /* ev.world_x, ev.world_y, ev.button, ev.mods */ },
        .canvas_drag => |ev| { /* ev.world_x, ev.world_y, ev.dx, ev.dy, ev.button, ev.mods */ },
        .canvas_scroll => |ev| { /* ev.world_x, ev.world_y, ev.dx, ev.dy */ },

        // IPC (v9)
        .plugin_message => |ev| { /* ev.sender, ev.topic, ev.payload */ },

        else => {},
    }
}
```

---

## Writer API

### Commands

```zig
w.registerPanel(.{ .id = "id", .title = "Title", .vim_cmd = "vim_cmd",
                   .layout = .left_sidebar, .keybind = 0 });
w.setStatus("Status text");
w.pushCommand("zoom_fit", "");
w.getState("key");
w.setState("key", "value");
w.getConfig("plugin_id", "key");
w.setConfig("plugin_id", "key", "value");
w.registerCommand("id", "Display Name", "Description");
w.subscribeEvents(7);  // 1=hover, 2=keys, 4=canvas
w.consumeEvent();
w.yieldPending();      // signal async work in progress (host sends .poll)
w.registerKeybind(key, mods, "command_tag");
w.html(panel_id, "<h1>Hello</h1>");
w.fileReadRequest("/path/to/file");
w.fileWrite("/path/to/file", data);
w.log(.info, "tag", "message");
w.placeDevice("symbol", "name", x, y);
w.addWire(x0, y0, x1, y1);
w.setInstanceProp(idx, "W", "1u");
w.queryInstances();
w.queryNets();
```

### Widgets

```zig
w.label("text", id);
w.button("text", id);
w.separator(id);
w.slider(val, min, max, id);
w.checkbox(val, "text", id);
w.progress(fraction, id);
w.textInput("hint", "text", id);
w.textArea("hint", "text", id);
w.beginRow(id);
w.endRow(id);
w.collapsibleStart("label", open, id);
w.collapsibleEnd(id);
w.tooltip("text", id);
w.dropdown("Option A\nOption B\nOption C", 0, id);
w.table("Name\tValue", "R1\t10k\nR2\t20k", id);
w.tabBar("Tab 1\nTab 2\nTab 3", 0, id);
w.plot("title", xs_slice, ys_slice, id);
w.image(pixel_data, width, height, id);
```

### Provider Responses (v9)

```zig
w.registerProvider("hover_info");
w.hoverInfoResult("Net: VDD\nFanout: 12");
w.completionResult("label", "insert_text", "detail");
w.diagnosticResult(severity, "message", x, y);
w.actionResult("Fix DRC", "fix_drc_command");
w.tooltipResult("Tooltip text");
w.decorationResult(0xFF0000FF, 1);
w.netlistHookResult(modified_netlist);
w.validationResult(severity, "msg", x, y, "fix_command");
```

### Canvas Drawing (v9)

```zig
w.canvasClearLayer(16);
w.canvasLine(16, x0, y0, x1, y1, color, width);
w.canvasRect(16, x, y, w_, h, fill, stroke, stroke_width);
w.canvasCircle(16, cx, cy, r, fill, stroke);
w.canvasText(16, x, y, color, size, "text");
w.canvasPolyline(16, color, width, points);
w.canvasPolygon(16, fill, stroke, points);
w.canvasArc(16, cx, cy, r, start_angle, end_angle, color, width);
w.canvasImage(16, x, y, w_, h, pixels);
w.canvasPath(16, fill, stroke, stroke_width, "M 0 0 L 10 10");
w.canvasBeginGroup(16, "group_name");
w.canvasEndGroup(16);
w.canvasSetTransform(16, a, b, c, d, tx, ty);
w.canvasResetTransform(16);
```

### Schematic Mutation (v9)

```zig
w.beginBatch();
w.endBatch();
w.deleteInstance(idx);
w.moveInstance(idx, dx, dy);
w.rotateInstance(idx, rotation);
w.mirrorInstance(idx, axis);
w.duplicateInstance(idx, dx, dy);
w.renameInstance(idx, "new_name");
w.setInstanceSymbol(idx, "symbol");
w.getInstanceProps(idx);
w.deleteInstanceProp(idx, "key");
w.deleteWire(idx);
w.moveWire(idx, dx, dy);
w.splitWire(idx, x, y);
w.mergeWires(a, b);
w.renameNet(idx, "VDD");
w.queryNetConnections(idx);
w.undoCmd();
w.redoCmd();
w.selectInstances(indices);
w.selectWires(indices);
w.selectArea(x, y, w_, h);
w.clearSelection();
w.copySelection();
w.cutSelection();
w.paste(x, y);
w.queryInstanceAt(x, y);
w.queryWireAt(x, y);
w.queryBoundingBox();
w.queryViewport();
w.queryInstancePins(idx);
```

### IPC (v9)

```zig
w.publishMessage("topic.name", payload_bytes);
```

---

## Tips

- No allocations in the SDK — everything reads/writes directly to the shared buffer
- `w.finish()` returns `error.Overflow` if the buffer was too small
- Use `comptime` to generate descriptors — the `sp.descriptor()` call is evaluated at compile time
- Widget IDs must be unique per panel and stable across frames
- The SDK is `pub` — you can inspect the `Tag` enum, `InMsg` union, etc. for advanced use
- `beginBatch()`/`endBatch()` wraps multiple mutations into a single undo step
- Provider registration should be done at load time
