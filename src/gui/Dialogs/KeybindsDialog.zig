//! Keybinds help window — displays all keyboard shortcuts.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const keybinds = @import("../Keybinds.zig");
const components = @import("../Components/lib.zig");

const AppState = st.AppState;

const KeybindsWindow = components.FloatingWindow(.{
    .title = "Keyboard Shortcuts",
    .min_w = 500,
    .min_h = 400,
    .modal = false,
});

// ── Local state ───────────────────────────────────────────────────────────── //

pub var open: bool = false;
var win_rect = dvui.Rect{ .x = 100, .y = 80, .w = 520, .h = 420 };

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    _ = app;
    KeybindsWindow.draw(&win_rect, &open, drawContents, {});
}

fn drawContents(_: void) void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    for (keybinds.static_keybinds, 0..) |kb, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
        defer row.deinit();

        var key_buf: [32]u8 = undefined;
        const ctrl_str: []const u8 = if (kb.ctrl) "Ctrl+" else "";
        const shift_str: []const u8 = if (kb.shift) "Shift+" else "";
        const alt_str: []const u8 = if (kb.alt) "Alt+" else "";
        const key_str = std.fmt.bufPrint(&key_buf, "{s}{s}{s}{s}", .{
            ctrl_str, shift_str, alt_str, @tagName(kb.key),
        }) catch "?";
        dvui.labelNoFmt(@src(), key_str, .{}, .{ .min_size_content = .{ .w = 150 }, .id_extra = i });

        const action_str: []const u8 = switch (kb.action) {
            .queue => |q| q.msg,
            .gui => |g| @tagName(g),
        };
        dvui.labelNoFmt(@src(), action_str, .{}, .{ .expand = .horizontal, .id_extra = i + 1000 });
    }

    if (dvui.button(@src(), "Close [Esc]", .{}, .{})) {
        open = false;
    }
}
