//! Instance properties dialog — view and edit component properties.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");

const AppState = st.AppState;

// ── Dialog state ──────────────────────────────────────────────────────────── //

var is_open: bool = false;
var view_only: bool = false;
var inst_idx: usize = 0;
var win_rect = dvui.Rect{ .x = 120, .y = 100, .w = 480, .h = 380 };

pub fn draw(app: *AppState) void {
    if (!is_open) return;
    const title: [:0]const u8 = if (view_only)
        "Instance Properties (read-only)"
    else
        "Instance Properties";

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &is_open,
        .rect = &win_rect,
    }, .{
        .min_size_content = .{ .w = 380, .h = 260 },
    });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader(title, "", &is_open));

    drawContents(app);
}

fn drawContents(app: *AppState) void {
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
    });
    defer body.deinit();

    // Header with instance info.
    {
        var hdr_buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "Instance #{d}", .{inst_idx}) catch "Instance";
        dvui.labelNoFmt(@src(), hdr, .{}, .{ .style = .control, .id_extra = 0 });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 1 });

    // TODO: iterate instance properties and show editable rows.
    // This requires access to the active document's schematic instances.
    dvui.labelNoFmt(@src(), "(Properties editor not yet implemented)", .{}, .{
        .id_extra = 2,
        .style = .control,
    });

    _ = dvui.spacer(@src(), .{ .expand = .vertical });

    // Bottom buttons.
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 3,
        });
        defer btns.deinit();

        if (!view_only) {
            if (dvui.button(@src(), "Apply", .{}, .{ .id_extra = 4 })) {
                // TODO: apply changed properties via command queue
                app.status_msg = "Properties applied (stub)";
                is_open = false;
            }
        }
        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 5 })) {
            is_open = false;
        }
    }
}
