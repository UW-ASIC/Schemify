//! Shared types for Canvas sub-renderers.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme_config");
const st = @import("state");

pub const Point = [2]i32;
pub const Vec2 = @Vector(2, f32);
pub const Color = dvui.Color;
pub const Palette = theme.Palette;

pub const RenderViewport = struct {
    cx: f32,
    cy: f32,
    scale: f32,
    pan: [2]f32,
    bounds: dvui.Rect.Physical,
};

pub const CanvasEvent = union(enum) {
    none,
    click: Point,
    double_click: Point,
    right_click: struct { pixel: Vec2, world: Point },
};

/// Bundles allocator + viewport + palette for Canvas sub-renderers.
/// Per Claude's discretion: RenderContext reduces parameter count from 3-4 to 1.
pub const RenderContext = struct {
    allocator: std.mem.Allocator,
    vp: RenderViewport,
    pal: Palette,
    cmd_flags: st.CommandFlags,
};

// Drawing constants (moved from Renderer.zig bottom)
pub const grid_min_step_px: f32 = 3.0;
pub const grid_max_points: f32 = 16_000.0;
pub const wire_endpoint_radius: f32 = 2.5;
pub const wire_preview_dot_radius: f32 = 4.0;
pub const wire_preview_arm: f32 = 8.0;
pub const inst_hit_tolerance: f32 = 14.0;
pub const wire_hit_tolerance: f32 = 10.0;
