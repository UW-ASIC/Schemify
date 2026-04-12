# Plugin Examples Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recreate `plugins/examples/` with six working demo plugins (Zig, C, C++, Rust, Go, Python) that each register four panel layouts (overlay, left_sidebar, right_sidebar, bottom_bar) and demonstrate all available UI widgets.

**Architecture:** Each plugin is a self-contained directory under `plugins/examples/` with its own `build.zig` + `build.zig.zon` referencing `schemify_sdk = { path = "../../.." }`. All six implement the same "schematic assistant" concept so language syntax can be compared directly. Widgets are drawn on every `draw_panel` call (current host always sends panel_id=0). Two small doc fixes are also included.

**Tech Stack:** Zig 0.15.x, C99, C++17, Rust/cargo + schemify-plugin crate, TinyGo + schemify Go package, Python 3 + schemify package. Build orchestrated via `build_plugin_helper.zig` in each example's `build.zig`.

---

## Key API Reference

```
build.zig pattern:
  const sdk    = @import("schemify_sdk");   // Schemify's build.zig
  const helper = sdk.build_plugin_helper;
  const sdk_dep = b.dependency("schemify_sdk", .{});
  const ctx = helper.setup(b, sdk_dep);
  helper.addNativeAutoInstallRunStep(b, "plugin-name", sdk_dep, "plugin-name");

build.zig.zon schemify_sdk dep:
  .schemify_sdk = .{ .path = "../../.." }   // 3 levels up from plugins/examples/<lang>/

PluginIF.Writer methods (Zig):
  .registerPanel(PanelDef)   .setStatus(str)
  .label(str, id)            .button(str, id)       .separator(id)
  .slider(val, min, max, id) .checkbox(val, str, id) .progress(frac, id)
  .beginRow(id)              .endRow(id)
  .collapsibleStart(str, open, id)  .collapsibleEnd(id)

C header: sp_write_ui_label(w, text, strlen(text), id)  etc.
Panel IDs: host currently always sends panel_id=0; switch on it for future-proofing.
```

---

## File Map

**Create:**
- `plugins/examples/zig-demo/build.zig`
- `plugins/examples/zig-demo/build.zig.zon`
- `plugins/examples/zig-demo/src/main.zig`
- `plugins/examples/c-demo/build.zig`
- `plugins/examples/c-demo/build.zig.zon`
- `plugins/examples/c-demo/src/plugin.c`
- `plugins/examples/cpp-demo/build.zig`
- `plugins/examples/cpp-demo/build.zig.zon`
- `plugins/examples/cpp-demo/src/plugin.cpp`
- `plugins/examples/rust-demo/build.zig`
- `plugins/examples/rust-demo/build.zig.zon`
- `plugins/examples/rust-demo/Cargo.toml`
- `plugins/examples/rust-demo/src/lib.rs`
- `plugins/examples/go-demo/build.zig`
- `plugins/examples/go-demo/build.zig.zon`
- `plugins/examples/go-demo/src/go.mod`
- `plugins/examples/go-demo/src/plugin.go`
- `plugins/examples/python-demo/build.zig`
- `plugins/examples/python-demo/build.zig.zon`
- `plugins/examples/python-demo/plugin.py`

**Modify:**
- `docs/plugins/creating/quick-start.md` — fix `.path` depth
- `docs/plugins/api.md` — add `abi_version` to Descriptor

---

## Task 1: Zig Demo

**Files:**
- Create: `plugins/examples/zig-demo/build.zig`
- Create: `plugins/examples/zig-demo/build.zig.zon`
- Create: `plugins/examples/zig-demo/src/main.zig`

- [ ] **Step 1: Create build.zig.zon**

```
plugins/examples/zig-demo/build.zig.zon
```
```zig
.{
    .name = .@"zig-demo",
    .version = "0.1.0",
    .dependencies = .{
        .schemify_sdk = .{
            .path = "../../..",
        },
    },
    .paths = .{""},
}
```

- [ ] **Step 2: Create build.zig**

```
plugins/examples/zig-demo/build.zig
```
```zig
const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx = helper.setup(b, sdk_dep);
    const lib = helper.addNativePluginLibrary(b, ctx, "zig-demo", "src/main.zig");
    b.installArtifact(lib);
    helper.addNativeAutoInstallRunStep(b, "zig-demo", sdk_dep, "zig-demo");
}
```

- [ ] **Step 3: Create src/main.zig**

