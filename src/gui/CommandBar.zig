//! Command bar — vim-style status bar at the bottom of the window.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("state").AppState;
const components = @import("components/root.zig");

const CmdBar = components.HorizontalBar(.{ .height = 26 });

/// Comptime table of status-message prefixes that indicate errors.
const error_prefixes = [_][]const u8{
    "Error", "Failed", "No active", "Cannot", "Unknown", "Usage:",
};

fn isErrorStatus(msg: []const u8) bool {
    if (std.mem.endsWith(u8, msg, "failed")) return true;
    inline for (error_prefixes) |prefix| {
        if (std.mem.startsWith(u8, msg, prefix)) return true;
    }
    return false;
}

/// Draw the command bar showing status, tool mode, and vim command input.
pub fn draw(app: *AppState) void {
    CmdBar.draw(drawContents, app, 0);
}

fn drawContents(app: *AppState) void {
    if (app.gui.command_mode) {
        var cmd_buf: [260]u8 = undefined;
        const cmd_text = std.fmt.bufPrint(&cmd_buf, ":{s}▌", .{app.gui.command_buf[0..app.gui.command_len]}) catch ":";
        dvui.labelNoFmt(@src(), cmd_text, .{}, .{ .style = .highlight });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        dvui.labelNoFmt(@src(), "Enter to run • Esc to cancel", .{}, .{ .id_extra = 1 });
        return;
    }

    // Status message — colour red for error-class prefixes.
    const msg_style: dvui.Theme.Style.Name = if (isErrorStatus(app.status_msg)) .err else .content;
    dvui.labelNoFmt(@src(), app.status_msg, .{}, .{ .style = msg_style });
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    {
        var hint_buf: [64]u8 = undefined;
        const snap_hint = std.fmt.bufPrint(&hint_buf, "snap:{d:.0}", .{app.tool.snap_size}) catch "snap:10";
        dvui.labelNoFmt(@src(), snap_hint, .{}, .{ .id_extra = 2 });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 10 });
    {
        const tool_name = app.tool.active.label();
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
