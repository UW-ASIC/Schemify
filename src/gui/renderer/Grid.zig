//! renderer/Grid — grid dots and origin cross drawing.

const c  = @import("common.zig");
const tc = @import("theme_config");

/// Draw the dot grid when `app.show_grid` is set.
pub fn draw(app: *c.AppState, pal: c.Palette, vp: c.Viewport) void {
    if (!app.show_grid) return;

    const snap  = app.tool.snap_size;
    const step  = snap * vp.scale;
    if (step < c.grid_min_step_px) return;

    const ox = @mod(vp.cx - vp.pan[0] * vp.scale, step);
    const oy = @mod(vp.cy - vp.pan[1] * vp.scale, step);

    const cols_f = @max(1.0, @floor(vp.bounds.w / step) + 2.0);
    const rows_f = @max(1.0, @floor(vp.bounds.h / step) + 2.0);
    const total  = cols_f * rows_f;
    const stride = if (total <= c.grid_max_points) 1.0 else @ceil(@sqrt(total / c.grid_max_points));
    const dstep  = step * stride;

    const dot_r_base: f32 = if (step > c.grid_dot_threshold) c.grid_dot_large else c.grid_dot_small;
    const dot_r: f32 = dot_r_base * tc.getGridDotSize();

    var x: f32 = vp.bounds.x + ox;
    while (x < vp.bounds.x + vp.bounds.w) : (x += dstep) {
        var y: f32 = vp.bounds.y + oy;
        while (y < vp.bounds.y + vp.bounds.h) : (y += dstep) {
            c.strokeDot(.{ x, y }, dot_r, pal.grid_dot);
        }
    }
}

/// Draw the origin crosshair.
pub fn drawOrigin(pal: c.Palette, vp: c.Viewport) void {
    const ox  = vp.cx - vp.pan[0] * vp.scale;
    const oy  = vp.cy - vp.pan[1] * vp.scale;
    const arm = @max(c.origin_arm_min, c.origin_arm_max_scale * @min(vp.scale, 1.0));

    if (ox < vp.bounds.x or ox > vp.bounds.x + vp.bounds.w) return;
    if (oy < vp.bounds.y or oy > vp.bounds.y + vp.bounds.h) return;

    c.strokeLine(ox - arm, oy, ox + arm, oy, 1.0, pal.origin);
    c.strokeLine(ox, oy - arm, ox, oy + arm, 1.0, pal.origin);
}
