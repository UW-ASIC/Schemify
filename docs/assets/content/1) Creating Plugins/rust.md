# Rust Plugin Guide

The Rust SDK is `no_std` compatible with zero dependencies. Add it as a path dependency or copy `lib.rs` into your project.

> **Consider HTML first.** For anything beyond basic controls, `w.html_layout()` sends HTML to dvui for rendering. See [HTML Layout](html-layout).

---

## Setup

### Option A: Path dependency (recommended for in-tree plugins)

```toml
# Cargo.toml
[package]
name = "my-plugin"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
schemify = { path = "../../tools/plugins/rust", package = "schemify-plugin" }

[profile.release]
opt-level = "s"
lto = true
panic = "abort"
```

### Option B: Copy the SDK file

```sh
cp tools/plugins/rust/src/lib.rs my-plugin/src/schemify.rs
```

Then `mod schemify;` in your code.

---

## Plugin Manifest

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

[activation]
events = ["onPanel:demo"]

[build]
binary = "libmy_plugin.so"
```

---

## Minimal Plugin

```rust
use schemify::{Plugin, Writer, Layout, Msg};

#[derive(Default)]
struct MyPlugin {
    slider_val: f32,
}

impl Plugin for MyPlugin {
    fn on_load(&mut self, w: &mut Writer) {
        w.register_panel(b"demo", b"Demo", b"demo", Layout::LeftSidebar, 0);
        w.set_status(b"Plugin loaded");
        self.slider_val = 50.0;
    }

    fn on_draw_panel(&mut self, panel_id: u16, w: &mut Writer) {
        w.label(b"Resistance (kOhm)", 1);
        w.slider(self.slider_val, 0.0, 100.0, 2);
        w.button(b"Apply", 3);
    }

    fn on_slider_changed(&mut self, _: u16, widget_id: u32, val: f32, _w: &mut Writer) {
        if widget_id == 2 { self.slider_val = val; }
    }

    fn on_button_clicked(&mut self, _: u16, widget_id: u32, w: &mut Writer) {
        if widget_id == 3 {
            w.set_status(b"Applied!");
        }
    }
}

