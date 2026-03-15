//! renderer/common — shared types, constants, and low-level primitives.
//!
//! Imported by all renderer sub-modules; not exposed to external callers.

const std  = @import("std");
const dvui = @import("dvui");
pub const AppState = @import("state").AppState;
pub const CT       = @import("state").CT;

// Theme config: overrides set by the themes plugin via SET_CONFIG key="theme".
// Re-export the types and the apply helper so callers only need this one import.
const theme_cfg = @import("theme_config");
pub const ThemeOverrides   = theme_cfg.ThemeOverrides;
pub const applyThemeJson   = theme_cfg.applyJson;
/// Direct access to the mutable global for the renderer (read-only here).
pub fn getThemeOverrides() *const ThemeOverrides { return &theme_cfg.current_overrides; }

// ── Fixed-capacity array ──────────────────────────────────────────────────── //

/// Replaces std.BoundedArray (removed in Zig 0.15).
pub fn BoundedArray(comptime T: type, comptime cap: usize) type {
    return struct {
        buf: [cap]T = undefined,
        len: usize = 0,

        pub fn append(self: *@This(), val: T) error{Overflow}!void {
            if (self.len >= cap) return error.Overflow;
            self.buf[self.len] = val;
            self.len += 1;
        }

        pub fn constSlice(self: *const @This()) []const T {
            return self.buf[0..self.len];
        }
    };
}

// ── Layout constants ──────────────────────────────────────────────────────── //

pub const grid_min_step_px:     f32 = 3.0;
pub const grid_max_points:      f32 = 16_000.0;
pub const grid_dot_large:       f32 = 1.2;
pub const grid_dot_small:       f32 = 0.7;
pub const grid_dot_threshold:   f32 = 20.0;
pub const origin_arm_min:       f32 = 6.0;
pub const origin_arm_max_scale: f32 = 12.0;
pub const wire_endpoint_radius: f32 = 2.5;
pub const wire_preview_dot_radius: f32 = 4.0;
pub const wire_preview_arm:     f32 = 8.0;
pub const inst_hit_tolerance:   f32 = 14.0;
pub const wire_hit_tolerance:   f32 = 10.0;

// ── Color math ───────────────────────────────────────────────────────────── //

pub inline fn blend(a: dvui.Color, b: dvui.Color, w: u8) dvui.Color {
    const fw: u32 = w;
    const fa: u32 = 255 - fw;
    return .{
        .r = @intCast((a.r * fa + b.r * fw) / 255),
        .g = @intCast((a.g * fa + b.g * fw) / 255),
        .b = @intCast((a.b * fa + b.b * fw) / 255),
        .a = 255,
    };
}

pub inline fn colorScale(c: dvui.Color, fac: u32) dvui.Color {
    return .{
        .r = @intCast(@min(255, @as(u32, c.r) * fac / 255)),
        .g = @intCast(@min(255, @as(u32, c.g) * fac / 255)),
        .b = @intCast(@min(255, @as(u32, c.b) * fac / 255)),
        .a = c.a,
    };
}

pub inline fn withAlpha(c: dvui.Color, a: u8) dvui.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

// ── Palette ───────────────────────────────────────────────────────────────── //

