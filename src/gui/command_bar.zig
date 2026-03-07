//! Command bar — vim-style status bar at the bottom of the window.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;

// ── Layout constants ──────────────────────────────────────────────────────── //

const COMMAND_BAR_HEIGHT: f32 = 26;

// ── Public API ────────────────────────────────────────────────────────────── //

/// Draw the command bar showing status, tool mode, and vim command input.
pub fn draw(app: *AppState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .min_size_content = .{ .h = COMMAND_BAR_HEIGHT },
    });
    defer bar.deinit();

    if (app.gui.command_mode) {
        // Command mode — show vim-style command input
        var cmd_buf: [260]u8 = undefined;
        const cmd_text = std.fmt.bufPrint(&cmd_buf, ":{s}▌", .{app.gui.command_buf[0..app.gui.command_len]}) catch ":";
        dvui.labelNoFmt(@src(), cmd_text, .{}, .{ .style = .highlight });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        dvui.labelNoFmt(@src(), "Enter to run • Esc to cancel", .{}, .{ .id_extra = 1 });
        return;
    }

    // Status message
    const is_err = isErrorMsg(app.status_msg);
    const msg_style: dvui.Theme.Style.Name = if (is_err) .err else .content;
    dvui.labelNoFmt(@src(), app.status_msg, .{}, .{ .style = msg_style });
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // Right side hints
    {
        var hint_buf: [64]u8 = undefined;
        const snap_hint = std.fmt.bufPrint(&hint_buf, "snap:{d:.0}", .{app.tool.snap_size}) catch "snap:10";
        dvui.labelNoFmt(@src(), snap_hint, .{}, .{ .id_extra = 2 });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 10 });
    {
        const tool_name = app.tool.label();
        const tool_style: dvui.Theme.Style.Name = switch (app.tool.active) {
            .wire, .line, .rect, .polygon, .arc, .circle, .text, .move, .pan => .highlight,
            .select => .control,
        };
        dvui.labelNoFmt(@src(), tool_name, .{}, .{ .style = tool_style, .id_extra = 3 });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 11 });
    {
        var view_buf: [24]u8 = undefined;
        const view_name = std.fmt.bufPrint(&view_buf, "{s}", .{@tagName(app.gui.view_mode)}) catch "sch";
        dvui.labelNoFmt(@src(), view_name, .{}, .{ .id_extra = 4 });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 12 });
    dvui.labelNoFmt(@src(), "[ : for commands ]", .{}, .{ .id_extra = 5 });
}

fn isErrorMsg(msg: []const u8) bool {
    return std.mem.startsWith(u8, msg, "Error") or
        std.mem.startsWith(u8, msg, "Failed") or
        std.mem.startsWith(u8, msg, "No active") or
        std.mem.startsWith(u8, msg, "Cannot") or
        std.mem.startsWith(u8, msg, "Unknown") or
        std.mem.startsWith(u8, msg, "Usage:") or
        std.mem.endsWith(u8, msg, "failed");
}
