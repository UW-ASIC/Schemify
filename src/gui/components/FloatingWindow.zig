//! FloatingWindow — centered modal overlay window, comptime-parameterized.
//!
//! Usage:
//!   const fw = FloatingWindow(.{
//!       .title    = "My Dialog",
//!       .min_w    = 480,
//!       .min_h    = 320,
//!       .modal    = true,
//!   });
//!   fw.draw(&open_flag, contentFn, app);

const dvui = @import("dvui");

// ── Comptime options ──────────────────────────────────────────────────────── //

pub const Options = struct {
    title:  [:0]const u8,
    min_w:  f32 = 320,
    min_h:  f32 = 240,
    modal:  bool = true,
};

// ── Public API ────────────────────────────────────────────────────────────── //

/// Returns a namespace with a single `draw` function parameterised by `opts`.
/// The content callback receives `ctx` and must render all inner widgets.
///
///   comptime opts  — window title, min size, modality (zero-cost, baked in)
///   open           — pointer to the bool that gates visibility
///   comptime ContentFn — `fn(ctx: Ctx) void`
///   ctx            — arbitrary context forwarded to ContentFn
pub fn FloatingWindow(comptime opts: Options) type {
    return struct {
        /// Draw the floating window when `open.*` is true.
        /// `ContentFn` is a comptime function — no vtable, no indirect call.
        pub fn draw(
            win_rect: *dvui.Rect,
            open:     *bool,
            comptime ContentFn: anytype,
            ctx:      anytype,
        ) void {
            if (!open.*) return;

            var fwin = dvui.floatingWindow(@src(), .{
                .modal     = opts.modal,
                .open_flag = open,
                .rect      = win_rect,
            }, .{
                .min_size_content = .{ .w = opts.min_w, .h = opts.min_h },
            });
            defer fwin.deinit();

            fwin.dragAreaSet(dvui.windowHeader(opts.title, "", open));
            ContentFn(ctx);
        }
    };
}