schemify::export_plugin!("my-plugin", "0.1.0", MyPlugin);
```

---

## Using HTML Layout

```rust
fn on_draw_panel(&mut self, panel_id: u16, w: &mut Writer) {
    w.html_layout(panel_id, br#"
        <div style="padding: 8px;">
            <h3>Simulation Results</h3>
            <table>
                <tr><td>Gain</td><td>42 dB</td></tr>
                <tr><td>BW</td><td>1.2 MHz</td></tr>
            </table>
            <button id="rerun">Re-run</button>
        </div>
    "#);
}
```

Use Rust's raw byte string literals (`br#"..."#`) for HTML embedding.

---

## Provider Pattern

```rust
impl Plugin for DRCPlugin {
    fn on_load(&mut self, w: &mut Writer) {
        w.register_panel(b"drc", b"DRC", b"drc", Layout::RightSidebar, 0);
        w.register_provider(b"hover_info");
        w.register_provider(b"validation");
    }

    fn on_provide_hover_info(&mut self, wx: i32, wy: i32, etype: u8,
                             eidx: i32, w: &mut Writer) {
        w.hover_info_result(b"Net: VDD\nFanout: 12");
    }

    fn on_provide_validation(&mut self, w: &mut Writer) {
        w.validation_result(1, b"Missing bulk connection", 100, 200, b"fix_bulk");
    }
}
```

---

## Canvas Drawing

```rust
impl Plugin for AnnotationPlugin {
    fn on_load(&mut self, w: &mut Writer) {
        w.register_panel(b"annotate", b"Annotate", b"annotate",
                        Layout::LeftSidebar, 0);
        w.subscribe_events(0x04); // EVENT_CANVAS
    }

    fn on_draw_panel(&mut self, _: u16, w: &mut Writer) {
        // Layer 16 = first plugin overlay layer
        w.canvas_rect(16, 100, 200, 50, 30, 0xFF000040, 0xFF0000FF, 2.0);
        w.canvas_text(16, 105, 195, 0xFFFFFFFF, 12.0, b"Critical Path");
        w.canvas_line(16, 150, 230, 300, 230, 0xFF0000FF, 2.0);
    }

    fn on_canvas_click(&mut self, wx: i32, wy: i32, button: u8,
                       mods: u8, w: &mut Writer) {
        w.set_status(b"Canvas clicked");
    }
}
```

---

## Schematic Mutation

```rust
fn generate(&mut self, w: &mut Writer) {
    w.begin_batch();  // single undo step
    w.place_device(b"nmos", b"M1", 100, 200);
    w.place_device(b"pmos", b"M2", 100, 100);
    w.add_wire(120, 200, 120, 100);
    w.set_instance_prop(0, b"W", b"1u");
    w.set_instance_prop(0, b"L", b"180n");
    w.end_batch();
}
```

---

## Inter-Plugin Communication

```rust
// Publisher
fn on_button_clicked(&mut self, _: u16, wid: u32, w: &mut Writer) {
    if wid == 1 {
        w.publish_message(b"my_plugin.data_ready", b"{\"value\": 42}");
    }
}

// Subscriber
fn on_plugin_message(&mut self, sender: &[u8], topic: &[u8],
                     payload: &[u8], w: &mut Writer) {
    if topic == b"my_plugin.data_ready" {
        // handle message
    }
}
```

---

## Build

```sh
cargo build --release
```

Output: `target/release/libmy_plugin.so`

### WASM

```sh
cargo build --release --target wasm32-unknown-unknown
```

---

## Install

```sh
mkdir -p ~/.config/Schemify/my-plugin
cp target/release/libmy_plugin.so ~/.config/Schemify/my-plugin/
cp plugin.toml ~/.config/Schemify/my-plugin/
```

---

## Plugin Trait

```rust
pub trait Plugin: Default {
    // Lifecycle
    fn on_load(&mut self, w: &mut Writer) {}
    fn on_unload(&mut self, w: &mut Writer) {}
    fn on_tick(&mut self, dt: f32, w: &mut Writer) {}
    fn on_poll(&mut self, w: &mut Writer) {}

    // Panel UI
    fn on_draw_panel(&mut self, panel_id: u16, w: &mut Writer) {}
    fn on_button_clicked(&mut self, panel_id: u16, widget_id: u32, w: &mut Writer) {}
    fn on_slider_changed(&mut self, panel_id: u16, widget_id: u32, val: f32, w: &mut Writer) {}
    fn on_checkbox_changed(&mut self, panel_id: u16, widget_id: u32, val: bool, w: &mut Writer) {}
    fn on_text_changed(&mut self, panel_id: u16, widget_id: u32, text: &[u8], w: &mut Writer) {}

    // Commands & state
    fn on_command(&mut self, tag: &[u8], payload: &[u8], w: &mut Writer) {}
    fn on_state_response(&mut self, key: &[u8], val: &[u8], w: &mut Writer) {}

    // Schematic events
    fn on_schematic_changed(&mut self, w: &mut Writer) {}
    fn on_selection_changed(&mut self, idx: i32, w: &mut Writer) {}
    fn on_hover(&mut self, x: i32, y: i32, elem_type: u8, elem_idx: i32,
                name: &[u8], w: &mut Writer) {}
    fn on_key_event(&mut self, key: u8, mods: u8, action: u8, w: &mut Writer) {}

    // Provider callbacks (v9)
    fn on_provide_hover_info(&mut self, wx: i32, wy: i32, etype: u8,
                             eidx: i32, w: &mut Writer) {}
    fn on_provide_completions(&mut self, context: &[u8], prefix: &[u8], w: &mut Writer) {}
    fn on_provide_diagnostics(&mut self, path: &[u8], w: &mut Writer) {}
    fn on_provide_actions(&mut self, etype: u8, eidx: i32, w: &mut Writer) {}
    fn on_provide_tooltip(&mut self, etype: u8, eidx: i32, w: &mut Writer) {}
    fn on_provide_decoration(&mut self, instance_idx: u32, w: &mut Writer) {}
    fn on_provide_netlist_hook(&mut self, format: &[u8], w: &mut Writer) {}
    fn on_provide_validation(&mut self, w: &mut Writer) {}

    // Canvas events (v9)
    fn on_canvas_click(&mut self, wx: i32, wy: i32, button: u8, mods: u8, w: &mut Writer) {}
    fn on_canvas_drag(&mut self, wx: i32, wy: i32, dx: i32, dy: i32,
                      button: u8, mods: u8, w: &mut Writer) {}
    fn on_canvas_scroll(&mut self, wx: i32, wy: i32, dx: f32, dy: f32, w: &mut Writer) {}

    // IPC (v9)
    fn on_plugin_message(&mut self, sender: &[u8], topic: &[u8],
                         payload: &[u8], w: &mut Writer) {}
}
```

---

## Writer Methods

```rust
// Commands
w.register_panel(id, title, vim_cmd, Layout::LeftSidebar, keybind);
w.set_status(b"msg");
w.push_command(b"zoom_fit", b"");
w.get_state(b"key");
w.set_state(b"key", b"val");
w.get_config(b"plugin_id", b"key");
w.set_config(b"plugin_id", b"key", b"val");
w.register_command(b"id", b"Display Name", b"Description");
w.subscribe_events(7);  // 1=hover, 2=keys, 4=canvas
w.consume_event();
w.yield_pending();
w.html_layout(panel_id, b"<h1>Hello</h1>");
w.log(level, b"tag", b"message");

// Widgets
w.label(b"text", id);
w.button(b"text", id);
w.separator(id);
w.slider(val, min, max, id);
w.checkbox(val, b"text", id);
w.progress(fraction, id);
w.text_input(b"hint", b"text", id);
w.text_area(b"hint", b"text", id);
w.begin_row(id);
w.end_row(id);
w.collapsible_start(b"label", open, id);
w.collapsible_end(id);
w.dropdown(b"Option A\nOption B\nOption C", 0, id);
w.table(b"Name\tValue", b"R1\t10k\nR2\t20k", id);
w.tab_bar(b"Tab 1\nTab 2\nTab 3", 0, id);

// Provider responses (v9)
w.register_provider(b"hover_info");
w.hover_info_result(b"Net: VDD\nFanout: 12");
w.completion_result(b"label", b"insert_text", b"detail");
w.diagnostic_result(severity, b"message", x, y);
w.action_result(b"label", b"command");
w.tooltip_result(b"text");
w.decoration_result(color, style);
w.validation_result(severity, b"msg", x, y, b"fix_cmd");

// Canvas drawing (v9)
w.canvas_clear_layer(16);
w.canvas_line(16, x0, y0, x1, y1, color, width);
w.canvas_rect(16, x, y, w, h, fill, stroke, stroke_width);
w.canvas_circle(16, cx, cy, r, fill, stroke);
w.canvas_text(16, x, y, color, size, b"text");
w.canvas_begin_group(16, b"name");
w.canvas_end_group(16);
w.canvas_set_transform(16, a, b, c, d, tx, ty);
w.canvas_reset_transform(16);

// Schematic mutation (v9)
w.begin_batch();
w.end_batch();
w.delete_instance(idx);
w.move_instance(idx, dx, dy);
w.rotate_instance(idx, rotation);
w.mirror_instance(idx, axis);
w.duplicate_instance(idx, dx, dy);
w.rename_instance(idx, b"name");
w.delete_wire(idx);
w.move_wire(idx, dx, dy);
w.merge_wires(a, b);
w.rename_net(idx, b"VDD");
w.undo();
w.redo();
w.clear_selection();
w.copy_selection();
w.paste(x, y);
w.cut_selection();
w.query_instance_at(x, y);
w.query_bounding_box();

// IPC (v9)
w.publish_message(b"topic", payload);
```

---

## Tips

- All string parameters are `&[u8]`, not `&str` — use `b"..."` byte literals
- The `export_plugin!` macro handles static initialization and the `extern "C"` export
- `no_std` is the default — the SDK uses no allocations or standard library features
- For WASM builds, `panic = "abort"` keeps the binary small
- Widget IDs must be unique within a panel and stable across frames
- `begin_batch()`/`end_batch()` wraps multiple mutations into a single undo step
- Provider registration should be done in `on_load()`