```
plugins/examples/zig-demo/src/main.zig
```
```zig
//! Schemify Plugin SDK — Zig demo
//!
//! Registers four panels (overlay, left_sidebar, right_sidebar, bottom_bar)
//! and draws a widget gallery on every draw_panel call.
//!
//! Build:  zig build
//! Run:    zig build run   (installs to ~/.config/Schemify/zig-demo/ and launches host)

const std = @import("std");
const PluginIF = @import("PluginIF");

// Plugin state — updated via slider/checkbox events.
var slider_val: f32 = 0.5;
var checkbox_val: bool = true;
var tick_count: u32 = 0;

/// The exported descriptor the host reads after dlopen().
export const schemify_plugin: PluginIF.Descriptor = .{
    .name = "zig-demo",
    .version_str = "0.1.0",
    .process = process,
};

fn process(
    in_ptr: [*]const u8,
    in_len: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) usize {
    var r = PluginIF.Reader.init(in_ptr[0..in_len]);
    var w = PluginIF.Writer.init(out_ptr[0..out_cap]);

    while (r.next()) |msg| {
        switch (msg) {
            .load => {
                // Register all four layout types. The host shows each in
                // its designated UI zone (floating / left / right / bottom).
                w.registerPanel(.{ .id = "zig-demo-overlay", .title = "Properties",   .vim_cmd = "zdprop",   .layout = .overlay,       .keybind = 0 });
                w.registerPanel(.{ .id = "zig-demo-left",    .title = "Components",   .vim_cmd = "zdcomp",   .layout = .left_sidebar,  .keybind = 0 });
                w.registerPanel(.{ .id = "zig-demo-right",   .title = "Design Stats", .vim_cmd = "zdstats",  .layout = .right_sidebar, .keybind = 0 });
                w.registerPanel(.{ .id = "zig-demo-bottom",  .title = "Status",       .vim_cmd = "zdstatus", .layout = .bottom_bar,    .keybind = 0 });
                w.setStatus("Zig Demo loaded");
            },
            .tick => tick_count +%= 1,
            .draw_panel => |dp| {
                // panel_id identifies which panel to draw. The host currently
                // sends 0 for all panels; switch on it when the host assigns
                // distinct IDs per registration.
                _ = dp.panel_id;
                drawWidgets(&w);
            },
            .slider_changed => |ev| {
                if (ev.widget_id == 3) slider_val = ev.val;
            },
            .checkbox_changed => |ev| {
                if (ev.widget_id == 4) checkbox_val = ev.val != 0;
            },
            else => {},
        }
    }

    return if (w.overflow()) std.math.maxInt(usize) else w.pos;
}

fn drawWidgets(w: *PluginIF.Writer) void {
    w.label("Selected: R1", 0);
    w.separator(1);
    // Slider and checkbox — widget IDs must be stable across frames.
    w.label("Value (kOhm)", 2);
    w.slider(slider_val, 0.0, 100.0, 3);
    w.checkbox(checkbox_val, "Show in netlist", 4);
    w.button("Apply", 5);
    w.separator(6);
    // Collapsible section demonstrates nested content.
    w.collapsibleStart("Component Browser", true, 7);
    w.label("  Resistors: R1, R2, R3", 8);
    w.label("  Capacitors: C1", 9);
    w.label("  Transistors: M1, M2", 10);
    w.collapsibleEnd(7);
    w.separator(11);
    // Progress bar shows a fraction in [0, 1].
    w.label("Design Stats", 12);
    w.progress(0.75, 13);
    // Horizontal row packs widgets side-by-side.
    w.beginRow(14);
    w.label("Nets: 12", 15);
    w.label("Comps: 8", 16);
    w.button("Simulate", 17);
    w.endRow(14);
}
```

- [ ] **Step 4: Verify build succeeds**

```bash
cd plugins/examples/zig-demo && zig build
```
Expected: `zig-out/lib/libzig-demo.so` created, no errors.

- [ ] **Step 5: Commit**

```bash
git add plugins/examples/zig-demo/
git commit -m "feat(examples): add zig-demo plugin with all 4 panel layouts"
```

---

## Task 2: C Demo

**Files:**
- Create: `plugins/examples/c-demo/build.zig`
- Create: `plugins/examples/c-demo/build.zig.zon`
- Create: `plugins/examples/c-demo/src/plugin.c`

- [ ] **Step 1: Create build.zig.zon**

```
plugins/examples/c-demo/build.zig.zon
```
```zig
.{
    .name = .@"c-demo",
    .version = "0.1.0",
    .dependencies = .{
        .schemify_sdk = .{
            .path = "../../..",
        },
    },
    .paths = .{""},
}
```

- [ ] **Step 2: Create build.zig**