pub const Palette = struct {
    canvas_bg:      dvui.Color,
    grid_dot:       dvui.Color,
    wire:           dvui.Color,
    wire_sel:       dvui.Color,
    wire_endpoint:  dvui.Color,
    inst_body:      dvui.Color,
    inst_sel:       dvui.Color,
    inst_pin:       dvui.Color,
    symbol_line:    dvui.Color,
    symbol_pin:     dvui.Color,
    wire_preview:   dvui.Color,
    origin:         dvui.Color,

    pub fn fromTheme(t: dvui.Theme) Palette {
        const focus  = t.focus;
        const hl     = t.highlight.fill orelse t.focus;
        const ctrl   = t.control.fill orelse t.fill;
        const win_bg = t.window.fill orelse t.fill;

        // Canvas background: slightly lighter fixed dark base for a modern EDA look.
        // Dark: RGB(22,22,28) rather than a pure scale of the theme window fill so
        // the canvas always reads as "schematic viewport", not "widget area".
        const canvas_bg = if (t.dark)
            dvui.Color{ .r = 22, .g = 22, .b = 28, .a = 255 }
        else
            colorScale(win_bg, 240);

        // Grid dots: more subtle / lower contrast so they don't compete with wires.
        // Alpha reduced from 200 → 120 in dark mode.
        const grid_dot = withAlpha(
            colorScale(t.border, if (t.dark) 130 else 160),
            if (t.dark) 120 else 160,
        );

        // Wires: brighter, more saturated cyan-blue reminiscent of KiCad dark.
        // Blend heavily toward a vivid cyan so wires pop against the dark bg.
        const wire = if (t.dark)
            blend(focus, .{ .r = 88, .g = 210, .b = 255, .a = 255 }, 120)
        else
            blend(focus, .{ .r = 0, .g = 40, .b = 120, .a = 255 }, 40);

        // Selected: warmer orange/amber — clearly distinct from the cyan wires.
        const wire_sel = if (t.dark)
            blend(hl, .{ .r = 255, .g = 165, .b = 50, .a = 255 }, 140)
        else
            blend(hl, .{ .r = 200, .g = 90,  .b = 0,  .a = 255 }, 90);

        // Wire endpoints: bright green, kept visible but smaller conceptually via
        // the radius constant (unchanged here — purely a color decision).
        const wire_endpoint = blend(focus, .{ .r = 50, .g = 255, .b = 130, .a = 255 }, 90);

        // Instance body: slightly more visible — blend more toward wire colour.
        const inst_body = blend(ctrl, wire, 60);

        // Instance pin markers: yellow-tinted.
        const inst_pin  = blend(t.text, .{ .r = 255, .g = 230, .b = 60, .a = 255 }, 90);

        // Symbol lines: bright white-grey at 90% so symbol geometry is clear.
        const symbol_line = colorScale(t.text, 230);

        // Symbol pins: keep the yellow-focus blend.
        const symbol_pin = blend(focus, .{ .r = 255, .g = 220, .b = 60, .a = 255 }, 100);

        // Wire preview: semi-transparent green-tinted highlight.
        const wire_preview = withAlpha(
            blend(hl, .{ .r = 80, .g = 255, .b = 120, .a = 255 }, 90),
            180,
        );

        const origin = withAlpha(t.border, if (t.dark) 190 else 170);

        var result = Palette{
            .canvas_bg     = canvas_bg,
            .grid_dot      = grid_dot,
            .wire          = wire,
            .wire_sel      = wire_sel,
            .wire_endpoint = wire_endpoint,
            .inst_body     = inst_body,
            .inst_sel      = wire_sel,
            .inst_pin      = inst_pin,
            .symbol_line   = symbol_line,
            .symbol_pin    = symbol_pin,
            .wire_preview  = wire_preview,
            .origin        = origin,
        };

        // Apply runtime plugin theme overrides (all fields optional).
        const ov = getThemeOverrides();
        if (ov.canvas_bg)      |rgb| result.canvas_bg     = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
        if (ov.grid_dot)       |rgba| result.grid_dot     = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
        if (ov.wire)           |rgb| result.wire          = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
        if (ov.wire_selected)  |rgb| { result.wire_sel = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 }; result.inst_sel = result.wire_sel; }
        if (ov.wire_endpoint)  |rgb| result.wire_endpoint = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
        if (ov.instance_body)  |rgb| result.inst_body     = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
        if (ov.instance_pin)   |rgb| result.inst_pin      = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
        if (ov.symbol_line)    |rgb| result.symbol_line   = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
        if (ov.wire_preview)   |rgba| result.wire_preview = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };

        return result;
    }
};

// ── Viewport ──────────────────────────────────────────────────────────────── //

pub const Viewport = struct {
    cx:     f32,
    cy:     f32,
    scale:  f32,
    pan:    [2]f32,
    bounds: dvui.Rect.Physical,
};

// ── World ↔ screen transforms ─────────────────────────────────────────────── //

/// World-to-pixel.
pub inline fn w2p(pt: CT.Point, vp: Viewport) @Vector(2, f32) {
    const world:  @Vector(2, f32) = @floatFromInt(pt);
    const pan:    @Vector(2, f32) = .{ vp.pan[0], vp.pan[1] };
    const s:      @Vector(2, f32) = @splat(vp.scale);
    const center: @Vector(2, f32) = .{ vp.cx, vp.cy };
    return center + (world - pan) * s;
}

/// Pixel-to-world with optional grid snap (pass 0 to disable).
pub inline fn p2w(pt: @Vector(2, f32), vp: Viewport, snap: f32) CT.Point {
    const center: @Vector(2, f32) = .{ vp.cx, vp.cy };
    const s:      @Vector(2, f32) = @splat(vp.scale);
    const pan:    @Vector(2, f32) = .{ vp.pan[0], vp.pan[1] };
    const world = (pt - center) / s + pan;
    const gs: f32 = if (snap > 0) snap else 1.0;
    return .{
        @intFromFloat(@round(world[0] / gs) * gs),
        @intFromFloat(@round(world[1] / gs) * gs),
    };
}

// ── DrawCmd tagged union ───────────────────────────────────────────────────── //

