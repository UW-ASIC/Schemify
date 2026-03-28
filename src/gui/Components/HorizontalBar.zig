//! HorizontalBar — fixed-height horizontal strip, comptime-parameterized.
//!
//! Usage:
//!   const Bar = HorizontalBar(.{ .height = 28 });
//!   Bar.draw(contentFn, app, 0);  // pass loop index instead of 0 in loops

const std = @import("std");
const dvui = @import("dvui");

// ── Comptime options ──────────────────────────────────────────────────────── //

pub const Options = struct {
    height: f32 = 28,
    /// Optional background color.  null → use theme default.
    bg_color: ?dvui.Color = null,
    /// Direction for child layout inside the bar.
    dir: dvui.enums.Direction = .horizontal,
};

// ── Public API ────────────────────────────────────────────────────────────── //

/// Returns a namespace with a single `draw` function parameterised by `opts`.
///
///   src                 — pass `@src()` at the call site so each bar gets a
///                         unique widget ID based on its caller's location.
///   comptime ContentFn  — `fn(ctx: Ctx) void`
///   ctx                 — arbitrary context forwarded to ContentFn
///   id_extra            — loop index or other unique value; pass 0 for
///                         singletons.  Forwarded to the outer dvui.box so
///                         that multiple bar instances in the same loop do not
///                         share a widget ID.
pub fn HorizontalBar(comptime opts: Options) type {
    return struct {
        pub fn draw(src: std.builtin.SourceLocation, comptime ContentFn: anytype, ctx: anytype, id_extra: usize) void {
            const layout_opts: dvui.Options = if (opts.bg_color) |c| .{
                .expand = .horizontal,
                .background = true,
                .color_fill = c,
                .min_size_content = .{ .h = opts.height },
                .id_extra = id_extra,
            } else .{
                .expand = .horizontal,
                .background = true,
                .min_size_content = .{ .h = opts.height },
                .id_extra = id_extra,
            };

            var bar = dvui.box(src, .{ .dir = opts.dir }, layout_opts);
            defer bar.deinit();
            ContentFn(ctx);
        }
    };
}