```
plugins/examples/c-demo/build.zig
```
```zig
const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx = helper.setup(b, sdk_dep);
    const lib = helper.addCPlugin(b, ctx, sdk_dep, "c-demo", "src/plugin.c");
    b.installArtifact(lib);
    helper.addNativeAutoInstallRunStep(b, "c-demo", sdk_dep, "c-demo");
}
```

- [ ] **Step 3: Create src/plugin.c**

```
plugins/examples/c-demo/src/plugin.c
```
```c
/*
 * Schemify Plugin SDK — C demo
 *
 * Registers four panels and draws a widget gallery on every draw_panel call.
 *
 * Build:  zig build
 * Run:    zig build run
 */
#include "schemify_plugin.h"
#include <string.h>

static float  slider_val   = 0.5f;
static int    checkbox_val = 1;
static unsigned tick_count = 0;

static void draw_widgets(SpWriter* w) {
    sp_write_ui_label(w, "Selected: R1", 12, 0);
    sp_write_ui_separator(w, 1);
    sp_write_ui_label(w, "Value (kOhm)", 12, 2);
    sp_write_ui_slider(w, slider_val, 0.0f, 100.0f, 3);
    sp_write_ui_checkbox(w, (uint8_t)checkbox_val, "Show in netlist", 15, 4);
    sp_write_ui_button(w, "Apply", 5, 5);
    sp_write_ui_separator(w, 6);
    sp_write_ui_collapsible_start(w, "Component Browser", 17, 1, 7);
    sp_write_ui_label(w, "  Resistors: R1, R2, R3", 23, 8);
    sp_write_ui_label(w, "  Capacitors: C1", 16, 9);
    sp_write_ui_label(w, "  Transistors: M1, M2", 21, 10);
    sp_write_ui_collapsible_end(w, 7);
    sp_write_ui_separator(w, 11);
    sp_write_ui_label(w, "Design Stats", 12, 12);
    sp_write_ui_progress(w, 0.75f, 13);
    sp_write_ui_begin_row(w, 14);
    sp_write_ui_label(w, "Nets: 12", 8, 15);
    sp_write_ui_label(w, "Comps: 8", 8, 16);
    sp_write_ui_button(w, "Simulate", 8, 17);
    sp_write_ui_end_row(w, 14);
}

static size_t c_demo_process(
    const uint8_t* in_ptr, size_t in_len,
    uint8_t*       out_ptr, size_t out_cap)
{
    SpReader r = sp_reader_init(in_ptr, in_len);
    SpWriter w = sp_writer_init(out_ptr, out_cap);
    SpMsg msg;

    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {
        case SP_TAG_LOAD:
            sp_write_register_panel(&w,
                "c-demo-overlay", 15, "Properties",   10, "cdprop",   6, SP_LAYOUT_OVERLAY,       0);
            sp_write_register_panel(&w,
                "c-demo-left",    11, "Components",   10, "cdcomp",   6, SP_LAYOUT_LEFT_SIDEBAR,  0);
            sp_write_register_panel(&w,
                "c-demo-right",   12, "Design Stats", 12, "cdstats",  7, SP_LAYOUT_RIGHT_SIDEBAR, 0);
            sp_write_register_panel(&w,
                "c-demo-bottom",  13, "Status",        6, "cdstatus", 8, SP_LAYOUT_BOTTOM_BAR,    0);
            sp_write_set_status(&w, "C Demo loaded", 13);
            break;
        case SP_TAG_TICK:
            tick_count++;
            break;
        case SP_TAG_DRAW_PANEL:
            /* panel_id = msg.u.draw_panel.panel_id — switch on it when host
             * assigns distinct IDs per registration. Currently always 0. */
            draw_widgets(&w);
            break;
        case SP_TAG_SLIDER_CHANGED:
            if (msg.u.slider_changed.widget_id == 3)
                slider_val = msg.u.slider_changed.val;
            break;
        case SP_TAG_CHECKBOX_CHANGED:
            if (msg.u.checkbox_changed.widget_id == 4)
                checkbox_val = msg.u.checkbox_changed.val;
            break;
        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}

SCHEMIFY_PLUGIN("c-demo", "0.1.0", c_demo_process)
```

- [ ] **Step 4: Verify build succeeds**

```bash
cd plugins/examples/c-demo && zig build
```
Expected: `zig-out/lib/libc-demo.so` created, no errors.

- [ ] **Step 5: Commit**

```bash
git add plugins/examples/c-demo/
git commit -m "feat(examples): add c-demo plugin with all 4 panel layouts"
```

---

## Task 3: C++ Demo

