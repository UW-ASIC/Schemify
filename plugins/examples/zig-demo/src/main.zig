//! Schemify Plugin SDK — Zig demo
//!
//! Registers four panels (overlay, left_sidebar, right_sidebar, bottom_bar)
//! and draws a widget gallery on every draw_panel call.
//!
//! Build:  zig build
//! WASM:   zig build -Dbackend=web

const sp = @import("schemify");

// Plugin state — updated via slider/checkbox events.
var slider_val: f32 = 0.5;
var checkbox_val: bool = true;
var tick_count: u32 = 0;

fn process(in: []const u8, out: []u8) usize {
    var r = sp.Reader.init(in);
    var w = sp.Writer.init(out);

    while (r.next()) |msg| {
        switch (msg) {
            .load => {
                // Register all four layout types.
                w.registerPanel("zig-demo-overlay", "Properties", "zdprop", .overlay, 0);
                w.registerPanel("zig-demo-left", "Components", "zdcomp", .left_sidebar, 0);
                w.registerPanel("zig-demo-right", "Design Stats", "zdstats", .right_sidebar, 0);
                w.registerPanel("zig-demo-bottom", "Status", "zdstatus", .bottom_bar, 0);
                w.setStatus("Zig Demo loaded");
            },
            .tick => tick_count +%= 1,
            .draw_panel => |_| drawWidgets(&w),
            .slider_changed => |ev| {
                if (ev.widget_id == 3) slider_val = ev.val;
            },
            .checkbox_changed => |ev| {
                if (ev.widget_id == 4) checkbox_val = ev.val;
            },
            else => {},
        }
    }

    return w.finish() catch ~@as(usize, 0);
}

fn drawWidgets(w: *sp.Writer) void {
    w.label("Selected: R1", 0);
    w.separator(1);
    w.label("Value (kOhm)", 2);
    w.slider(slider_val, 0.0, 100.0, 3);
    w.checkbox(checkbox_val, "Show in netlist", 4);
    w.button("Apply", 5);
    w.separator(6);
    w.collapsibleStart("Component Browser", true, 7);
    w.label("  Resistors: R1, R2, R3", 8);
    w.label("  Capacitors: C1", 9);
    w.label("  Transistors: M1, M2", 10);
    w.collapsibleEnd(7);
    w.separator(11);
    w.label("Design Stats", 12);
    w.progress(0.75, 13);
    w.beginRow(14);
    w.label("Nets: 12", 15);
    w.label("Comps: 8", 16);
    w.button("Simulate", 17);
    w.endRow(14);
}

export const schemify_plugin = sp.descriptor("zig-demo", "0.1.0", process);
