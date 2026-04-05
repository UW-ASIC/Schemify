//! Grid dot and origin crosshair rendering.

const theme = @import("theme_config");

const types = @import("types.zig");
const h = @import("draw_helpers.zig");

const RenderContext = types.RenderContext;

// Grid-specific constants not shared with other renderers.
const grid_dot_large: f32 = 1.2;
const grid_dot_small: f32 = 0.7;
const grid_dot_threshold: f32 = 20.0;
const origin_arm_min: f32 = 6.0;
const origin_arm_max_scale: f32 = 12.0;

/// Draw grid dots across the canvas viewport.
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

    const dot_r_base: f32 = if (step > grid_dot_threshold) grid_dot_large else grid_dot_small;
    const dot_r: f32 = dot_r_base * theme.getGridDotSize();

    var x: f32 = vp.bounds.x + ox;
    while (x < vp.bounds.x + vp.bounds.w) : (x += dstep) {
        var y: f32 = vp.bounds.y + oy;
        while (y < vp.bounds.y + vp.bounds.h) : (y += dstep) {
            h.strokeDot(.{ x, y }, dot_r, pal.grid_dot);
        }
    }
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