**Files:**
- Create: `plugins/examples/cpp-demo/build.zig`
- Create: `plugins/examples/cpp-demo/build.zig.zon`
- Create: `plugins/examples/cpp-demo/src/plugin.cpp`

- [ ] **Step 1: Create build.zig.zon**

```
plugins/examples/cpp-demo/build.zig.zon
```
```zig
.{
    .name = .@"cpp-demo",
    .version = "0.1.0",
    .dependencies = .{
        .schemify_sdk = .{
            .path = "../../..",
        },
    },
    .paths = .{""},
}
```

- [ ] **Step 2: Create build.zig**

```
plugins/examples/cpp-demo/build.zig
```
```zig
const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx = helper.setup(b, sdk_dep);
    const lib = helper.addCppPlugin(b, ctx, sdk_dep, "cpp-demo", "src/plugin.cpp");
    b.installArtifact(lib);
    helper.addNativeAutoInstallRunStep(b, "cpp-demo", sdk_dep, "cpp-demo");
}
```

- [ ] **Step 3: Create src/plugin.cpp**

```
plugins/examples/cpp-demo/src/plugin.cpp
```
```cpp
/*
 * Schemify Plugin SDK — C++ demo
 *
 * Same four-panel showcase as c-demo but written in C++17.
 *
 * Build:  zig build
 * Run:    zig build run
 */
#include "schemify_plugin.h"

struct CppDemo {
    float    slider_val   = 0.5f;
    bool     checkbox_val = true;
    unsigned tick_count   = 0;

    void drawWidgets(SpWriter* w) const {
        sp_write_ui_label(w, "Selected: R1", 12, 0);
        sp_write_ui_separator(w, 1);
        sp_write_ui_label(w, "Value (kOhm)", 12, 2);
        sp_write_ui_slider(w, slider_val, 0.0f, 100.0f, 3);
        sp_write_ui_checkbox(w, static_cast<uint8_t>(checkbox_val),
                             "Show in netlist", 15, 4);
        sp_write_ui_button(w, "Apply", 5, 5);
        sp_write_ui_separator(w, 6);
        sp_write_ui_collapsible_start(w, "Component Browser", 17, 1, 7);
        sp_write_ui_label(w, "  Resistors: R1, R2, R3", 23, 8);
        sp_write_ui_label(w, "  Capacitors: C1", 16, 9);
        sp_write_ui_label(w, "  Transistors: M1, M2", 21, 10);
        sp_write_ui_collapsible_end(w, 7);
        sp_write_ui_separator(w, 11);
        sp_write_ui_label(w, "Design Stats", 12, 12);
        sp_write_ui_progress(w, 0.75f, 13);
        sp_write_ui_begin_row(w, 14);
        sp_write_ui_label(w, "Nets: 12", 8, 15);
        sp_write_ui_label(w, "Comps: 8", 8, 16);
        sp_write_ui_button(w, "Simulate", 8, 17);
        sp_write_ui_end_row(w, 14);
    }
};

static CppDemo g_plugin;

static size_t cpp_demo_process(
    const uint8_t* in_ptr, size_t in_len,
    uint8_t*       out_ptr, size_t out_cap)
{
    SpReader r = sp_reader_init(in_ptr, in_len);
    SpWriter w = sp_writer_init(out_ptr, out_cap);
    SpMsg    msg;

    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {
        case SP_TAG_LOAD:
            sp_write_register_panel(&w,
                "cpp-demo-overlay", 17, "Properties",   10, "cppdprop",   8, SP_LAYOUT_OVERLAY,       0);
            sp_write_register_panel(&w,
                "cpp-demo-left",    13, "Components",   10, "cppdcomp",   8, SP_LAYOUT_LEFT_SIDEBAR,  0);
            sp_write_register_panel(&w,
                "cpp-demo-right",   14, "Design Stats", 12, "cppdstats",  9, SP_LAYOUT_RIGHT_SIDEBAR, 0);
            sp_write_register_panel(&w,
                "cpp-demo-bottom",  15, "Status",        6, "cppdstatus",10, SP_LAYOUT_BOTTOM_BAR,    0);
            sp_write_set_status(&w, "C++ Demo loaded", 15);
            break;
        case SP_TAG_TICK:
            g_plugin.tick_count++;
            break;
        case SP_TAG_DRAW_PANEL:
            g_plugin.drawWidgets(&w);
            break;
        case SP_TAG_SLIDER_CHANGED:
            if (msg.u.slider_changed.widget_id == 3)
                g_plugin.slider_val = msg.u.slider_changed.val;
            break;
        case SP_TAG_CHECKBOX_CHANGED:
            if (msg.u.checkbox_changed.widget_id == 4)
                g_plugin.checkbox_val = msg.u.checkbox_changed.val != 0;
            break;
        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? static_cast<size_t>(-1) : w.pos;
}

SCHEMIFY_PLUGIN("cpp-demo", "0.1.0", cpp_demo_process)
```

