//! Testbench linkage overlay.
//!
//! When the active document is a component schematic that has registered
//! testbenches in the TbIndex, this module renders a small button strip in
//! the top-right corner of the canvas — one pill per linked testbench.
//!
//! * Hover  — ghost-draws the testbench's wires over the schematic and hides
//!            port-pin primitives (ipin/opin/iopin) so the connections are visible.
//! * Click       — close the current tab and open the testbench in its place.
//! * Shift+Click — open the testbench in a new tab alongside the current one.
//!
//! Rendering is done entirely via LineBatch / drawLabel (same path as the rest
//! of the canvas) — no dvui widgets, no floating windows.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const core = @import("core");
const utility = @import("utility");
const Vfs = utility.Vfs;

const types = @import("types.zig");
const vp_mod = @import("Viewport.zig");
const h = @import("draw_helpers.zig");

const RenderContext = types.RenderContext;
const RenderViewport = types.RenderViewport;
const Vec2 = types.Vec2;
const Color = types.Color;

// ── Module-level state ────────────────────────────────────────────────────

/// Index of the currently-hovered button (-1 = none). Consumed by
/// SymbolRenderer.draw to suppress port-pin rendering during hover.
var hovered_idx: i32 = -1;

/// Last known mouse position (updated from dvui events in preInput).
var last_mouse_x: f32 = -1;
var last_mouse_y: f32 = -1;

/// Wire cache: reloaded when the hovered tb index changes.
var cached_for_idx: i32 = -2;
const MAX_CACHED_WIRES = 512;
var cached_x0: [MAX_CACHED_WIRES]i32 = undefined;
var cached_y0: [MAX_CACHED_WIRES]i32 = undefined;
var cached_x1: [MAX_CACHED_WIRES]i32 = undefined;
var cached_y1: [MAX_CACHED_WIRES]i32 = undefined;
var cached_wire_count: usize = 0;
var cache_arena: ?std.heap.ArenaAllocator = null;

// ── Layout constants ──────────────────────────────────────────────────────

const BTN_H: f32 = 20.0;
const BTN_W: f32 = 100.0;
const BTN_GAP: f32 = 4.0;
const BTN_PAD_X: f32 = 8.0;
const BTN_MARGIN_RIGHT: f32 = 10.0;
const BTN_MARGIN_TOP: f32 = 10.0;

// ── Color constants ───────────────────────────────────────────────────────

const btn_bg_normal    = Color{ .r = 35,  .g = 35,  .b = 50,  .a = 175 };
const btn_bg_hover     = Color{ .r = 60,  .g = 100, .b = 180, .a = 210 };
const btn_border       = Color{ .r = 75,  .g = 75,  .b = 100, .a = 180 };
const btn_border_hover = Color{ .r = 130, .g = 170, .b = 255, .a = 230 };
const btn_text         = Color{ .r = 190, .g = 190, .b = 205, .a = 220 };
const btn_text_hover   = Color{ .r = 240, .g = 240, .b = 255, .a = 255 };

const BtnPos = struct { x: f32, y: f32 };

fn btnPos(bounds: dvui.Rect.Physical, idx: usize) BtnPos {
    return .{
        .x = bounds.x + bounds.w - BTN_W - BTN_MARGIN_RIGHT,
        .y = bounds.y + BTN_MARGIN_TOP + @as(f32, @floatFromInt(idx)) * (BTN_H + BTN_GAP),
    };
}

fn hitButton(px: f32, py: f32, bounds: dvui.Rect.Physical, idx: usize) bool {
    const p = btnPos(bounds, idx);
    return px >= p.x and px <= p.x + BTN_W and py >= p.y and py <= p.y + BTN_H;
}

// ── Public API ────────────────────────────────────────────────────────────

/// True when a tb button is hovered. SymbolRenderer.draw reads this to
/// suppress ipin/opin/iopin rendering while the wire overlay is shown.
pub fn isHovered() bool {
    return hovered_idx >= 0;
}

/// Process button input BEFORE interaction.handleInput so button clicks are
/// not consumed by the canvas pan/select logic.
pub fn preInput(app: *st.AppState, wd: *dvui.WidgetData, bounds: dvui.Rect.Physical) void {
    const tbs = getTbs(app) orelse {
        hovered_idx = -1;
        return;
    };

    // Single event pass: track mouse position and consume button clicks.
    for (dvui.events()) |*ev| {
        switch (ev.evt) {
            .mouse => |me| {
                last_mouse_x = me.p.x;
                last_mouse_y = me.p.y;
                if (me.action == .press and me.button == .left and
                    !ev.handled and dvui.eventMatchSimple(ev, wd))
                {
                    for (tbs, 0..) |tb_path, idx| {
                        if (hitButton(me.p.x, me.p.y, bounds, idx)) {
                            ev.handled = true;
                            handleClick(app, tb_path, me.mod.shift());
                            break;
                        }
                    }
                }
            },
            else => {},
        }
    }

    // Determine hovered button from latest mouse position.
    var new_hov: i32 = -1;
    for (0..tbs.len) |idx| {
        if (hitButton(last_mouse_x, last_mouse_y, bounds, idx)) {
            new_hov = @intCast(idx);
            break;
        }
    }
    hovered_idx = new_hov;

    // Reload wire cache only when the hovered tb changes.
    if (hovered_idx != cached_for_idx) {
        cached_for_idx = hovered_idx;
        cached_wire_count = 0;
        if (hovered_idx >= 0) loadWireCache(tbs[@intCast(hovered_idx)]);
    }
}

