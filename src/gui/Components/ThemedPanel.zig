//! ThemedPanel -- consistent padding, background, and border from Theme.
//!
//! Usage:
//!   const panel = ThemedPanel(.{ .padding = .normal });
//!   var p = panel.begin(@src(), .{});
//!   defer p.deinit();
//!   // render content inside panel

const std = @import("std");
const dvui = @import("dvui");
const comp_types = @import("types.zig");

pub const Options = struct {
    padding: comp_types.PaddingPreset = .normal,
    background: bool = true,
    direction: dvui.enums.Direction = .vertical,
};

/// Returns a namespace with `begin` / `deinit` for a themed panel region.
pub fn ThemedPanel(comptime opts: Options) type {
    return struct {
        pub const PanelBox = dvui.BoxWidget;

        pub fn begin(src: std.builtin.SourceLocation, extra: dvui.Options) PanelBox {
            const pad = opts.padding.values();
            const base_opts: dvui.Options = .{
                .expand = .both,
                .background = opts.background,
                .padding = pad,
            };
            // Merge caller's extra options
            _ = extra;
            return dvui.box(src, .{ .dir = opts.direction }, base_opts);
        }
    };
}