- [ ] **Step 4: Verify build succeeds**

```bash
cd plugins/examples/cpp-demo && zig build
```
Expected: `zig-out/lib/libcpp-demo.so` created, no errors.

- [ ] **Step 5: Commit**

```bash
git add plugins/examples/cpp-demo/
git commit -m "feat(examples): add cpp-demo plugin with all 4 panel layouts"
```

---

## Task 4: Rust Demo

**Files:**
- Create: `plugins/examples/rust-demo/build.zig`
- Create: `plugins/examples/rust-demo/build.zig.zon`
- Create: `plugins/examples/rust-demo/Cargo.toml`
- Create: `plugins/examples/rust-demo/src/lib.rs`

- [ ] **Step 1: Create build.zig.zon**

```
plugins/examples/rust-demo/build.zig.zon
```
```zig
.{
    .name = .@"rust-demo",
    .version = "0.1.0",
    .dependencies = .{
        .schemify_sdk = .{
            .path = "../../..",
        },
    },
    .paths = .{""},
}
```

- [ ] **Step 2: Create build.zig**

```
plugins/examples/rust-demo/build.zig
```
```zig
const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    _ = sdk_dep; // Rust build uses cargo directly; sdk_dep is unused here
    // `addRustPlugin` calls `cargo build --release` and copies the .so to zig-out/lib/.
    helper.addRustPlugin(b, ".", "rust_demo");
    const ctx = helper.setup(b, b.dependency("schemify_sdk", .{}));
    _ = ctx;
    helper.addNativeAutoInstallRunStep(b, "rust-demo", b.dependency("schemify_sdk", .{}), "rust-demo");
}
```

- [ ] **Step 3: Create Cargo.toml**

```
plugins/examples/rust-demo/Cargo.toml
```
```toml
[package]
name    = "rust-demo"
version = "0.1.0"
edition = "2021"

[lib]
name       = "rust_demo"
crate-type = ["cdylib"]

[dependencies]
schemify-plugin = { path = "../../../tools/sdk/bindings/rust/schemify-plugin" }
```

- [ ] **Step 4: Create src/lib.rs**

```
plugins/examples/rust-demo/src/lib.rs
```
```rust
//! Schemify Plugin SDK — Rust demo
//!
//! Registers four panels and draws a widget gallery on every on_draw call.
//!
//! Build:  zig build        (invokes cargo build --release internally)
//! Run:    zig build run

use schemify_plugin::{InMsg, PanelDef, PanelLayout, Plugin, Writer};

struct RustDemo {
    slider_val:   f32,
    checkbox_val: bool,
    tick_count:   u32,
}

impl Default for RustDemo {
    fn default() -> Self {
        RustDemo {
            slider_val:   0.5,
            checkbox_val: true,
            tick_count:   0,
        }
    }
}

impl Plugin for RustDemo {
    fn on_load(&mut self, w: &mut Writer) {
        w.register_panel(&PanelDef { id: "rust-demo-overlay", title: "Properties",   vim_cmd: "rdprop",   layout: PanelLayout::Overlay,      keybind: 0 });
        w.register_panel(&PanelDef { id: "rust-demo-left",    title: "Components",   vim_cmd: "rdcomp",   layout: PanelLayout::LeftSidebar,  keybind: 0 });
        w.register_panel(&PanelDef { id: "rust-demo-right",   title: "Design Stats", vim_cmd: "rdstats",  layout: PanelLayout::RightSidebar, keybind: 0 });
        w.register_panel(&PanelDef { id: "rust-demo-bottom",  title: "Status",       vim_cmd: "rdstatus", layout: PanelLayout::BottomBar,    keybind: 0 });
        w.set_status("Rust Demo loaded!");
    }

    fn on_tick(&mut self, _dt: f32, _w: &mut Writer) {
        self.tick_count = self.tick_count.wrapping_add(1);
    }

    fn on_draw(&mut self, _panel_id: u16, w: &mut Writer) {
        // panel_id identifies which panel to draw; switch on it when the
        // host assigns distinct IDs per registration. Currently always 0.
        w.label("Selected: R1", 0);
        w.separator(1);
        w.label("Value (kOhm)", 2);
        w.slider(self.slider_val, 0.0, 100.0, 3);
        w.checkbox(self.checkbox_val, "Show in netlist", 4);
        w.button("Apply", 5);
        w.separator(6);
        w.collapsible_start("Component Browser", true, 7);
        w.label("  Resistors: R1, R2, R3", 8);
        w.label("  Capacitors: C1", 9);
        w.label("  Transistors: M1, M2", 10);
        w.collapsible_end(7);
        w.separator(11);
        w.label("Design Stats", 12);
        w.progress(0.75, 13);
        w.begin_row(14);
        w.label("Nets: 12", 15);
        w.label("Comps: 8", 16);
        w.button("Simulate", 17);
        w.end_row(14);
    }

    fn on_event(&mut self, ev: InMsg, _w: &mut Writer) {
        match ev {
            InMsg::SliderChanged   { widget_id: 3, val, .. } => self.slider_val   = val,
            InMsg::CheckboxChanged { widget_id: 4, val, .. } => self.checkbox_val = val,
            _ => {}
        }
    }
}

schemify_plugin::export_plugin!(RustDemo, "rust-demo", "0.1.0");
```

