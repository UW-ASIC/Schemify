//! Shared drawing primitives for Canvas sub-renderers.
//!
//! Two flavors live here:
//!   - `strokeLine` / `strokeDot` / `strokeRectOutline`: thin wrappers around
//!     `dvui.Path.stroke`, one render command per call. Cheap for the handful
//!     of overlay strokes (selection box, hover preview) that draw a few
//!     segments per frame.
//!   - `LineBatch`: collects an arbitrary number of thick line segments and
//!     submits them as ONE `renderTriangles` call. Use this anywhere a loop
//!     would otherwise emit hundreds of `strokeLine`s per frame (wires,
//!     symbols, instance geometry). Each line becomes a screen-aligned quad
//!     (4 verts + 6 indices) with thickness baked into the geometry, so
//!     varying thickness/color across the batch is fine.

const std = @import("std");
const dvui = @import("dvui");
const types = @import("types.zig");

const Vec2 = types.Vec2;
const Color = types.Color;
const Point = types.Point;
const RenderViewport = types.RenderViewport;
const Vertex = dvui.Vertex;

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

const empty_bounds: dvui.Rect.Physical = .{
    .x = std.math.floatMax(f32),
    .y = std.math.floatMax(f32),
    .w = -std.math.floatMax(f32),
    .h = -std.math.floatMax(f32),
};

