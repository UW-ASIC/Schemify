//! Selection highlight and wire preview overlay rendering.

const st = @import("state");

const types = @import("types.zig");
const vp_mod = @import("Viewport.zig");
const h = @import("draw_helpers.zig");

const RenderContext = types.RenderContext;

/// Draw the wire-placement preview overlay (start-point marker).
pub fn drawWirePreview(ctx: *const RenderContext, app: *st.AppState) void {
    const vp = ctx.vp;
    const pal = ctx.pal;

    const ws = app.tool.wire_start orelse return;
    const start = vp_mod.w2p(ws, vp);
    h.strokeDot(start, types.wire_preview_dot_radius, pal.wire_preview);
    h.strokeLine(start[0] - types.wire_preview_arm, start[1], start[0] + types.wire_preview_arm, start[1], 1.5, pal.wire_preview);
    h.strokeLine(start[0], start[1] - types.wire_preview_arm, start[0], start[1] + types.wire_preview_arm, 1.5, pal.wire_preview);
}
