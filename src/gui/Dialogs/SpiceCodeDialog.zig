//! SPICE Code Block dialog — view and edit the schematic-level SPICE code block.
//!
//! The code block is emitted verbatim into the netlist after the subcircuit
//! definitions.  Use it for .param, .model, .include, or any other top-level
//! SPICE directives that apply to the whole schematic.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const actions = @import("../Actions.zig");

const AppState = st.AppState;
const components = @import("../Components/lib.zig");

const SpiceCodeWindow = components.FloatingWindow(.{
    .title = "SPICE Code Block",
    .min_w = 600,
    .min_h = 400,
    .modal = true,
});

// ── Public API ───────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    const sd = &app.gui.cold.spice_code_dialog;
    if (!sd.is_open) return;
    SpiceCodeWindow.draw(components.winRectPtr(&sd.win_rect), &sd.is_open, drawContents, app);
}

// ── Private rendering ─────────────────────────────────────────────────────── //

fn drawContents(app: *AppState) void {
    const sd = &app.gui.cold.spice_code_dialog;

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
    });
    defer body.deinit();

    dvui.labelNoFmt(@src(), "SPICE directives emitted verbatim into the netlist:", .{}, .{ .id_extra = 0 });
    _ = dvui.separator(@src(), .{ .id_extra = 1 });

    // Preview of current buffer length.
    {
        var info_buf: [64]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "{d} chars", .{sd.buf_len}) catch "";
        dvui.labelNoFmt(@src(), info, .{}, .{ .id_extra = 2, .style = .control });
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical });

    _ = dvui.separator(@src(), .{ .id_extra = 3 });

    // Bottom buttons.
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 4,
        });
        defer btns.deinit();

        if (dvui.button(@src(), "Apply", .{}, .{ .id_extra = 5 })) {
            const payload: @import("commands").Undoable = .{ .edit_spice_code = sd.buf[0..sd.buf_len] };
            actions.enqueue(app, .{ .undoable = payload }, "SPICE code block updated");
            sd.is_open = false;
        }
        if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = 6 })) {
            sd.is_open = false;
        }
    }
}
