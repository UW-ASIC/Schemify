//! Find / select dialog — search instances by name or symbol.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const components = @import("../Components/root.zig");

const AppState = st.AppState;

const FindWindow = components.FloatingWindow(.{
    .title = "Find / Select",
    .min_w = 320,
    .min_h = 200,
    .modal = false,
});

// ── Dialog state ───────────────────────────────────────────────────────────── //

var is_open: bool = false;
var query_buf: [128]u8 = [_]u8{0} ** 128;
var query_len: usize = 0;
var result_count: usize = 0;
var win_rect = dvui.Rect{ .x = 80, .y = 80, .w = 340, .h = 220 };

pub fn draw(app: *AppState) void {
    FindWindow.draw(&win_rect, &is_open, drawContents, app);
}

fn drawContents(app: *AppState) void {
    // Search input.
    dvui.labelNoFmt(@src(), "Search:", .{}, .{ .id_extra = 0 });

    // TODO: text entry for query_buf; for now show current query.
    {
        var hint_buf: [140]u8 = undefined;
        const hint = std.fmt.bufPrint(&hint_buf, "Query: \"{s}\"", .{query_buf[0..query_len]}) catch "Query: ...";
        dvui.labelNoFmt(@src(), hint, .{}, .{ .id_extra = 1, .style = .control });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 2 });

    // Match count.
    {
        var count_buf: [64]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d} match(es)", .{result_count}) catch "?";
        dvui.labelNoFmt(@src(), count_text, .{}, .{ .id_extra = 3 });
    }

    // TODO: result list — iterate matching instances and display them.

    _ = dvui.separator(@src(), .{ .id_extra = 4 });

    // Buttons.
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 5 });
        defer btns.deinit();

        if (dvui.button(@src(), "Select All Matches", .{}, .{ .id_extra = 6 })) {
            // TODO: select all matching instances in app.selection
            app.status_msg = "Select all matches: not yet implemented";
            is_open = false;
        }
        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 7 })) {
            is_open = false;
        }
    }
}
