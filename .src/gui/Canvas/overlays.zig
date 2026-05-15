//! Consolidated overlay rendering: wire preview, rubber-band selection,
//! and testbench linkage button strip + ghost wire overlay.

const std = @import("std");
const dvui = @import("dvui");
const utility = @import("utility");
const st = @import("state");
const core = @import("core");
const actions = @import("../actions.zig");

const types = @import("types.zig");
const h = @import("render.zig");

const RenderContext = types.RenderContext;
const RenderViewport = types.RenderViewport;
const Vec2 = types.Vec2;
const Color = types.Color;

// ═══════════════════════════════════════════════════════════════════════════
// Wire preview crosshair
// ═══════════════════════════════════════════════════════════════════════════

pub fn drawWirePreview(ctx: *const RenderContext, app: *st.AppState) void {
    const vp = ctx.vp;
    const pal = ctx.pal;
    const ws = app.tool.wire_start orelse return;
    const start = h.w2p(ws, vp);
    h.strokeDot(start, types.wire_preview_dot_radius, pal.wire_preview);
    h.strokeLine(start[0] - types.wire_preview_arm, start[1], start[0] + types.wire_preview_arm, start[1], 1.5, pal.wire_preview);
    h.strokeLine(start[0], start[1] - types.wire_preview_arm, start[0], start[1] + types.wire_preview_arm, 1.5, pal.wire_preview);

    // Live manhattan-constrained preview.
    const cur = app.gui.hot.canvas.cursor_world;
    const dx: u64 = @abs(@as(i64, cur[0]) - ws[0]);
    const dy: u64 = @abs(@as(i64, cur[1]) - ws[1]);
    const end_world: types.Point = if (dx >= dy) .{ cur[0], ws[1] } else .{ ws[0], cur[1] };
    const end = h.w2p(end_world, vp);
    h.strokeLine(start[0], start[1], end[0], end[1], 1.5, pal.wire_preview);
    h.strokeDot(end, types.wire_endpoint_radius, pal.wire_preview);
}

// ═══════════════════════════════════════════════════════════════════════════
// Rubber-band selection rectangle
// ═══════════════════════════════════════════════════════════════════════════

pub fn drawRubberBand(ctx: *const RenderContext, app: *st.AppState) void {
    const cs = &app.gui.hot.canvas;
    if (!cs.rubber_band_active) return;

    const vp = ctx.vp;
    const tl_world: types.Point = .{ @min(cs.rubber_band_start[0], cs.rubber_band_end[0]), @min(cs.rubber_band_start[1], cs.rubber_band_end[1]) };
    const br_world: types.Point = .{ @max(cs.rubber_band_start[0], cs.rubber_band_end[0]), @max(cs.rubber_band_start[1], cs.rubber_band_end[1]) };
    const tl = h.w2p(tl_world, vp);
    const br = h.w2p(br_world, vp);

    // Rubber band colors derived from palette wire color
    const pal = ctx.pal;
    const fill_col = Color{ .r = pal.wire.r, .g = pal.wire.g, .b = pal.wire.b, .a = 30 };
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = tl[0], .y = tl[1] }, .{ .x = br[0], .y = tl[1] },
            .{ .x = br[0], .y = br[1] }, .{ .x = tl[0], .y = br[1] },
            .{ .x = tl[0], .y = tl[1] },
        },
    }, .{ .thickness = 1, .color = fill_col });
    h.strokeRectOutline(tl, br, 1.0, Color{ .r = pal.wire.r, .g = pal.wire.g, .b = pal.wire.b, .a = 160 });
}

// ═══════════════════════════════════════════════════════════════════════════
// Testbench overlay — button strip + ghost wires
// ═══════════════════════════════════════════════════════════════════════════

const TbOverlayCache = st.TbOverlayCache;

// Layout
const BTN_H: f32 = 20.0;
const BTN_W: f32 = 100.0;
const BTN_GAP: f32 = 4.0;
const BTN_PAD_X: f32 = 8.0;
const BTN_MARGIN_RIGHT: f32 = 10.0;
const BTN_MARGIN_TOP: f32 = 10.0;

