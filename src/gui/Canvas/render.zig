//! Canvas rendering primitives — consolidates Grid, Viewport transforms,
//! LineBatch, draw helpers, and label queue into one file.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme_config");

const types = @import("types.zig");
const Vec2 = types.Vec2;
const Color = types.Color;
const Point = types.Point;
const RenderViewport = types.RenderViewport;
const Vertex = dvui.Vertex;

// ═══════════════════════════════════════════════════════════════════════════
// Viewport transforms — world <-> pixel
// ═══════════════════════════════════════════════════════════════════════════

pub inline fn w2p(pt: Point, vp: RenderViewport) Vec2 {
    const world: Vec2 = @floatFromInt(@as(@Vector(2, i32), pt));
    const pan: Vec2 = .{ vp.pan[0], vp.pan[1] };
    const s: Vec2 = @splat(vp.scale);
    const center: Vec2 = .{ vp.cx, vp.cy };
    return center + (world - pan) * s;
}

pub inline fn p2w_raw(pt: Vec2, vp: RenderViewport) Vec2 {
    const center: Vec2 = .{ vp.cx, vp.cy };
    const s: Vec2 = @splat(vp.scale);
    const pan: Vec2 = .{ vp.pan[0], vp.pan[1] };
    return (pt - center) / s + pan;
}

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

// ═══════════════════════════════════════════════════════════════════════════
// Rotation / flip helper
// ═══════════════════════════════════════════════════════════════════════════

pub fn applyRotFlip(px: f32, py: f32, rot: u2, flip: bool) [2]f32 {
    const x = if (flip) -px else px;
    return switch (rot) {
        0 => .{ x, py },
        1 => .{ -py, x },
        2 => .{ -x, -py },
        3 => .{ py, -x },
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Immediate stroke helpers (for overlays — few calls per frame)
// ═══════════════════════════════════════════════════════════════════════════

pub inline fn strokeLine(x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, col: Color) void {
    dvui.Path.stroke(.{
        .points = &.{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 } },
    }, .{ .thickness = thickness, .color = col });
}

pub inline fn strokeDot(p: Vec2, radius: f32, col: Color) void {
    dvui.Path.stroke(.{
        .points = &.{ .{ .x = p[0] - radius, .y = p[1] }, .{ .x = p[0] + radius, .y = p[1] } },
    }, .{ .thickness = radius * 2.0, .color = col });
}

pub fn strokeRectOutline(tl: Vec2, br: Vec2, thickness: f32, col: Color) void {
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = tl[0], .y = tl[1] }, .{ .x = br[0], .y = tl[1] },
            .{ .x = br[0], .y = br[1] }, .{ .x = tl[0], .y = br[1] },
            .{ .x = tl[0], .y = tl[1] },
        },
    }, .{ .thickness = thickness, .color = col });
}

pub fn strokeCircle(center: Vec2, radius: f32, thickness: f32, col: Color) void {
    var pts: [16]dvui.Point.Physical = undefined;
    inline for (0..16) |si| {
        const angle: f32 = @as(f32, @floatFromInt(si)) * (2.0 * std.math.pi / 16.0);
        pts[si] = .{ .x = center[0] + radius * @cos(angle), .y = center[1] - radius * @sin(angle) };
    }
    dvui.Path.stroke(.{ .points = &pts }, .{ .thickness = thickness, .color = col, .closed = true });
}

pub fn strokeArc(center: Vec2, radius: f32, start_angle: i16, sweep_angle: i16, thickness: f32, col: Color) void {
    const start_deg: f32 = @floatFromInt(start_angle);
    const sweep_deg: f32 = @floatFromInt(sweep_angle);
    const n_segs: usize = @min(64, @max(8, @as(usize, @intFromFloat(@abs(sweep_deg) / 10.0))));
    const start_rad = start_deg * std.math.pi / 180.0;
    const sweep_rad = sweep_deg * std.math.pi / 180.0;
    var pts: [65]dvui.Point.Physical = undefined;
    const point_count = n_segs + 1;
    for (0..point_count) |si| {
        const t: f32 = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(n_segs));
        const angle = start_rad + sweep_rad * t;
        pts[si] = .{ .x = center[0] + radius * @cos(angle), .y = center[1] - radius * @sin(angle) };
    }
    dvui.Path.stroke(.{ .points = pts[0..point_count] }, .{ .thickness = thickness, .color = col });
}