- [ ] **Step 5: Verify Cargo.toml parses**

```bash
cd plugins/examples/rust-demo && cargo metadata --no-deps 2>&1 | head -5
```
Expected: JSON metadata output, no "error" lines.

- [ ] **Step 6: Commit**

```bash
git add plugins/examples/rust-demo/
git commit -m "feat(examples): add rust-demo plugin with all 4 panel layouts"
```

---

## Task 5: Go Demo

**Files:**
- Create: `plugins/examples/go-demo/build.zig`
- Create: `plugins/examples/go-demo/build.zig.zon`
- Create: `plugins/examples/go-demo/src/go.mod`
- Create: `plugins/examples/go-demo/src/plugin.go`

- [ ] **Step 1: Create build.zig.zon**

```
plugins/examples/go-demo/build.zig.zon
```
```zig
.{
    .name = .@"go-demo",
    .version = "0.1.0",
    .dependencies = .{
        .schemify_sdk = .{
            .path = "../../..",
        },
    },
    .paths = .{""},
}
```

- [ ] **Step 2: Create build.zig**

```
plugins/examples/go-demo/build.zig
```
```zig
const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    // `addGoPlugin` invokes tinygo build -buildmode=c-shared and copies
    // the resulting .so to zig-out/lib/.
    helper.addGoPlugin(b, "src", "go_demo");
    const sdk_dep = b.dependency("schemify_sdk", .{});
    helper.addNativeAutoInstallRunStep(b, "go-demo", sdk_dep, "go-demo");
}
```

- [ ] **Step 3: Create src/go.mod**

```
plugins/examples/go-demo/src/go.mod
```
```
module github.com/uwasic/schemify/plugins/examples/go-demo

go 1.21

require github.com/uwasic/schemify v0.0.0-local

replace github.com/uwasic/schemify => ../../../..
```

- [ ] **Step 4: Create src/plugin.go**

```
plugins/examples/go-demo/src/plugin.go
```
```go
// Schemify Plugin SDK — Go demo
//
// Registers four panels and draws a widget gallery on every OnDraw call.
//
// Build:  zig build        (invokes tinygo build -buildmode=c-shared internally)
// Run:    zig build run
package main

import (
	schemify "github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify"
)

// GoDemo holds per-frame state updated via slider/checkbox events.
type GoDemo struct {
	sliderVal   float32
	checkboxVal bool
	tickCount   uint32
}

func (p *GoDemo) OnLoad(w *schemify.Writer) {
	w.RegisterPanel("go-demo-overlay", "Properties",   "gdprop",   schemify.LayoutOverlay,      0)
	w.RegisterPanel("go-demo-left",    "Components",   "gdcomp",   schemify.LayoutLeftSidebar,  0)
	w.RegisterPanel("go-demo-right",   "Design Stats", "gdstats",  schemify.LayoutRightSidebar, 0)
	w.RegisterPanel("go-demo-bottom",  "Status",       "gdstatus", schemify.LayoutBottomBar,    0)
	w.SetStatus("Go Demo loaded")
}

func (p *GoDemo) OnUnload(w *schemify.Writer) {}

func (p *GoDemo) OnTick(dt float32, w *schemify.Writer) {
	p.tickCount++
}

func (p *GoDemo) OnDraw(panelId uint16, w *schemify.Writer) {
	// panelId identifies which panel to draw; switch on it when the host
	// assigns distinct IDs per registration. Currently always 0.
	_ = panelId
	p.drawWidgets(w)
}

func (p *GoDemo) OnEvent(msg schemify.Msg, w *schemify.Writer) {
	switch d := msg.Data.(type) {
	case schemify.MsgSliderChanged:
		if d.WidgetId == 3 {
			p.sliderVal = d.Val
		}
	case schemify.MsgCheckboxChanged:
		if d.WidgetId == 4 {
			p.checkboxVal = d.Val
		}
	}
}

func (p *GoDemo) drawWidgets(w *schemify.Writer) {
	w.Label("Selected: R1", 0)
	w.Separator(1)
	w.Label("Value (kOhm)", 2)
	w.Slider(p.sliderVal, 0.0, 100.0, 3)
	w.Checkbox(p.checkboxVal, "Show in netlist", 4)
	w.Button("Apply", 5)
	w.Separator(6)
	w.CollapsibleStart("Component Browser", true, 7)
	w.Label("  Resistors: R1, R2, R3", 8)
	w.Label("  Capacitors: C1", 9)
	w.Label("  Transistors: M1, M2", 10)
	w.CollapsibleEnd(7)
	w.Separator(11)
	w.Label("Design Stats", 12)
	w.Progress(0.75, 13)
	w.BeginRow(14)
	w.Label("Nets: 12", 15)
	w.Label("Comps: 8", 16)
	w.Button("Simulate", 17)
	w.EndRow(14)
}

var plugin GoDemo = GoDemo{sliderVal: 0.5, checkboxVal: true}

//export schemify_process
func schemify_process(inPtr *byte, inLen uintptr, outPtr *byte, outCap uintptr) uintptr {
	return schemify.RunPlugin(&plugin, inPtr, inLen, outPtr, outCap)
}

func main() {}
```