// Colors — derived from palette in tbColors()

const BtnPos = struct { x: f32, y: f32 };

fn btnPos(bounds: dvui.Rect.Physical, idx: usize) BtnPos {
    // Offset below the Auto-Generate button (AGEN_H + AGEN_MARGIN + gap)
    const tb_top = AGEN_MARGIN + AGEN_H + 8.0;
    return .{
        .x = bounds.x + bounds.w - BTN_W - BTN_MARGIN_RIGHT,
        .y = bounds.y + tb_top + @as(f32, @floatFromInt(idx)) * (BTN_H + BTN_GAP),
    };
}

fn hitButton(px_val: f32, py_val: f32, bounds: dvui.Rect.Physical, idx: usize) bool {
    const p = btnPos(bounds, idx);
    return px_val >= p.x and px_val <= p.x + BTN_W and py_val >= p.y and py_val <= p.y + BTN_H;
}

pub fn tbIsHovered(app: *st.AppState) bool { return app.gui.hot.canvas.tb_overlay.hovered_idx >= 0; }

/// Process tb button input BEFORE interaction.handleInput.
pub fn tbPreInput(app: *st.AppState, wd: *dvui.WidgetData, bounds: dvui.Rect.Physical) void {
    const tb_ov = &app.gui.hot.canvas.tb_overlay;
    const tbs = getTbs(app) orelse { tb_ov.hovered_idx = -1; return; };

    for (dvui.events()) |*ev| {
        switch (ev.evt) {
            .mouse => |me| {
                tb_ov.last_mouse_x = me.p.x; tb_ov.last_mouse_y = me.p.y;
                if (me.action == .press and me.button == .left and !ev.handled and dvui.eventMatchSimple(ev, wd)) {
                    for (tbs, 0..) |tb_path, idx| {
                        if (hitButton(me.p.x, me.p.y, bounds, idx)) {
                            ev.handled = true;
                            tbHandleClick(app, tb_path, me.mod.shift());
                            break;
                        }
                    }
                }
            },
            else => {},
        }
    }

    var new_hov: i32 = -1;
    for (0..tbs.len) |idx| { if (hitButton(tb_ov.last_mouse_x, tb_ov.last_mouse_y, bounds, idx)) { new_hov = @intCast(idx); break; } }
    tb_ov.hovered_idx = new_hov;

    if (tb_ov.hovered_idx != tb_ov.cached_for_idx) {
        tb_ov.cached_for_idx = tb_ov.hovered_idx; tb_ov.cached_wire_count = 0;
        if (tb_ov.hovered_idx >= 0) loadWireCache(tb_ov, tbs[@intCast(tb_ov.hovered_idx)]);
    }
}

/// Compute TB button colors from the active palette.
fn tbColors(pal: types.Palette) struct {
    bg_normal: Color,
    bg_hover: Color,
    border_normal: Color,
    border_hover: Color,
    text_normal: Color,
    text_hover: Color,
} {
    return .{
        .bg_normal = Color{ .r = pal.canvas_bg.r +| 19, .g = pal.canvas_bg.g +| 19, .b = pal.canvas_bg.b +| 21, .a = 200 },
        .bg_hover = Color{ .r = pal.wire.r / 2, .g = pal.wire.g / 2, .b = pal.wire.b / 2, .a = 220 },
        .border_normal = Color{ .r = pal.grid_dot.r, .g = pal.grid_dot.g, .b = pal.grid_dot.b, .a = 150 },
        .border_hover = Color{ .r = pal.wire.r, .g = pal.wire.g, .b = pal.wire.b, .a = 200 },
        .text_normal = Color{ .r = pal.symbol_line.r, .g = pal.symbol_line.g, .b = pal.symbol_line.b, .a = 220 },
        .text_hover = Color{ .r = pal.symbol_line.r +| 32, .g = pal.symbol_line.g +| 32, .b = pal.symbol_line.b +| 32, .a = 255 },
    };
}

