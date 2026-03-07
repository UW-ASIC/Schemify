//! Tab bar — horizontal row of open schematic tabs with view-mode switcher.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
const actions = @import("actions.zig");

// ── Layout constants ──────────────────────────────────────────────────────── //

const TABBAR_HEIGHT: f32 = 30;

// ── Public API ────────────────────────────────────────────────────────────── //

/// Draw the tab bar showing all open schematics and view-mode buttons.
pub fn draw(app: *AppState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .min_size_content = .{ .h = TABBAR_HEIGHT },
    });
    defer bar.deinit();

    // Tab list
    for (app.schematics.items, 0..) |fio, idx| {
        const is_active = idx == app.active_idx;
        var name_buf: [64]u8 = undefined;
        const dirty_mark: []const u8 = if (fio.isDirty()) "● " else "";
        const label = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ dirty_mark, fio.comp.name }) catch fio.comp.name;

        if (is_active) {
            // Active tab - highlighted style
            if (dvui.button(@src(), label, .{}, .{ .style = .highlight, .id_extra = idx })) {
                // Already active, do nothing
            }
        } else {
            if (dvui.button(@src(), label, .{}, .{ .id_extra = idx })) {
                app.active_idx = idx;
                app.status_msg = "Switched tab";
            }
        }
    }

    // New tab button
    if (dvui.button(@src(), "+", .{}, .{ .id_extra = 9000 })) {
        actions.enqueue(app, .{ .new_tab = {} }, "New tab");
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // View mode selector
    {
        const sch_style: dvui.Theme.Style.Name = if (app.gui.view_mode == .schematic) .highlight else .control;
        const sym_style: dvui.Theme.Style.Name = if (app.gui.view_mode == .symbol) .highlight else .control;
        if (dvui.button(@src(), "Sch", .{}, .{ .style = sch_style, .id_extra = 9001 }))
            actions.runGuiCommand(app, .view_schematic);
        if (dvui.button(@src(), "Sym", .{}, .{ .style = sym_style, .id_extra = 9002 }))
            actions.runGuiCommand(app, .view_symbol);
    }

    // Close active tab button (only show when multiple tabs)
    if (app.schematics.items.len > 1) {
        if (dvui.button(@src(), "✕", .{}, .{ .style = .err, .id_extra = 9003 })) {
            actions.enqueue(app, .{ .close_tab = {} }, "Close tab");
        }
    }
}
