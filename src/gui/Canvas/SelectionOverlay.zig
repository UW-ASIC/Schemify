//! Selection highlight and wire preview overlay rendering.

const dvui = @import("dvui");
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

/// Draw the rubber-band selection rectangle when active.
pub fn drawRubberBand(ctx: *const RenderContext, app: *st.AppState) void {
    const cs = &app.gui.hot.canvas;
    if (!cs.rubber_band_active) return;

    const vp = ctx.vp;
    const tl_world: types.Point = .{
        @min(cs.rubber_band_start[0], cs.rubber_band_end[0]),
        @min(cs.rubber_band_start[1], cs.rubber_band_end[1]),
    };
    const br_world: types.Point = .{
        @max(cs.rubber_band_start[0], cs.rubber_band_end[0]),
        @max(cs.rubber_band_start[1], cs.rubber_band_end[1]),
    };
    const tl = vp_mod.w2p(tl_world, vp);
    const br = vp_mod.w2p(br_world, vp);

    // Translucent blue fill using a closed stroked rect with thick stroke = fill approach.
    const fill_col = types.Color{ .r = 80, .g = 140, .b = 220, .a = 40 };
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = tl[0], .y = tl[1] },
            .{ .x = br[0], .y = tl[1] },
            .{ .x = br[0], .y = br[1] },
            .{ .x = tl[0], .y = br[1] },
            .{ .x = tl[0], .y = tl[1] },
        },
    }, .{ .thickness = 1, .color = fill_col });

    // Blue outline using strokeRectOutline helper.
    const outline_col = types.Color{ .r = 60, .g = 120, .b = 200, .a = 180 };
    h.strokeRectOutline(tl, br, 1.5, outline_col);
}