/// Draw ghost wire overlay + button strip.
pub fn tbDraw(ctx: *const RenderContext, app: *st.AppState) void {
    const tbs = getTbs(app) orelse return;
    const tb_ov = &app.gui.hot.canvas.tb_overlay;
    const vp = ctx.vp;
    const pal = ctx.pal;
    const bounds = vp.bounds;
    const cw = dvui.currentWindow();
    const cols = tbColors(pal);

    // Ghost wire overlay
    if (tb_ov.hovered_idx >= 0 and tb_ov.cached_wire_count > 0) {
        const ghost = Color{ .r = pal.wire.r, .g = pal.wire.g, .b = pal.wire.b, .a = 90 };
        const ww: f32 = @max(0.8, 1.8 * vp.scale);
        var batch = h.LineBatch.init(cw.lifo());
        defer batch.deinit();
        batch.ensureLineCapacity(tb_ov.cached_wire_count) catch {};
        for (0..tb_ov.cached_wire_count) |i| {
            const a = h.w2p(.{ tb_ov.cached_x0[i], tb_ov.cached_y0[i] }, vp);
            const b = h.w2p(.{ tb_ov.cached_x1[i], tb_ov.cached_y1[i] }, vp);
            batch.addLine(a[0], a[1], b[0], b[1], ww, ghost);
        }
        batch.flush();
    }

    // Button backgrounds + borders
    {
        var batch = h.LineBatch.init(cw.lifo());
        defer batch.deinit();
        batch.ensureLineCapacity(tbs.len * 8) catch {};
        for (tbs, 0..) |_, idx| {
            const p = btnPos(bounds, idx);
            const hov = tb_ov.hovered_idx == @as(i32, @intCast(idx));
            batch.addLine(p.x, p.y + BTN_H * 0.5, p.x + BTN_W, p.y + BTN_H * 0.5, BTN_H, if (hov) cols.bg_hover else cols.bg_normal);
            batch.addRectOutline(.{ p.x, p.y }, .{ p.x + BTN_W, p.y + BTN_H }, 1.0, if (hov) cols.border_hover else cols.border_normal);
        }
        batch.flush();
    }

    // Button labels
    for (tbs, 0..) |tb_path, idx| {
        const p = btnPos(bounds, idx);
        const hov = tb_ov.hovered_idx == @as(i32, @intCast(idx));
        h.drawLabel(tbBaseName(tb_path), p.x + BTN_PAD_X, p.y + 3.0, if (hov) cols.text_hover else cols.text_normal, vp, idx + 80_000);
    }
}

// ── Testbench private helpers ────────────────────────────────────────────

fn getTbs(app: *st.AppState) ?[]const []const u8 {
    const doc = app.active() orelse return null;
    if (doc.sch.stype == .testbench) return null;
    const dut_path = switch (doc.origin) { .chn_file => |p| p, else => return null };
    const tbs = app.tb_index.testbenchesFor(st.TbIndex.normalizeSymbol(dut_path));
    return if (tbs.len == 0) null else tbs;
}

fn tbHandleClick(app: *st.AppState, tb_path: []const u8, shift: bool) void {
    _ = shift;
    app.openPath(tb_path) catch {
        app.status_msg = "Failed to open testbench";
    };
}

fn loadWireCache(tb_ov: *TbOverlayCache, tb_path: []const u8) void {
    tb_ov.cached_wire_count = 0;
    if (tb_ov.cache_arena) |*a| _ = a.reset(.retain_capacity);
    if (tb_ov.cache_arena == null) tb_ov.cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = tb_ov.cache_arena.?.allocator();
    const data = utility.platform.fs.cwd().readFileAlloc(arena, tb_path, std.math.maxInt(usize)) catch return;
    const sch = core.Schemify.readFile(data, arena, null);
    const wx0 = sch.wires.items(.x0); const wy0 = sch.wires.items(.y0);
    const wx1 = sch.wires.items(.x1); const wy1 = sch.wires.items(.y1);
    const n = @min(sch.wires.len, TbOverlayCache.MAX_CACHED_WIRES);
    for (0..n) |i| { tb_ov.cached_x0[i] = wx0[i]; tb_ov.cached_y0[i] = wy0[i]; tb_ov.cached_x1[i] = wx1[i]; tb_ov.cached_y1[i] = wy1[i]; }
    tb_ov.cached_wire_count = n;
}

