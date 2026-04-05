//! ScrollableList -- scrollable item list with selection highlight.
//!
//! Usage:
//!   const list = ScrollableList(.{});
//!   var sl = list.begin(@src(), .{});
//!   defer sl.deinit();
//!   // render items inside scroll area

const std = @import("std");
const dvui = @import("dvui");

pub const Options = struct {
    /// Minimum visible height for the scroll area.
    min_height: f32 = 120,
};

/// Returns a namespace with `begin` for a scrollable list region.
pub fn ScrollableList(comptime opts: Options) type {
    return struct {
        pub const ScrollBox = dvui.ScrollAreaWidget;

        pub fn begin(src: std.builtin.SourceLocation, extra: dvui.Options) ScrollBox {
            _ = extra;
            return dvui.scrollArea(src, .{}, .{
                .expand = .both,
                .min_size_content = .{ .h = opts.min_height },
            });
        }
    };
}