pub const DrawCmd = union(enum) {
    line:         struct { a: @Vector(2, f32), b: @Vector(2, f32), color: dvui.Color, width: f32 },
    dot:          struct { p: @Vector(2, f32), radius: f32,        color: dvui.Color },
    rect_outline: struct { min: @Vector(2, f32), max: @Vector(2, f32), color: dvui.Color, width: f32 },
    cross:        struct { p: @Vector(2, f32), arm: f32, width: f32, color: dvui.Color },
};
comptime { std.debug.assert(@sizeOf(DrawCmd) <= 64); }

// ── Layer enum + bucketed storage ─────────────────────────────────────────── //

pub const Layer = enum(u8) {
    grid_overlays = 0,
    wires,
    wire_endpoints,
    instances,
    selection,
    symbol_shapes,
    symbol_pins,
    overlay,
};
pub const N_LAYERS   = std.meta.fields(Layer).len;
pub const BUCKET_CAP = 512;

pub const Buckets = [N_LAYERS]BoundedArray(DrawCmd, BUCKET_CAP);

pub fn emptyBuckets() Buckets {
    var b: Buckets = undefined;
    for (&b) |*bucket| bucket.* = .{};
    return b;
}

pub inline fn push(buckets: *Buckets, layer: Layer, cmd: DrawCmd) void {
    buckets[@intFromEnum(layer)].append(cmd) catch {};
}

// ── Primitive helpers ─────────────────────────────────────────────────────── //

pub inline fn strokeLine(x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, col: dvui.Color) void {
    dvui.Path.stroke(.{
        .points = &.{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 } },
    }, .{ .thickness = thickness, .color = col });
}

pub inline fn strokeDot(p: @Vector(2, f32), radius: f32, col: dvui.Color) void {
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = p[0] - radius, .y = p[1] },
            .{ .x = p[0] + radius, .y = p[1] },
        },
    }, .{ .thickness = radius * 2.0, .color = col });
}

// ── Flush ─────────────────────────────────────────────────────────────────── //

pub fn flushCmd(cmd: DrawCmd) void {
    switch (cmd) {
        inline .line => |c| strokeLine(c.a[0], c.a[1], c.b[0], c.b[1], c.width, c.color),
        inline .dot  => |c| strokeDot(c.p, c.radius, c.color),
        inline .rect_outline => |c| dvui.Path.stroke(.{
            .points = &.{
                .{ .x = c.min[0], .y = c.min[1] },
                .{ .x = c.max[0], .y = c.min[1] },
                .{ .x = c.max[0], .y = c.max[1] },
                .{ .x = c.min[0], .y = c.max[1] },
                .{ .x = c.min[0], .y = c.min[1] },
            },
        }, .{ .thickness = c.width, .color = c.color }),
        inline .cross => |c| {
            strokeLine(c.p[0] - c.arm, c.p[1], c.p[0] + c.arm, c.p[1], c.width, c.color);
            strokeLine(c.p[0], c.p[1] - c.arm, c.p[0], c.p[1] + c.arm, c.width, c.color);
        },
    }
}

pub fn flushBuckets(buckets: *const Buckets) void {
    for (buckets) |*bucket| {
        for (bucket.constSlice()) |cmd| flushCmd(cmd);
    }
}

// ── Hit testing ───────────────────────────────────────────────────────────── //

pub fn nearestInstance(sch: *CT.Schematic, mp: @Vector(2, f32), vp: Viewport, tol: f32) ?usize {
    var best:   ?usize = null;
    var best_d2: f32   = tol * tol;
    for (sch.instances.items, 0..) |inst, i| {
        const d  = w2p(inst.pos, vp) - mp;
        const d2 = d[0] * d[0] + d[1] * d[1];
        if (d2 <= best_d2) { best = i; best_d2 = d2; }
    }
    return best;
}

pub fn nearestWire(sch: *CT.Schematic, mp: @Vector(2, f32), vp: Viewport, tol: f32) ?usize {
    var best:   ?usize = null;
    var best_d2: f32   = tol * tol;
    for (sch.wires.items, 0..) |w, i| {
        const d2 = pointSegmentDist2(mp, w2p(w.start, vp), w2p(w.end, vp));
        if (d2 <= best_d2) { best = i; best_d2 = d2; }
    }
    return best;
}

fn pointSegmentDist2(p: @Vector(2, f32), a: @Vector(2, f32), b: @Vector(2, f32)) f32 {
    const v  = b - a;
    const w  = p - a;
    const len2 = v[0] * v[0] + v[1] * v[1];
    if (len2 <= 0.0001) return w[0] * w[0] + w[1] * w[1];
    const t    = std.math.clamp((w[0] * v[0] + w[1] * v[1]) / len2, 0.0, 1.0);
    const proj = a + v * @as(@Vector(2, f32), @splat(t));
    const d    = p - proj;
    return d[0] * d[0] + d[1] * d[1];
}
