//! Instance properties dialog — view and edit component properties.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");

const AppState = st.AppState;

// ── Helpers ──────────────────────────────────────────────────────────────── //

/// Zero-cost cast from *WinRect to *dvui.Rect (identical layout: 4 x f32).
fn winRectPtr(wr: *st.WinRect) *dvui.Rect {
    return @ptrCast(wr);
}

// ── Public API ───────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    const pd = &app.gui.props_dialog;
    if (!pd.is_open) return;
    const title: [:0]const u8 = if (pd.view_only)
        "Instance Properties (read-only)"
    else
        "Instance Properties";

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &pd.is_open,
        .rect = winRectPtr(&pd.win_rect),
    }, .{
        .min_size_content = .{ .w = 380, .h = 260 },
    });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader(title, "", &pd.is_open));

    drawContents(app);
}

fn drawContents(app: *AppState) void {
    const pd = &app.gui.props_dialog;

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
    });
    defer body.deinit();

    // Header with instance info.
    {
        var hdr_buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "Instance #{d}", .{pd.inst_idx}) catch "Instance";
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

        if (!pd.view_only) {
            if (dvui.button(@src(), "Apply", .{}, .{ .id_extra = 4 })) {
                // TODO: apply changed properties via command queue
                app.status_msg = "Properties applied (stub)";
                pd.is_open = false;
            }
        }
        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 5 })) {
            pd.is_open = false;
        }
    }
}