/// Accumulator for line/dot/rect-outline geometry drawn as a single
/// `renderTriangles` call.
///
/// Allocate one per renderer pass (typically on `dvui.currentWindow().lifo()`),
/// fill it via `addLine` / `addDot` / `addRectOutline`, then call `flush`.
/// `flush` submits the batch and clears the buffers (capacity retained), so
/// the same batch can be reused for a follow-up pass within the same frame.
///
/// Each line is rasterised as a screen-space quad rather than a true polyline,
/// so adjacent segments at corners do NOT share vertices and there are no
/// miter joins. At typical schematic line widths (1–3 px) any sub-pixel
/// gap/overlap at corners is invisible. Connected polylines that need clean
/// joins (curves, multi-segment paths) should still go through `dvui.Path`.
pub const LineBatch = struct {
    vertexes: std.ArrayListUnmanaged(Vertex) = .{},
    indices: std.ArrayListUnmanaged(Vertex.Index) = .{},
    bounds: dvui.Rect.Physical = empty_bounds,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LineBatch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LineBatch) void {
        // NOTE: opposite order to ArrayList growth, matching Triangles.Builder.deinit.
        self.indices.deinit(self.allocator);
        self.vertexes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Pre-reserve space for `n_lines` upcoming `addLine` calls. Optional —
    /// `addLine` falls back to incremental growth — but skipping repeated
    /// reallocation matters when the line count is in the thousands.
    pub fn ensureLineCapacity(self: *LineBatch, n_lines: usize) !void {
        try self.vertexes.ensureUnusedCapacity(self.allocator, n_lines * 4);
        try self.indices.ensureUnusedCapacity(self.allocator, n_lines * 6);
    }

    /// Append one thick line segment as a screen-aligned quad. Degenerate
    /// (zero-length) segments are silently dropped — they have no perpendicular
    /// direction and would produce a NaN quad.
    pub fn addLine(self: *LineBatch, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, col: Color) void {
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len_sq = dx * dx + dy * dy;
        if (len_sq < 1e-6) return;
        const len = @sqrt(len_sq);
        const half = thickness * 0.5;
        // Perpendicular offset, scaled to half-thickness.
        const nx = -dy / len * half;
        const ny = dx / len * half;

        // Grow on demand if caller didn't pre-reserve. On allocation failure
        // we drop the segment rather than crashing the frame — a dropped line
        // is a much better failure mode than an OOM panic mid-render.
        self.vertexes.ensureUnusedCapacity(self.allocator, 4) catch return;
        self.indices.ensureUnusedCapacity(self.allocator, 6) catch return;

        const pma: dvui.Color.PMA = .fromColor(col);
        const base: Vertex.Index = @intCast(self.vertexes.items.len);

        // Quad corners, ordered so that the index winding below is CCW in
        // y-down screen space (dvui backface-culls CW triangles, so getting
        // this wrong makes the entire batch invisible).
        //
        //   v0 ----- v1      v0 = (x0-n, y0-n)   v1 = (x1-n, y1-n)
        //   |  line  |       v3 = (x0+n, y0+n)   v2 = (x1+n, y1+n)
        //   v3 ----- v2
        const corners = [4]dvui.Point.Physical{
            .{ .x = x0 - nx, .y = y0 - ny },
            .{ .x = x1 - nx, .y = y1 - ny },
            .{ .x = x1 + nx, .y = y1 + ny },
            .{ .x = x0 + nx, .y = y0 + ny },
        };
        for (corners) |c| {
            self.vertexes.appendAssumeCapacity(.{ .pos = c, .col = pma });
            self.bounds.x = @min(self.bounds.x, c.x);
            self.bounds.y = @min(self.bounds.y, c.y);
            self.bounds.w = @max(self.bounds.w, c.x);
            self.bounds.h = @max(self.bounds.h, c.y);
        }
        // (v0, v3, v2) and (v0, v2, v1) — both CCW in y-down. Mirrors
        // Grid.zig's TL/BL/BR/TR pattern which is the known-good reference.
        self.indices.appendSliceAssumeCapacity(&.{
            base,     base + 3, base + 2,
            base,     base + 2, base + 1,
        });
    }

    /// Append a small filled square centred on `p` with half-side `radius`.
    /// Emitted via `addLine` quad path.
    pub fn addDot(self: *LineBatch, p: Vec2, radius: f32, col: Color) void {
        self.addLine(p[0] - radius, p[1], p[0] + radius, p[1], radius * 2.0, col);
    }

    /// Append a rectangle outline as 4 line quads.
    pub fn addRectOutline(self: *LineBatch, tl: Vec2, br: Vec2, thickness: f32, col: Color) void {
        self.addLine(tl[0], tl[1], br[0], tl[1], thickness, col);
        self.addLine(br[0], tl[1], br[0], br[1], thickness, col);
        self.addLine(br[0], br[1], tl[0], br[1], thickness, col);
        self.addLine(tl[0], br[1], tl[0], tl[1], thickness, col);
    }

    /// Submit all collected geometry as one `renderTriangles` call, then
    /// clear (capacity retained) so the batch can be reused for a follow-up
    /// layer within the same frame. Empty batches are a no-op.
    pub fn flush(self: *LineBatch) void {
        if (self.vertexes.items.len == 0) return;
        // Construct Triangles directly from our slices. dvui.renderTriangles
        // copies the data into its arena before returning, so the slices are
        // safe to clear/free immediately afterwards.
        const tri = dvui.Triangles{
            .vertexes = self.vertexes.items,
            .indices = self.indices.items,
            .bounds = .{
                .x = self.bounds.x,
                .y = self.bounds.y,
                .w = self.bounds.w - self.bounds.x,
                .h = self.bounds.h - self.bounds.y,
            },
        };
        dvui.renderTriangles(tri, null) catch {};
        self.vertexes.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.bounds = empty_bounds;
    }
};

pub fn strokeCircle(center: Vec2, radius: f32, thickness: f32, col: Color) void {
    // Batched: build all 16 corner points and emit ONE closed stroke. The
    // previous version emitted 16 separate one-segment strokes per circle —
    // an order of magnitude more render commands and triangulation work.
    var pts: [16]dvui.Point.Physical = undefined;
    inline for (0..16) |si| {
        const angle: f32 = @as(f32, @floatFromInt(si)) * (2.0 * std.math.pi / 16.0);
        pts[si] = .{
            .x = center[0] + radius * @cos(angle),
            .y = center[1] - radius * @sin(angle),
        };
    }
    dvui.Path.stroke(.{ .points = &pts }, .{ .thickness = thickness, .color = col, .closed = true });
}

