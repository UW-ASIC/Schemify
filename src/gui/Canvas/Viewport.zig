//! Coordinate transforms between world space and pixel space.

const types = @import("types.zig");

const Point = types.Point;
const Vec2 = types.Vec2;
const RenderViewport = types.RenderViewport;

/// World-to-pixel: convert a world-space point to screen-space pixel coordinates.
pub inline fn w2p(pt: Point, vp: RenderViewport) Vec2 {
    const world: Vec2 = @floatFromInt(@as(@Vector(2, i32), pt));
    const pan: Vec2 = .{ vp.pan[0], vp.pan[1] };
    const s: Vec2 = @splat(vp.scale);
    const center: Vec2 = .{ vp.cx, vp.cy };
    return center + (world - pan) * s;
}

/// Pixel-to-world raw: convert pixel coordinates to unsnapped world-space floats.
pub inline fn p2w_raw(pt: Vec2, vp: RenderViewport) Vec2 {
    const center: Vec2 = .{ vp.cx, vp.cy };
    const s: Vec2 = @splat(vp.scale);
    const pan: Vec2 = .{ vp.pan[0], vp.pan[1] };
    return (pt - center) / s + pan;
}

/// Pixel-to-world snapped: convert pixel coordinates to grid-snapped world-space integers.
pub inline fn p2w(pt: Vec2, vp: RenderViewport, snap: f32) Point {
    const center: Vec2 = .{ vp.cx, vp.cy };
    const s: Vec2 = @splat(vp.scale);
    const pan: Vec2 = .{ vp.pan[0], vp.pan[1] };
    const world = (pt - center) / s + pan;
    const gs: f32 = if (snap > 0) snap else 1.0;
    return .{
        @intFromFloat(@round(world[0] / gs) * gs),
        @intFromFloat(@round(world[1] / gs) * gs),
    };
}
