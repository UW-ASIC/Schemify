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