pub fn strokeArc(center: Vec2, radius: f32, start_angle: i16, sweep_angle: i16, thickness: f32, col: Color) void {
    const start_deg: f32 = @floatFromInt(start_angle);
    const sweep_deg: f32 = @floatFromInt(sweep_angle);
    const n_segs: usize = @min(64, @max(8, @as(usize, @intFromFloat(@abs(sweep_deg) / 10.0))));
    const start_rad = start_deg * std.math.pi / 180.0;
    const sweep_rad = sweep_deg * std.math.pi / 180.0;

    // Batched: build n_segs+1 points and emit ONE stroke (open polyline).
    var pts: [65]dvui.Point.Physical = undefined;
    const point_count = n_segs + 1;
    for (0..point_count) |si| {
        const t: f32 = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(n_segs));
        const angle = start_rad + sweep_rad * t;
        pts[si] = .{
            .x = center[0] + radius * @cos(angle),
            .y = center[1] - radius * @sin(angle),
        };
    }
    dvui.Path.stroke(.{ .points = pts[0..point_count] }, .{ .thickness = thickness, .color = col });
}

/// A label queued for rendering after a `LineBatch.flush`. See `LabelList`.
/// `text` must reference memory that outlives the enclosing frame — strings
/// from Schemify / subckt arenas are fine; stack-allocated buffers are not.
pub const PendingLabel = struct {
    text: []const u8,
    x: f32,
    y: f32,
    col: Color,
    id_extra: usize,
};

pub const LabelList = std.ArrayListUnmanaged(PendingLabel);

/// Append a label to `list`. Use this from draw helpers that interleave
/// shapes and labels — the shapes go into a `LineBatch`, the labels into a
/// `LabelList`, and the caller drains the list via `drainLabels` AFTER
/// flushing the line batch so labels layer on top.
pub fn queueLabel(list: *LabelList, allocator: std.mem.Allocator, text: []const u8, x: f32, y: f32, col: Color, id_extra: usize) void {
    // Silently drop on OOM for the same reason LineBatch does: a missing
    // label is a better failure mode than crashing the frame.
    list.append(allocator, .{
        .text = text,
        .x = x,
        .y = y,
        .col = col,
        .id_extra = id_extra,
    }) catch {};
}

/// Draw every pending label then clear the list (capacity retained).
pub fn drainLabels(list: *LabelList, vp: RenderViewport) void {
    for (list.items) |lbl| {
        drawLabel(lbl.text, lbl.x, lbl.y, lbl.col, vp, lbl.id_extra);
    }
    list.clearRetainingCapacity();
}

/// Build the canvas-label font for the current viewport.
///
/// We render text in dvui's logical-pixel convention: the returned font's
/// `size` is a logical-pixel count, and the caller must pass `rs.s = vp.rs_s`
/// to `renderText`. dvui then keys the font cache on `logical_size × rs_s`,
/// which is exactly the physical pixel size we want.
///
/// The logical size is **quantized to whole pixels** as a function of
/// `app.view.zoom` (recovered as `vp.scale / vp.rs_s`). This is the key
/// fix for the zoom-jitter bug: with the previous formulation
/// `font.size = 12.0 * vp.scale`, every fractional zoom step produced a
/// distinct float font hash, so dvui's font cache spawned a new entry on
/// every frame even though they all rounded to the same integer pixel
/// glyph atlas. The resulting per-frame `target_fraction` micro-shifts
/// (see `dvui/src/render.zig:166`) made glyphs jiggle by sub-pixel amounts
/// every time the user scrolled the mouse wheel.
///
/// `min_size` is 8 logical pixels — below that the text would be illegible
/// anyway, and the caller should be culling via `vp.scale >= 0.3` first.
fn canvasLabelFont(vp: RenderViewport) dvui.Font {
    const view_zoom = if (vp.rs_s > 0.0) vp.scale / vp.rs_s else vp.scale;
    const desired: f32 = 12.0 * view_zoom;
    // Quantize to integer logical pixels. @round (not @floor) so we don't
    // bias the displayed size half a pixel below the visual zoom.
    const quantized: f32 = @max(8.0, @round(desired));
    var font = dvui.themeGet().font_body;
    font.size = quantized;
    return font;
}

