//! Keybinds help window — drawing only.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
const keybinds = @import("keybinds.zig");

// ── Local state ───────────────────────────────────────────────────────────── //

pub const State = struct {
    open: bool = false,
};

pub var state: State = .{};

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    _ = app;
    if (!state.open) return;

    var fw = dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{ .w = 500, .h = 400 } });
    defer fw.deinit();

    dvui.labelNoFmt(@src(), "Keyboard Shortcuts", .{}, .{ .style = .highlight });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    for (keybinds.static_keybinds, 0..) |kb, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
        defer row.deinit();

        var key_buf: [32]u8 = undefined;
        const ctrl_str: []const u8 = if (kb.ctrl) "Ctrl+" else "";
        const shift_str: []const u8 = if (kb.shift) "Shift+" else "";
        const alt_str: []const u8 = if (kb.alt) "Alt+" else "";
        const key_str = std.fmt.bufPrint(&key_buf, "{s}{s}{s}{s}", .{ ctrl_str, shift_str, alt_str, @tagName(kb.key) }) catch "?";
        dvui.labelNoFmt(@src(), key_str, .{}, .{ .min_size_content = .{ .w = 150 }, .id_extra = i });

        var action_buf: [64]u8 = undefined;
        const action_str: []const u8 = switch (kb.action) {
            .queue => |q| q.msg,
            .gui => |g| @tagName(g),
        };
        const action_text = std.fmt.bufPrint(&action_buf, "{s}", .{action_str}) catch "?";
        dvui.labelNoFmt(@src(), action_text, .{}, .{ .expand = .horizontal, .id_extra = i + 1000 });
    }

    if (dvui.button(@src(), "Close [Esc]", .{}, .{})) {
        state.open = false;
    }
}