// ═══════════════════════════════════════════════════════════════════════════
// LineBatch — batched line/dot/rect geometry as one renderTriangles call
// ═══════════════════════════════════════════════════════════════════════════

const empty_bounds: dvui.Rect.Physical = .{
    .x = std.math.floatMax(f32), .y = std.math.floatMax(f32),
    .w = -std.math.floatMax(f32), .h = -std.math.floatMax(f32),
};

pub const LineBatch = struct {
    vertexes: std.ArrayListUnmanaged(Vertex) = .{},
    indices: std.ArrayListUnmanaged(Vertex.Index) = .{},
    bounds: dvui.Rect.Physical = empty_bounds,
    alloc: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) LineBatch { return .{ .alloc = a }; }

    pub fn deinit(self: *LineBatch) void {
        self.indices.deinit(self.alloc);
        self.vertexes.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn ensureLineCapacity(self: *LineBatch, n: usize) !void {
        try self.vertexes.ensureUnusedCapacity(self.alloc, n * 4);
        try self.indices.ensureUnusedCapacity(self.alloc, n * 6);
    }

    pub fn addLine(self: *LineBatch, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, col: Color) void {
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len_sq = dx * dx + dy * dy;
        if (len_sq < 1e-6) return;
        const len = @sqrt(len_sq);
        const half = thickness * 0.5;
        const nx = -dy / len * half;
        const ny = dx / len * half;

        self.vertexes.ensureUnusedCapacity(self.alloc, 4) catch return;
        self.indices.ensureUnusedCapacity(self.alloc, 6) catch return;

        const pma: dvui.Color.PMA = .fromColor(col);
        const base: Vertex.Index = @intCast(self.vertexes.items.len);
        const corners = [4]dvui.Point.Physical{
            .{ .x = x0 - nx, .y = y0 - ny }, .{ .x = x1 - nx, .y = y1 - ny },
            .{ .x = x1 + nx, .y = y1 + ny }, .{ .x = x0 + nx, .y = y0 + ny },
        };
        for (corners) |c| {
            self.vertexes.appendAssumeCapacity(.{ .pos = c, .col = pma });
            self.bounds.x = @min(self.bounds.x, c.x);
            self.bounds.y = @min(self.bounds.y, c.y);
            self.bounds.w = @max(self.bounds.w, c.x);
            self.bounds.h = @max(self.bounds.h, c.y);
        }
        self.indices.appendSliceAssumeCapacity(&.{ base, base + 3, base + 2, base, base + 2, base + 1 });
    }

    pub fn addDot(self: *LineBatch, p: Vec2, radius: f32, col: Color) void {
        self.addLine(p[0] - radius, p[1], p[0] + radius, p[1], radius * 2.0, col);
    }

    pub fn addFilledPoly(self: *LineBatch, pts: []const dvui.Point.Physical, col: Color) void {
        const n = pts.len;
        if (n < 3) return;
        var area2: f32 = 0;
        for (pts, 0..) |p, i| {
            const q = pts[(i + 1) % n];
            area2 += p.x * q.y - q.x * p.y;
        }
        const needs_reverse = area2 > 0;
        self.vertexes.ensureUnusedCapacity(self.alloc, n) catch return;
        self.indices.ensureUnusedCapacity(self.alloc, (n - 2) * 3) catch return;
        const pma: dvui.Color.PMA = .fromColor(col);
        const base: Vertex.Index = @intCast(self.vertexes.items.len);

        if (needs_reverse) {
            var k: usize = n;
            while (k > 0) { k -= 1; self.appendVtx(pts[k], pma); }
        } else {
            for (pts) |p| self.appendVtx(p, pma);
        }
        var k: Vertex.Index = 1;
        while (k + 1 < n) : (k += 1) {
            self.indices.appendAssumeCapacity(base);
            self.indices.appendAssumeCapacity(base + k);
            self.indices.appendAssumeCapacity(base + k + 1);
        }
    }

    fn appendVtx(self: *LineBatch, p: dvui.Point.Physical, pma: dvui.Color.PMA) void {
        self.vertexes.appendAssumeCapacity(.{ .pos = p, .col = pma });
        self.bounds.x = @min(self.bounds.x, p.x);
        self.bounds.y = @min(self.bounds.y, p.y);
        self.bounds.w = @max(self.bounds.w, p.x);
        self.bounds.h = @max(self.bounds.h, p.y);
    }

    pub fn addHollowCircle(self: *LineBatch, center: Vec2, radius: f32, thickness: f32, col: Color) void {
        const segs = 8;
        var prev: Vec2 = .{ center[0] + radius, center[1] };
        for (1..segs + 1) |si| {
            const angle: f32 = @as(f32, @floatFromInt(si)) * (2.0 * std.math.pi / @as(f32, segs));
            const cur: Vec2 = .{ center[0] + radius * @cos(angle), center[1] - radius * @sin(angle) };
            self.addLine(prev[0], prev[1], cur[0], cur[1], thickness, col);
            prev = cur;
        }
    }

    pub fn addFilledSquare(self: *LineBatch, center: Vec2, half_side: f32, col: Color) void {
        self.vertexes.ensureUnusedCapacity(self.alloc, 4) catch return;
        self.indices.ensureUnusedCapacity(self.alloc, 6) catch return;
        const pma: dvui.Color.PMA = .fromColor(col);
        const base: Vertex.Index = @intCast(self.vertexes.items.len);
        const pts = [4]dvui.Point.Physical{
            .{ .x = center[0] - half_side, .y = center[1] - half_side },
            .{ .x = center[0] + half_side, .y = center[1] - half_side },
            .{ .x = center[0] + half_side, .y = center[1] + half_side },
            .{ .x = center[0] - half_side, .y = center[1] + half_side },
        };
        for (pts) |p| {
            self.vertexes.appendAssumeCapacity(.{ .pos = p, .col = pma });
            self.bounds.x = @min(self.bounds.x, p.x);
            self.bounds.y = @min(self.bounds.y, p.y);
            self.bounds.w = @max(self.bounds.w, p.x);
            self.bounds.h = @max(self.bounds.h, p.y);
        }
        self.indices.appendSliceAssumeCapacity(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
    }

    pub fn addRectOutline(self: *LineBatch, tl: Vec2, br: Vec2, thickness: f32, col: Color) void {
        self.addLine(tl[0], tl[1], br[0], tl[1], thickness, col);
        self.addLine(br[0], tl[1], br[0], br[1], thickness, col);
        self.addLine(br[0], br[1], tl[0], br[1], thickness, col);
        self.addLine(tl[0], br[1], tl[0], tl[1], thickness, col);
    }

    pub fn flush(self: *LineBatch) void {
        if (self.vertexes.items.len == 0) return;
        const tri = dvui.Triangles{
            .vertexes = self.vertexes.items,
            .indices = self.indices.items,
            .bounds = .{ .x = self.bounds.x, .y = self.bounds.y, .w = self.bounds.w - self.bounds.x, .h = self.bounds.h - self.bounds.y },
        };
        dvui.renderTriangles(tri, null) catch {};
        self.vertexes.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.bounds = empty_bounds;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Label queue — deferred text rendering atop line batch
// ═══════════════════════════════════════════════════════════════════════════

pub const PendingLabel = struct {
    text: []const u8,
    x: f32,
    y: f32,
    col: Color,
    id_extra: usize,
};

pub const LabelList = std.ArrayListUnmanaged(PendingLabel);

pub fn queueLabel(list: *LabelList, a: std.mem.Allocator, text: []const u8, x: f32, y: f32, col: Color, id_extra: usize) void {
    list.append(a, .{ .text = text, .x = x, .y = y, .col = col, .id_extra = id_extra }) catch {};
}

pub fn drainLabels(list: *LabelList, vp: RenderViewport) void {
    for (list.items) |lbl| drawLabel(lbl.text, lbl.x, lbl.y, lbl.col, vp, lbl.id_extra);
    list.clearRetainingCapacity();
}

// ═══════════════════════════════════════════════════════════════════════════
// Canvas font helpers
// ═══════════════════════════════════════════════════════════════════════════

fn canvasLabelFont(vp: RenderViewport) dvui.Font {
    _ = vp;
    var font = dvui.themeGet().font_body;
    font.size = 11.0;
    return font;
}

pub fn measureLabelWidth(text: []const u8, vp: RenderViewport) f32 {
    if (text.len == 0) return 0;
    const font = canvasLabelFont(vp);
    const sz = font.textSize(text);
    return sz.w * vp.rs_s;
}

pub fn drawLabel(text: []const u8, x: f32, y: f32, col: Color, vp: RenderViewport, id_extra: usize) void {
    _ = id_extra;
    const font = canvasLabelFont(vp);
    const phys_size = font.size * vp.rs_s;
    const lh = phys_size * 1.6 + 4;
    const text_w: f32 = @max(200, @as(f32, @floatFromInt(text.len)) * phys_size * 0.8 + 40);

    if (x > vp.bounds.x + vp.bounds.w or x + text_w < vp.bounds.x) return;
    if (y > vp.bounds.y + vp.bounds.h or y + lh < vp.bounds.y) return;

    const sx = @round(x);
    const sy = @round(y);
    const rs: dvui.RectScale = .{
        .r = .{ .x = sx, .y = sy, .w = text_w, .h = lh },
        .s = vp.rs_s,
    };
    dvui.renderText(.{ .font = font, .text = text, .rs = rs, .color = col }) catch {};
}

// ═══════════════════════════════════════════════════════════════════════════
// Grid rendering
// ═══════════════════════════════════════════════════════════════════════════

const grid_dot_large: f32 = 1.2;
const grid_dot_small: f32 = 0.7;
const origin_arm_min: f32 = 6.0;
const origin_arm_max_scale: f32 = 12.0;

pub fn drawGrid(ctx: *const types.RenderContext, snap_size: f32) void {
    const vp = ctx.vp;
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
    const dot_r: f32 = dot_r_base * ctx.canvas_styles.grid.dot_size;

    const x_start = vp.bounds.x + ox;
    const y_start = vp.bounds.y + oy;
    const x_end = vp.bounds.x + vp.bounds.w;
    const y_end = vp.bounds.y + vp.bounds.h;

    var n_cols: usize = 0;
    { var x: f32 = x_start; while (x < x_end) : (x += dstep) n_cols += 1; }
    var n_rows: usize = 0;
    { var y: f32 = y_start; while (y < y_end) : (y += dstep) n_rows += 1; }
    const n_dots = n_cols * n_rows;
    if (n_dots == 0) return;

    const cw = dvui.currentWindow();
    const alloc = cw.lifo();
    var tb = dvui.Triangles.Builder.init(alloc, n_dots * 4, n_dots * 6) catch return;
    const grid_col: dvui.Color.PMA = .fromColor(ctx.canvas_styles.grid.color);

    var row: usize = 0;
    while (row < n_rows) : (row += 1) {
        const y = y_start + @as(f32, @floatFromInt(row)) * dstep;
        var col_i: usize = 0;
        while (col_i < n_cols) : (col_i += 1) {
            const x = x_start + @as(f32, @floatFromInt(col_i)) * dstep;
            const base: Vertex.Index = @intCast(tb.vertexes.items.len);
            tb.appendVertex(.{ .pos = .{ .x = x - dot_r, .y = y - dot_r }, .col = grid_col });
            tb.appendVertex(.{ .pos = .{ .x = x - dot_r, .y = y + dot_r }, .col = grid_col });
            tb.appendVertex(.{ .pos = .{ .x = x + dot_r, .y = y + dot_r }, .col = grid_col });
            tb.appendVertex(.{ .pos = .{ .x = x + dot_r, .y = y - dot_r }, .col = grid_col });
            tb.appendTriangles(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
        }
    }

    var triangles = tb.build();
    defer triangles.deinit(alloc);
    dvui.renderTriangles(triangles, null) catch {};
}

pub fn drawOrigin(ctx: *const types.RenderContext) void {
    const vp = ctx.vp;
    const pal = ctx.pal;
    const ox_px = vp.cx - vp.pan[0] * vp.scale;
    const oy_px = vp.cy - vp.pan[1] * vp.scale;
    const arm = @max(origin_arm_min, origin_arm_max_scale * @min(vp.scale, 1.0));
    if (ox_px < vp.bounds.x or ox_px > vp.bounds.x + vp.bounds.w) return;
    if (oy_px < vp.bounds.y or oy_px > vp.bounds.y + vp.bounds.h) return;
    strokeLine(ox_px - arm, oy_px, ox_px + arm, oy_px, 1.0, pal.origin);
    strokeLine(ox_px, oy_px - arm, ox_px, oy_px + arm, 1.0, pal.origin);
}