- [ ] **Step 5: Commit**

```bash
git add plugins/examples/go-demo/
git commit -m "feat(examples): add go-demo plugin with all 4 panel layouts"
```

---

## Task 6: Python Demo

**Files:**
- Create: `plugins/examples/python-demo/build.zig`
- Create: `plugins/examples/python-demo/build.zig.zon`
- Create: `plugins/examples/python-demo/plugin.py`

- [ ] **Step 1: Create build.zig.zon**

```
plugins/examples/python-demo/build.zig.zon
```
```zig
.{
    .name = .@"python-demo",
    .version = "0.1.0",
    .dependencies = .{
        .schemify_sdk = .{
            .path = "../../..",
        },
    },
    .paths = .{""},
}
```

- [ ] **Step 2: Create build.zig**

```
plugins/examples/python-demo/build.zig
```
```zig
const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    // `addPythonPlugin` copies plugin.py to
    // ~/.config/Schemify/SchemifyPython/scripts/python-demo/
    helper.addPythonPlugin(
        b,
        "python-demo",
        sdk_dep,
        &.{"plugin.py"},
        null, // no requirements.txt
        "python-demo",
    );
}
```

- [ ] **Step 3: Create plugin.py**

```
plugins/examples/python-demo/plugin.py
```
```python
"""
Schemify Plugin SDK — Python demo

Registers four panels and draws a widget gallery on every on_draw call.

Deploy:  zig build run   (copies to ~/.config/Schemify/SchemifyPython/scripts/)
"""

import schemify


class PythonDemo(schemify.Plugin):
    def __init__(self) -> None:
        self.slider_val   = 0.5
        self.checkbox_val = True
        self.tick_count   = 0

    def on_load(self, w: schemify.Writer) -> None:
        w.register_panel("py-demo-overlay", "Properties",   "pydprop",   schemify.LAYOUT_OVERLAY,       0)
        w.register_panel("py-demo-left",    "Components",   "pydcomp",   schemify.LAYOUT_LEFT_SIDEBAR,  0)
        w.register_panel("py-demo-right",   "Design Stats", "pydstats",  schemify.LAYOUT_RIGHT_SIDEBAR, 0)
        w.register_panel("py-demo-bottom",  "Status",       "pydstatus", schemify.LAYOUT_BOTTOM_BAR,    0)
        w.set_status("Python Demo loaded")

    def on_tick(self, dt: float, w: schemify.Writer) -> None:
        self.tick_count += 1

    def on_draw(self, panel_id: int, w: schemify.Writer) -> None:
        # panel_id identifies which panel to draw; switch on it when the
        # host assigns distinct IDs per registration. Currently always 0.
        self._draw_widgets(w)

    def on_event(self, msg: dict, w: schemify.Writer) -> None:
        tag = msg.get("tag")
        if tag == schemify.TAG_SLIDER_CHANGED and msg.get("widget_id") == 3:
            self.slider_val = msg["val"]
        elif tag == schemify.TAG_CHECKBOX_CHANGED and msg.get("widget_id") == 4:
            self.checkbox_val = msg["val"]

    def _draw_widgets(self, w: schemify.Writer) -> None:
        w.label("Selected: R1", id=0)
        w.separator(id=1)
        w.label("Value (kOhm)", id=2)
        w.slider(self.slider_val, 0.0, 100.0, id=3)
        w.checkbox(self.checkbox_val, "Show in netlist", id=4)
        w.button("Apply", id=5)
        w.separator(id=6)
        w.collapsible_start("Component Browser", open=True, id=7)
        w.label("  Resistors: R1, R2, R3", id=8)
        w.label("  Capacitors: C1", id=9)
        w.label("  Transistors: M1, M2", id=10)
        w.collapsible_end(id=7)
        w.separator(id=11)
        w.label("Design Stats", id=12)
        w.progress(0.75, id=13)
        w.begin_row(id=14)
        w.label("Nets: 12", id=15)
        w.label("Comps: 8", id=16)
        w.button("Simulate", id=17)
        w.end_row(id=14)


_plugin = PythonDemo()


def schemify_process(in_bytes: bytes) -> bytes:
    return schemify.run_plugin(_plugin, in_bytes)
```