/// Draw the wire overlay and button strip. Call after symbols are rendered
/// so the overlay and buttons appear on top.
pub fn draw(ctx: *const RenderContext, app: *st.AppState) void {
    const tbs = getTbs(app) orelse return;
    const vp = ctx.vp;
    const pal = ctx.pal;
    const bounds = vp.bounds;
    const cw = dvui.currentWindow();

    // ── Ghost wire overlay ────────────────────────────────────────────────
    if (hovered_idx >= 0 and cached_wire_count > 0) {
        const ghost = Color{ .r = pal.wire.r, .g = pal.wire.g, .b = pal.wire.b, .a = 90 };
        const ww: f32 = @max(0.8, 1.8 * vp.scale);
        var batch = h.LineBatch.init(cw.lifo());
        defer batch.deinit();
        batch.ensureLineCapacity(cached_wire_count) catch {};
        for (0..cached_wire_count) |i| {
            const a = vp_mod.w2p(.{ cached_x0[i], cached_y0[i] }, vp);
            const b = vp_mod.w2p(.{ cached_x1[i], cached_y1[i] }, vp);
            batch.addLine(a[0], a[1], b[0], b[1], ww, ghost);
        }
        batch.flush();
    }

    // ── Button backgrounds and borders ────────────────────────────────────
    {
        var batch = h.LineBatch.init(cw.lifo());
        defer batch.deinit();
        batch.ensureLineCapacity(tbs.len * 8) catch {};
        for (tbs, 0..) |_, idx| {
            const p = btnPos(bounds, idx);
            const hov = hovered_idx == @as(i32, @intCast(idx));
            // Fill: one thick horizontal line spanning the full button width.
            const bg: Color = if (hov) btn_bg_hover else btn_bg_normal;
            batch.addLine(p.x, p.y + BTN_H * 0.5, p.x + BTN_W, p.y + BTN_H * 0.5, BTN_H, bg);
            // Outline.
            const border: Color = if (hov) btn_border_hover else btn_border;
            batch.addRectOutline(.{ p.x, p.y }, .{ p.x + BTN_W, p.y + BTN_H }, 1.0, border);
        }
        batch.flush();
    }

    // ── Button labels ─────────────────────────────────────────────────────
    for (tbs, 0..) |tb_path, idx| {
        const p = btnPos(bounds, idx);
        const hov = hovered_idx == @as(i32, @intCast(idx));
        const text_col: Color = if (hov) btn_text_hover else btn_text;
        h.drawLabel(baseName(tb_path), p.x + BTN_PAD_X, p.y + 3.0, text_col, vp, idx + 80_000);
    }
}

// ── Private helpers ───────────────────────────────────────────────────────

/// Return the list of testbenches for the active document, or null if the
/// document is itself a testbench or has no registered testbenches.
fn getTbs(app: *st.AppState) ?[]const []const u8 {
    const doc = app.active() orelse return null;
    if (doc.sch.stype == .testbench) return null;
    const dut_path = switch (doc.origin) {
        .chn_file => |p| p,
        else => return null,
    };
    const tbs = app.tb_index.testbenchesFor(st.TbIndex.normalizeSymbol(dut_path));
    return if (tbs.len == 0) null else tbs;
}

/// Push open-testbench commands onto the app command queue.
fn handleClick(app: *st.AppState, tb_path: []const u8, shift: bool) void {
    const alloc = app.allocator();
    const path_dup = alloc.dupe(u8, tb_path) catch return;
    if (shift) {
        // Shift+click: open alongside current tab.
        app.queue.push(alloc, .{ .undoable = .{ .load_schematic = .{ .path = path_dup } } }) catch {};
    } else {
        // Click: replace current tab.
        app.queue.push(alloc, .{ .immediate = .close_tab }) catch {
            alloc.free(path_dup);
            return;
        };
        app.queue.push(alloc, .{ .undoable = .{ .load_schematic = .{ .path = path_dup } } }) catch {};
    }
}

/// Read the testbench schematic and copy its wire endpoints into the fixed
/// cache arrays. Uses an arena so repeated hover changes don't fragment the heap.
fn loadWireCache(tb_path: []const u8) void {
    cached_wire_count = 0;
    if (cache_arena) |*a| _ = a.reset(.retain_capacity);
    if (cache_arena == null) cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = cache_arena.?.allocator();
    const data = Vfs.readAlloc(arena, tb_path) catch return;
    const sch = core.Schemify.readFile(data, arena, null);
    const wx0 = sch.wires.items(.x0);
    const wy0 = sch.wires.items(.y0);
    const wx1 = sch.wires.items(.x1);
    const wy1 = sch.wires.items(.y1);
    const n = @min(sch.wires.len, MAX_CACHED_WIRES);
    for (0..n) |i| {
        cached_x0[i] = wx0[i];
        cached_y0[i] = wy0[i];
        cached_x1[i] = wx1[i];
        cached_y1[i] = wy1[i];
    }
    cached_wire_count = n;
}

/// Return just the basename without known schematic extensions.
fn baseName(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i|
        path[i + 1 ..]
    else if (std.mem.lastIndexOfScalar(u8, path, '\\')) |i|
        path[i + 1 ..]
    else
        path;
    inline for ([_][]const u8{ ".chn_tb", ".chn_prim", ".chn" }) |ext| {
        if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    }
    return base;
}
