//! Thin action bar below the canvas — SPICE code and Digital block buttons.

const std = @import("std");
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

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // Digital button — only enabled for .chn_prim files.
    const is_prim = blk: {
        const doc = app.active() orelse break :blk false;
        break :blk switch (doc.origin) {
            .chn_file => |path| std.mem.endsWith(u8, path, ".chn_prim"),
            else => false,
        };
    };

    if (is_prim) {
        if (dvui.button(@src(), "Digital", .{}, .{ .id_extra = 1 })) {
            actions.enqueue(app, .{ .immediate = .open_digital_block_dialog }, "Open digital block dialog");
        }
    } else {
        dvui.labelNoFmt(@src(), "Digital (prim only)", .{}, .{
            .id_extra = 1,
            .style = .control,
        });
    }
}