- [ ] **Step 4: Commit**

```bash
git add plugins/examples/python-demo/
git commit -m "feat(examples): add python-demo plugin with all 4 panel layouts"
```

---

## Task 7: Fix docs/plugins/creating/quick-start.md path depth

**Files:**
- Modify: `docs/plugins/creating/quick-start.md`

- [ ] **Step 1: Find the broken path references**

```bash
grep -n '\.path.*"\.\.' docs/plugins/creating/quick-start.md | head -20
```

- [ ] **Step 2: Fix each occurrence**

The file uses `.path = "../../"` where it should use `"../../.."` (examples live 3 levels deep: `plugins/examples/<lang>/`). Run:

```bash
sed -i 's|\.path = "\.\./\.\./"|.path = "../../.."|g' docs/plugins/creating/quick-start.md
```

- [ ] **Step 3: Verify no remaining occurrences of the wrong depth**

```bash
grep -n '"../../"' docs/plugins/creating/quick-start.md
```
Expected: no output (all occurrences replaced).

- [ ] **Step 4: Commit**

```bash
git add docs/plugins/creating/quick-start.md
git commit -m "fix(docs): correct schemify_sdk path depth in quick-start examples"
```

---

## Task 8: Fix docs/plugins/api.md Descriptor missing abi_version

**Files:**
- Modify: `docs/plugins/api.md`

- [ ] **Step 1: Find the Descriptor section**

```bash
grep -n "Descriptor" docs/plugins/api.md | head -10
```

- [ ] **Step 2: Read surrounding lines to get exact text**

Read the Descriptor struct block (look for `extern struct` or equivalent in the docs).

- [ ] **Step 3: Add abi_version as first field**

Find the Descriptor struct definition in the docs. It currently shows:
```
name:        [*:0]const u8,
version_str: [*:0]const u8,
process:     ProcessFn,
```

Replace with:
```
abi_version: u32 = ABI_VERSION,   // must equal 6; host rejects mismatches
name:        [*:0]const u8,
version_str: [*:0]const u8,
process:     ProcessFn,
```

Use Edit tool with the exact surrounding text for a unique match.

- [ ] **Step 4: Commit**

```bash
git add docs/plugins/api.md
git commit -m "fix(docs): add missing abi_version field to Descriptor documentation"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] Six examples (Zig, C, C++, Rust, Go, Python) — Tasks 1–6
- [x] All four panel layouts in each example — every plugin registers overlay, left_sidebar, right_sidebar, bottom_bar
- [x] Widget gallery (label, separator, slider, checkbox, button, progress, collapsible, beginRow/endRow) — in drawWidgets/draw_widgets/_draw_widgets
- [x] build.zig + build.zig.zon per example — each task creates both
- [x] `zig build` verify step in each task
- [x] Doc fix: quick-start.md path — Task 7
- [x] Doc fix: api.md Descriptor — Task 8

**Notes for executor:**
- The `rust-demo/build.zig` calls `addRustPlugin(b, ".", "rust_demo")` — the cargo dir is `"."` (the plugin root) and the install name `rust_demo` matches the `[lib] name` in Cargo.toml
- The `go-demo/src/go.mod` uses a `replace` directive pointing `../../..` (from `src/` 3 levels up to repo root then to `tools/sdk/bindings/tinygo/schemify/` via the module path). Adjust if TinyGo resolves the path differently.
- The `addNativeAutoInstallRunStep` installs to `~/.config/Schemify/<plugin_dir_name>/` and then runs `zig build run` in the Schemify host root.
