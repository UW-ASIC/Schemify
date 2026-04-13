//! Grid dot and origin crosshair rendering.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme_config");

const types = @import("types.zig");
const h = @import("draw_helpers.zig");

const RenderContext = types.RenderContext;
const Triangles = dvui.Triangles;
const Vertex = dvui.Vertex;

// Grid-specific constants not shared with other renderers.
const grid_dot_large: f32 = 1.2;
const grid_dot_small: f32 = 0.7;
const grid_dot_threshold: f32 = 20.0;
const origin_arm_min: f32 = 6.0;
const origin_arm_max_scale: f32 = 12.0;

/// Draw grid dots across the canvas viewport.
///
/// All dots are batched into a single `Triangles` and submitted via one
/// `renderTriangles` call. The previous implementation emitted one
/// `dvui.Path.stroke` per dot — hundreds to thousands of render commands per
/// frame, each allocating a Path.Builder, triangulating two points, and
/// queuing a render command. On redraws (dialog drag, zoom, hover) that
/// cost dominated the whole frame and was the main cause of UI lag.
pub fn draw(ctx: *const RenderContext, snap_size: f32) void {
    const vp = ctx.vp;
    const pal = ctx.pal;

    const step = snap_size * vp.scale;
    if (step < types.grid_min_step_px) return;

    const ox = @mod(vp.cx - vp.pan[0] * vp.scale, step);
    const oy = @mod(vp.cy - vp.pan[1] * vp.scale, step);

    const cols_f = @max(1.0, @floor(vp.bounds.w / step) + 2.0);
    const rows_f = @max(1.0, @floor(vp.bounds.h / step) + 2.0);
    const total = cols_f * rows_f;
    const stride = if (total <= types.grid_max_points) 1.0 else @ceil(@sqrt(total / types.grid_max_points));
    const dstep = step * stride;
    if (!(dstep > 0)) return;

    const dot_r_base: f32 = blk: {
        const t = std.math.clamp((step - 10.0) / 20.0, 0.0, 1.0);
        break :blk grid_dot_small + (grid_dot_large - grid_dot_small) * t;
    };
    const dot_r: f32 = dot_r_base * theme.getGridDotSize();

    const x_start = vp.bounds.x + ox;
    const y_start = vp.bounds.y + oy;
    const x_end = vp.bounds.x + vp.bounds.w;
    const y_end = vp.bounds.y + vp.bounds.h;

    // Count dots first so the Triangles.Builder gets exact capacity (its
    // appendVertex uses appendAssumeCapacity). Using the same floating-point
    // loop condition as the fill pass keeps both passes in lockstep.
    var n_cols: usize = 0;
    {
        var x: f32 = x_start;
        while (x < x_end) : (x += dstep) n_cols += 1;
    }
    var n_rows: usize = 0;
    {
        var y: f32 = y_start;
        while (y < y_end) : (y += dstep) n_rows += 1;
    }
    const n_dots = n_cols * n_rows;
    if (n_dots == 0) return;

    const cw = dvui.currentWindow();
    const alloc = cw.lifo();

    var tb = Triangles.Builder.init(alloc, n_dots * 4, n_dots * 6) catch return;
    // `build()` transfers ownership to the returned Triangles, so we deinit
    // the Triangles, not the builder. If init succeeded but we bail before
    // build (unreachable here — fill loop can't error), we'd need to clean
    // up the builder itself.

    const col: dvui.Color.PMA = .fromColor(pal.grid_dot);

    var row: usize = 0;
    while (row < n_rows) : (row += 1) {
        const y = y_start + @as(f32, @floatFromInt(row)) * dstep;
        var col_i: usize = 0;
        while (col_i < n_cols) : (col_i += 1) {
            const x = x_start + @as(f32, @floatFromInt(col_i)) * dstep;

            const base: Vertex.Index = @intCast(tb.vertexes.items.len);
            // Vertex order: TL, BL, BR, TR — matches Path.addRect so
            // winding (0,1,2) + (0,2,3) is CCW in y-down space.
            tb.appendVertex(.{ .pos = .{ .x = x - dot_r, .y = y - dot_r }, .col = col });
            tb.appendVertex(.{ .pos = .{ .x = x - dot_r, .y = y + dot_r }, .col = col });
            tb.appendVertex(.{ .pos = .{ .x = x + dot_r, .y = y + dot_r }, .col = col });
            tb.appendVertex(.{ .pos = .{ .x = x + dot_r, .y = y - dot_r }, .col = col });
            tb.appendTriangles(&.{
                base,     base + 1, base + 2,
                base,     base + 2, base + 3,
            });
        }
    }

    var triangles = tb.build();
    defer triangles.deinit(alloc);

    dvui.renderTriangles(triangles, null) catch {};
}

/// Draw the origin crosshair (X/Y axis lines through world origin).
pub fn drawOrigin(ctx: *const RenderContext) void {
    const vp = ctx.vp;
    const pal = ctx.pal;

    const ox = vp.cx - vp.pan[0] * vp.scale;
    const oy = vp.cy - vp.pan[1] * vp.scale;
    const arm = @max(origin_arm_min, origin_arm_max_scale * @min(vp.scale, 1.0));

    if (ox < vp.bounds.x or ox > vp.bounds.x + vp.bounds.w) return;
    if (oy < vp.bounds.y or oy > vp.bounds.y + vp.bounds.h) return;

    h.strokeLine(ox - arm, oy, ox + arm, oy, 1.0, pal.origin);
    h.strokeLine(ox, oy - arm, ox, oy + arm, 1.0, pal.origin);
}
