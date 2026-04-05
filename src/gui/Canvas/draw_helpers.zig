//! Shared drawing primitives for Canvas sub-renderers.
//! Thin wrappers around dvui.Path.stroke for common shapes.

const std = @import("std");
const dvui = @import("dvui");
const types = @import("types.zig");

const Vec2 = types.Vec2;
const Color = types.Color;
const Point = types.Point;
const RenderViewport = types.RenderViewport;

pub inline fn strokeLine(x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, col: Color) void {
    dvui.Path.stroke(.{
        .points = &.{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 } },
    }, .{ .thickness = thickness, .color = col });
}

pub inline fn strokeDot(p: Vec2, radius: f32, col: Color) void {
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = p[0] - radius, .y = p[1] },
            .{ .x = p[0] + radius, .y = p[1] },
        },
    }, .{ .thickness = radius * 2.0, .color = col });
}

pub fn strokeRectOutline(tl: Vec2, br: Vec2, thickness: f32, col: Color) void {
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = tl[0], .y = tl[1] },
            .{ .x = br[0], .y = tl[1] },
            .{ .x = br[0], .y = br[1] },
            .{ .x = tl[0], .y = br[1] },
            .{ .x = tl[0], .y = tl[1] },
        },
    }, .{ .thickness = thickness, .color = col });
}

pub fn strokeCircle(center: Vec2, radius: f32, thickness: f32, col: Color) void {
    const n_segs: usize = 16;
    var prev: Vec2 = .{ center[0] + radius, center[1] };
    for (1..n_segs + 1) |si| {
        const angle = @as(f32, @floatFromInt(si)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(n_segs)));
        const cur: Vec2 = .{
            center[0] + radius * @cos(angle),
            center[1] - radius * @sin(angle),
        };
        strokeLine(prev[0], prev[1], cur[0], cur[1], thickness, col);
        prev = cur;
    }
}

pub fn strokeArc(center: Vec2, radius: f32, start_angle: i16, sweep_angle: i16, thickness: f32, col: Color) void {
    const start_deg: f32 = @floatFromInt(start_angle);
    const sweep_deg: f32 = @floatFromInt(sweep_angle);
    const n_segs: usize = @max(8, @as(usize, @intFromFloat(@abs(sweep_deg) / 10.0)));
    const start_rad = start_deg * std.math.pi / 180.0;
    const sweep_rad = sweep_deg * std.math.pi / 180.0;

    var prev: Vec2 = .{
        center[0] + radius * @cos(start_rad),
        center[1] - radius * @sin(start_rad),
    };
    for (1..n_segs + 1) |si| {
        const t: f32 = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(n_segs));
        const angle = start_rad + sweep_rad * t;
        const cur: Vec2 = .{
            center[0] + radius * @cos(angle),
            center[1] - radius * @sin(angle),
        };
        strokeLine(prev[0], prev[1], cur[0], cur[1], thickness, col);
        prev = cur;
    }
}

pub fn drawLabel(text: []const u8, x: f32, y: f32, col: Color, vp: RenderViewport, id_extra: usize) void {
    const size = @max(10.0, @min(18.0, 12.0 * vp.scale));
    var font = dvui.themeGet().font_body;
    font.size = size;
    const lh = size * 1.6 + 4;

    const text_w: f32 = @max(200, @as(f32, @floatFromInt(text.len)) * size * 0.8 + 40);

    if (x > vp.bounds.x + vp.bounds.w or x + text_w < vp.bounds.x) return;
    if (y > vp.bounds.y + vp.bounds.h or y + lh < vp.bounds.y) return;

    dvui.labelNoFmt(@src(), text, .{}, .{
        .rect = .{ .x = x, .y = y, .w = text_w, .h = lh },
        .color_text = col,
        .font = font,
        .id_extra = id_extra,
    });
}

pub fn applyRotFlip(px: f32, py: f32, rot: u2, flip: bool) [2]f32 {
    const x = if (flip) -px else px;
    const y = py;
    return switch (rot) {
        0 => .{ x, y },
        1 => .{ -y, x },
        2 => .{ -x, -y },
        3 => .{ y, -x },
    };
}
