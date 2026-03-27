//! Library browser — browse and place/open cells from PDK dirs and config paths.
//!
//! Layout (floating window):
//!   +-------------------------------------------+
//!   | Library Browser                       [x] |
//!   +-------------------------------------------+
//!   | Search: [________________]                |
//!   |-------------------------------------------|
//!   | [SCH] inverter.chn                        |
//!   | [SYM] nand2.chn_sym                       |
//!   | [TB ] testbench.chn_tb                    |
//!   |-------------------------------------------|
//!   | [Place Selected]  [Open in Tab]  [Close]  |
//!   +-------------------------------------------+

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");

const AppState = st.AppState;

// ── Module-level state ───────────────────────────────────────────────────── //

var win_rect = dvui.Rect{ .x = 100, .y = 60, .w = 420, .h = 380 };
var search_buf: [128]u8 = [_]u8{0} ** 128;
var selected_idx: i32 = -1;
var scanned: bool = false;

// ── Public API ───────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    if (!app.open_library_browser) return;

    if (!scanned or app.rescan_library_browser) {
        // TODO: scan PDK directories and config paths for .chn, .chn_sym, .chn_tb
        scanned = true;
        app.rescan_library_browser = false;
    }

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = false,
        .open_flag = &app.open_library_browser,
        .rect = &win_rect,
    }, .{
        .min_size_content = .{ .w = 380, .h = 300 },
    });
    defer fwin.deinit();

    fwin.dragAreaSet(dvui.windowHeader("Library Browser", "", &app.open_library_browser));

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
    });
    defer body.deinit();

    // Search bar.
    dvui.labelNoFmt(@src(), "Search:", .{}, .{ .id_extra = 100 });
    // TODO: text entry for search_buf when dvui text entry API is wired

    _ = dvui.separator(@src(), .{ .id_extra = 101 });

    // Entry list area.
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 102 });
        defer scroll.deinit();

        // TODO: populate from scanned library entries
        dvui.labelNoFmt(@src(), "(No library entries scanned yet)", .{}, .{
            .id_extra = 103,
            .style = .control,
        });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 104 });

    // Bottom buttons.
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 105,
        });
        defer btns.deinit();

        if (dvui.button(@src(), "Place Selected", .{}, .{ .id_extra = 106 })) {
            // TODO: place selected symbol instance at cursor
            app.status_msg = "Place: not yet implemented";
        }
        if (dvui.button(@src(), "Open in Tab", .{}, .{ .id_extra = 107 })) {
            // TODO: open selected .chn file in a new tab
            app.status_msg = "Open: not yet implemented";
        }
        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 108 })) {
            app.open_library_browser = false;
        }
    }
}

pub fn reset() void {
    scanned = false;
    selected_idx = -1;
    @memset(&search_buf, 0);
}
