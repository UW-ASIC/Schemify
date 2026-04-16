//! SPICE Netlist Viewer — shows the generated SPICE netlist for the active schematic.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");

const AppState = st.AppState;
const components = @import("../Components/lib.zig");

const NetlistWindow = components.FloatingWindow(.{
    .title = "SPICE Netlist",
    .min_w = 640,
    .min_h = 440,
    .modal = true,
});

// ── Public API ───────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    const sd = &app.gui.cold.spice_code_dialog;
    if (!sd.is_open) return;
    NetlistWindow.draw(components.winRectPtr(&sd.win_rect), &sd.is_open, drawContents, app);
}

// ── Private rendering ─────────────────────────────────────────────────────── //

fn drawContents(app: *AppState) void {
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
    });
    defer body.deinit();

    const netlist = app.last_netlist[0..app.last_netlist_len];

    if (netlist.len == 0) {
        dvui.labelNoFmt(@src(), "No netlist — open a schematic and try again.", .{}, .{
            .id_extra = 0,
            .style = .control,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
        return;
    }

    // Scrollable line-by-line view.
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 1 });
    defer scroll.deinit();

    var line_no: usize = 0;
    var rest = netlist;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..nl];
        rest = if (nl < rest.len) rest[nl + 1 ..] else &.{};

        dvui.labelNoFmt(@src(), line, .{}, .{
            .id_extra = line_no,
            .font      = .theme(.mono),
        });
        line_no += 1;
    }
}
