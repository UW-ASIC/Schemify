//! Find / select dialog — search instances by name or symbol.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const components = @import("../Components/lib.zig");

const AppState = st.AppState;

const FindWindow = components.FloatingWindow(.{
    .title = "Find / Select",
    .min_w = 320,
    .min_h = 200,
    .modal = false,
});

// ── Helpers ────────────────────────────────────────────────────────���─────── //

/// Zero-cost cast from *WinRect to *dvui.Rect (identical layout: 4 x f32).
// ── Public API ───────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    const fd = &app.gui.cold.find_dialog;
    FindWindow.draw(components.winRectPtr(&fd.win_rect), &fd.is_open, drawContents, app);
}

fn drawContents(app: *AppState) void {
    const fd = &app.gui.cold.find_dialog;

    // Search input.
    dvui.labelNoFmt(@src(), "Search:", .{}, .{ .id_extra = 0 });

    // TODO: text entry for query_buf; for now show current query.
    {
        var hint_buf: [140]u8 = undefined;
        const hint = std.fmt.bufPrint(&hint_buf, "Query: \"{s}\"", .{fd.query_buf[0..fd.query_len]}) catch "Query: ...";
        dvui.labelNoFmt(@src(), hint, .{}, .{ .id_extra = 1, .style = .control });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 2 });

    // Match count.
    {
        var count_buf: [64]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d} match(es)", .{fd.result_count}) catch "?";
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
            fd.is_open = false;
        }
        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 7 })) {
            fd.is_open = false;
        }
    }
}