/// Measure label text width in **physical** pixels using the same quantized
/// font that `drawLabel` will render with. Returns 0 on failure.
///
/// Used by right-anchored label callers (e.g. subckt pin names on the right
/// side of a symbol box) so they can position the label exactly against its
/// anchor pin instead of relying on a magic per-character width constant.
/// Without this, right-anchored labels visibly drift away from their pin as
/// the user zooms in — the drift scales with `(font_advance - 6) × len × scale`.
pub fn measureLabelWidth(text: []const u8, vp: RenderViewport) f32 {
    if (text.len == 0) return 0;
    const font = canvasLabelFont(vp);
    // Font.textSize works in logical pixels, so the returned width is in
    // logical pixels. Multiply by rs_s to get physical pixels for the
    // canvas's coordinate frame.
    const sz = font.textSize(text);
    return sz.w * vp.rs_s;
}

pub fn drawLabel(text: []const u8, x: f32, y: f32, col: Color, vp: RenderViewport, id_extra: usize) void {
    // We don't need a widget identity for canvas labels — nothing handles
    // events on them, nothing tracks focus, they're pure visual output.
    _ = id_extra;

    const font = canvasLabelFont(vp);
    // Logical font size × rs_s = physical pixel size, used for culling and
    // for the rect handed to dvui (dvui treats `rs.r` as physical and only
    // uses its top-left as the text origin when `opts.p` is null).
    const phys_size = font.size * vp.rs_s;
    const lh = phys_size * 1.6 + 4;
    const text_w: f32 = @max(200, @as(f32, @floatFromInt(text.len)) * phys_size * 0.8 + 40);

    // Cull offscreen labels before doing any work.
    if (x > vp.bounds.x + vp.bounds.w or x + text_w < vp.bounds.x) return;
    if (y > vp.bounds.y + vp.bounds.h or y + lh < vp.bounds.y) return;

    // Pre-snap label origin to whole physical pixels in OUR coordinate frame.
    // dvui's renderText also rounds when `cw.snap_to_pixels` is true, but
    // it does so AFTER computing `start = rs.r.topLeft()`. With our
    // continuously-varying anchors (`origin + 25*scale`), letting dvui do
    // the rounding means the label can flip between two adjacent pixel
    // rows whenever the unrounded value crosses x.5 — visually a 1px jump
    // mid-zoom-sweep. Rounding here keeps the rounding consistent with our
    // own geometry and matches the intent of "anchor at this pixel".
    const sx = @round(x);
    const sy = @round(y);

    // Direct render-text command — bypasses LabelWidget creation entirely.
    // The previous implementation called dvui.labelNoFmt which builds a full
    // LabelWidget per label (ID hashing, layout registration, event matching,
    // text size measurement). For schematics with hundreds of pin/instance
    // labels that work was the dominant per-frame cost.
    //
    // We pass `rs.s = vp.rs_s` and `font.size` in LOGICAL pixels: dvui will
    // multiply them to get the physical glyph size. With `font.size`
    // quantized to integer logical pixels, the same font cache entry is
    // reused across small zoom changes — eliminating glyph atlas churn.
    const rs: dvui.RectScale = .{
        .r = .{ .x = sx, .y = sy, .w = text_w, .h = lh },
        .s = vp.rs_s,
    };
    dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = rs,
        .color = col,
    }) catch {};
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
