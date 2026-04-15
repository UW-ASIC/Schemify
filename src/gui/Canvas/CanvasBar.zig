//! Thin action bar below the canvas — SPICE code button.

const dvui = @import("dvui");
const st = @import("state");
const actions = @import("../Actions.zig");

const AppState = st.AppState;

pub fn draw(app: *AppState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        .min_size_content = .{ .h = 24 },
    });
    defer bar.deinit();

    // SPICE Code button — always available.
    if (dvui.button(@src(), "SPICE Code", .{}, .{ .id_extra = 0 })) {
        actions.enqueue(app, .{ .immediate = .open_spice_code_dialog }, "Opening SPICE code block editor");
    }
}
