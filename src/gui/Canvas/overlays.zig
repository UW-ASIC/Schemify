//! Consolidated overlay rendering: wire preview, rubber-band selection,
//! and testbench linkage button strip + ghost wire overlay.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const core = @import("core");

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

    const fill_col = Color{ .r = 60, .g = 120, .b = 200, .a = 30 };
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = tl[0], .y = tl[1] }, .{ .x = br[0], .y = tl[1] },
            .{ .x = br[0], .y = br[1] }, .{ .x = tl[0], .y = br[1] },
            .{ .x = tl[0], .y = tl[1] },
        },
    }, .{ .thickness = 1, .color = fill_col });
    h.strokeRectOutline(tl, br, 1.0, Color{ .r = 91, .g = 156, .b = 245, .a = 160 });
}

// ═══════════════════════════════════════════════════════════════════════════
// Testbench overlay — button strip + ghost wires
// ═══════════════════════════════════════════════════════════════════════════

// Module-level state
var hovered_idx: i32 = -1;
var last_mouse_x: f32 = -1;
var last_mouse_y: f32 = -1;

var cached_for_idx: i32 = -2;
const MAX_CACHED_WIRES = 512;
var cached_x0: [MAX_CACHED_WIRES]i32 = undefined;
var cached_y0: [MAX_CACHED_WIRES]i32 = undefined;
var cached_x1: [MAX_CACHED_WIRES]i32 = undefined;
var cached_y1: [MAX_CACHED_WIRES]i32 = undefined;
var cached_wire_count: usize = 0;
var cache_arena: ?std.heap.ArenaAllocator = null;

// Layout
const BTN_H: f32 = 20.0;
const BTN_W: f32 = 100.0;
const BTN_GAP: f32 = 4.0;
const BTN_PAD_X: f32 = 8.0;
const BTN_MARGIN_RIGHT: f32 = 10.0;
const BTN_MARGIN_TOP: f32 = 10.0;

// Colors
const btn_bg_normal = Color{ .r = 34, .g = 36, .b = 44, .a = 200 };
const btn_bg_hover = Color{ .r = 42, .g = 74, .b = 140, .a = 220 };
const btn_border = Color{ .r = 50, .g = 52, .b = 64, .a = 150 };
const btn_border_hover = Color{ .r = 91, .g = 156, .b = 245, .a = 200 };
const btn_text = Color{ .r = 180, .g = 184, .b = 196, .a = 220 };
const btn_text_hover = Color{ .r = 220, .g = 224, .b = 232, .a = 255 };

const BtnPos = struct { x: f32, y: f32 };

fn btnPos(bounds: dvui.Rect.Physical, idx: usize) BtnPos {
    return .{
        .x = bounds.x + bounds.w - BTN_W - BTN_MARGIN_RIGHT,
        .y = bounds.y + BTN_MARGIN_TOP + @as(f32, @floatFromInt(idx)) * (BTN_H + BTN_GAP),
    };
}

fn hitButton(px_val: f32, py_val: f32, bounds: dvui.Rect.Physical, idx: usize) bool {
    const p = btnPos(bounds, idx);
    return px_val >= p.x and px_val <= p.x + BTN_W and py_val >= p.y and py_val <= p.y + BTN_H;
}

pub fn tbIsHovered() bool { return hovered_idx >= 0; }

/// Process tb button input BEFORE interaction.handleInput.
pub fn tbPreInput(app: *st.AppState, wd: *dvui.WidgetData, bounds: dvui.Rect.Physical) void {
    const tbs = getTbs(app) orelse { hovered_idx = -1; return; };

    for (dvui.events()) |*ev| {
        switch (ev.evt) {
            .mouse => |me| {
                last_mouse_x = me.p.x; last_mouse_y = me.p.y;
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
    for (0..tbs.len) |idx| { if (hitButton(last_mouse_x, last_mouse_y, bounds, idx)) { new_hov = @intCast(idx); break; } }
    hovered_idx = new_hov;

    if (hovered_idx != cached_for_idx) {
        cached_for_idx = hovered_idx; cached_wire_count = 0;
        if (hovered_idx >= 0) loadWireCache(tbs[@intCast(hovered_idx)]);
    }
}

/// Draw ghost wire overlay + button strip.
pub fn tbDraw(ctx: *const RenderContext, app: *st.AppState) void {
    const tbs = getTbs(app) orelse return;
    const vp = ctx.vp;
    const pal = ctx.pal;
    const bounds = vp.bounds;
    const cw = dvui.currentWindow();

    // Ghost wire overlay
    if (hovered_idx >= 0 and cached_wire_count > 0) {
        const ghost = Color{ .r = pal.wire.r, .g = pal.wire.g, .b = pal.wire.b, .a = 90 };
        const ww: f32 = @max(0.8, 1.8 * vp.scale);
        var batch = h.LineBatch.init(cw.lifo());
        defer batch.deinit();
        batch.ensureLineCapacity(cached_wire_count) catch {};
        for (0..cached_wire_count) |i| {
            const a = h.w2p(.{ cached_x0[i], cached_y0[i] }, vp);
            const b = h.w2p(.{ cached_x1[i], cached_y1[i] }, vp);
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
            const hov = hovered_idx == @as(i32, @intCast(idx));
            batch.addLine(p.x, p.y + BTN_H * 0.5, p.x + BTN_W, p.y + BTN_H * 0.5, BTN_H, if (hov) btn_bg_hover else btn_bg_normal);
            batch.addRectOutline(.{ p.x, p.y }, .{ p.x + BTN_W, p.y + BTN_H }, 1.0, if (hov) btn_border_hover else btn_border);
        }
        batch.flush();
    }

    // Button labels
    for (tbs, 0..) |tb_path, idx| {
        const p = btnPos(bounds, idx);
        const hov = hovered_idx == @as(i32, @intCast(idx));
        h.drawLabel(tbBaseName(tb_path), p.x + BTN_PAD_X, p.y + 3.0, if (hov) btn_text_hover else btn_text, vp, idx + 80_000);
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
    const alloc = app.allocator();
    const path_dup = alloc.dupe(u8, tb_path) catch return;
    _ = shift;
    // TODO: implement load_schematic command for testbench navigation
    alloc.free(path_dup);
}

fn loadWireCache(tb_path: []const u8) void {
    cached_wire_count = 0;
    if (cache_arena) |*a| _ = a.reset(.retain_capacity);
    if (cache_arena == null) cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = cache_arena.?.allocator();
    const data = dvui.fs.cwd().readFileAlloc(arena, tb_path, std.math.maxInt(usize)) catch return;
    const sch = core.Schemify.readFile(data, arena, null);
    const wx0 = sch.wires.items(.x0); const wy0 = sch.wires.items(.y0);
    const wx1 = sch.wires.items(.x1); const wy1 = sch.wires.items(.y1);
    const n = @min(sch.wires.len, MAX_CACHED_WIRES);
    for (0..n) |i| { cached_x0[i] = wx0[i]; cached_y0[i] = wy0[i]; cached_x1[i] = wx1[i]; cached_y1[i] = wy1[i]; }
    cached_wire_count = n;
}

fn tbBaseName(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else if (std.mem.lastIndexOfScalar(u8, path, '\\')) |i| path[i + 1 ..] else path;
    inline for ([_][]const u8{ ".chn_tb", ".chn_prim", ".chn" }) |ext| {
        if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    }
    return base;
}