fn tbBaseName(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else if (std.mem.lastIndexOfScalar(u8, path, '\\')) |i| path[i + 1 ..] else path;
    inline for ([_][]const u8{ ".chn_tb", ".chn_prim", ".chn" }) |ext| {
        if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    }
    return base;
}

// ═══════════════════════════════════════════════════════════════════════════
// Auto-Generate button (top-right of schematic canvas)
// ═══════════════════════════════════════════════════════════════════════════

const AGEN_W: f32 = 110.0;
const AGEN_H: f32 = 24.0;
const AGEN_MARGIN: f32 = 10.0;

fn agenPos(bounds: dvui.Rect.Physical) BtnPos {
    return .{
        .x = bounds.x + bounds.w - AGEN_W - AGEN_MARGIN,
        .y = bounds.y + AGEN_MARGIN,
    };
}

fn hitAgen(px: f32, py: f32, bounds: dvui.Rect.Physical) bool {
    const p = agenPos(bounds);
    return px >= p.x and px <= p.x + AGEN_W and py >= p.y and py <= p.y + AGEN_H;
}

/// Process Auto-Generate button input before canvas interaction.
pub fn autoGenPreInput(app: *st.AppState, wd: *dvui.WidgetData, bounds: dvui.Rect.Physical) void {
    if (app.gui.hot.view_mode != .schematic) return;

    for (dvui.events()) |*ev| {
        switch (ev.evt) {
            .mouse => |me| {
                if (me.action == .press and me.button == .left and !ev.handled and dvui.eventMatchSimple(ev, wd)) {
                    if (hitAgen(me.p.x, me.p.y, bounds)) {
                        ev.handled = true;
                        actions.enqueue(app, .{ .immediate = .make_symbol_from_schematic }, "Auto-generate symbol");
                    }
                }
            },
            else => {},
        }
    }
}

/// Draw the Auto-Generate button overlay.
pub fn autoGenDraw(ctx: *const RenderContext, app: *st.AppState) void {
    if (app.gui.hot.view_mode != .schematic) return;
    // Only show when a saved schematic is open
    const doc = app.active() orelse return;
    switch (doc.origin) {
        .chn_file => {},
        else => return,
    }

    const bounds = ctx.vp.bounds;
    const pal = ctx.pal;
    const p = agenPos(bounds);
    const cw = dvui.currentWindow();

    // Check hover
    const mouse_x = app.gui.hot.canvas.tb_overlay.last_mouse_x;
    const mouse_y = app.gui.hot.canvas.tb_overlay.last_mouse_y;
    const hov = hitAgen(mouse_x, mouse_y, bounds);

    const cols = tbColors(pal);

    // Background + border
    {
        var batch = h.LineBatch.init(cw.lifo());
        defer batch.deinit();
        batch.ensureLineCapacity(8) catch {};
        batch.addLine(p.x, p.y + AGEN_H * 0.5, p.x + AGEN_W, p.y + AGEN_H * 0.5, AGEN_H, if (hov) cols.bg_hover else cols.bg_normal);
        batch.addRectOutline(.{ p.x, p.y }, .{ p.x + AGEN_W, p.y + AGEN_H }, 1.0, if (hov) cols.border_hover else cols.border_normal);
        batch.flush();
    }

    // Label
    h.drawLabel("Auto-Generate", p.x + 10.0, p.y + 4.0, if (hov) cols.text_hover else cols.text_normal, ctx.vp, 90_000);
}
