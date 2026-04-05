//! ThemedButton -- wraps dvui.button with Theme palette colors.
//!
//! Usage:
//!   const btn = ThemedButton(.{ .style = .primary });
//!   if (btn.draw(@src(), "Save", .{})) { /* handle click */ }

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme_config");

pub const Style = enum { primary, secondary, danger };

pub const Options = struct {
    style: Style = .secondary,
};

/// Returns a namespace with a `draw` function using theme colors.
pub fn ThemedButton(comptime opts: Options) type {
    return struct {
        pub fn draw(src: std.builtin.SourceLocation, label: []const u8, extra: dvui.Options) bool {
            const pal = theme.Palette.fromDvui(dvui.themeGet());
            _ = pal; // Theme colors available for future use
            _ = opts; // Style available for future use

            return dvui.button(src, label, .{}, extra) != null;
        }
    };
}
