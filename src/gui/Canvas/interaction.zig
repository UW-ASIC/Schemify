//! Mouse/keyboard dvui events -> CanvasEvent.
//! State lives in app.gui.hot.canvas (CanvasState).
//!
//! Gestures handled directly:
//!   Middle-drag pan | Space+left-drag pan | Space tap -> sticky grab | Wheel zoom
//!   Drag-to-move selected instances (>4px threshold) | Rubber-band selection
//!
//! Events emitted to lib.zig:
//!   .click | .double_click | .right_click (with hit-tested inst_idx / wire_idx)

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const core = @import("core");

const types = @import("types.zig");
const h = @import("render.zig");

const Vec2 = types.Vec2;
const Point = types.Point;
const CanvasEvent = types.CanvasEvent;
const RenderViewport = types.RenderViewport;
const CanvasState = st.CanvasState;
const PanMode = st.PanMode;
const Schemify = core.Schemify;

const move_drag_threshold_px: f32 = 4.0;
const select_hit_radius_sq: i64 = 400;

// ═══════════════════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleInput(cs: *CanvasState, app: *st.AppState, wd: *dvui.WidgetData, vp: RenderViewport) CanvasEvent {
    var result: CanvasEvent = .none;
    const snap = app.tool.snap_size;

    for (dvui.events()) |*ev| {
        if (ev.handled or !dvui.eventMatchSimple(ev, wd)) continue;
        switch (ev.evt) {
            .key => |ke| {
                if (ke.code == .space) { handleSpaceKey(cs, ke.action); ev.handled = true; }
            },
            .mouse => |me| {
                const mp: Vec2 = .{ me.p.x, me.p.y };
                switch (me.action) {
                    .press => { ev.handled = true; result = handleMousePress(cs, app, me.button, mp, vp, snap); },
                    .release => { ev.handled = true; const r = handleMouseRelease(cs, me.button); if (r != .none) result = r; },
                    .motion => {
                        cs.cursor_world = h.p2w(mp, vp, snap);
                        if (handleMouseMotion(cs, app, mp, vp, snap)) ev.handled = true;
                    },
                    .wheel_y => |dy| { ev.handled = true; handleWheelZoom(app, mp, dy, vp); },
                    else => {},
                }
            },
            else => {},
        }
    }
    return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// Hit-testing (public — used by lib.zig for hover dispatch)
// ═══════════════════════════════════════════════════════════════════════════

pub fn hitTestInstance(sch: *const Schemify, world: Point) ?usize {
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const flags = sch.instances.items(.flags);
    const px: f32 = @floatFromInt(world[0]);
    const py: f32 = @floatFromInt(world[1]);
    for (0..sch.instances.len) |i| {
        const dx = px - @as(f32, @floatFromInt(xs[i]));
        const dy = py - @as(f32, @floatFromInt(ys[i]));
        if (instanceShapeHit(sch, i, dx, dy, flags[i].rot, flags[i].flip)) return i;
    }
    return null;
}

pub fn hitTestWire(sch: *const Schemify, world: Point) ?usize {
    const x0s = sch.wires.items(.x0); const y0s = sch.wires.items(.y0);
    const x1s = sch.wires.items(.x1); const y1s = sch.wires.items(.y1);
    const tol2: f64 = @floatFromInt(select_hit_radius_sq);
    const wpx: f64 = @floatFromInt(world[0]);
    const wpy: f64 = @floatFromInt(world[1]);
    for (0..sch.wires.len) |i| {
        const ax: f64 = @floatFromInt(x0s[i]); const ay: f64 = @floatFromInt(y0s[i]);
        const bx: f64 = @floatFromInt(x1s[i]); const by: f64 = @floatFromInt(y1s[i]);
        const abx = bx - ax; const aby = by - ay;
        const len2 = abx * abx + aby * aby;
        var d2: f64 = undefined;
        if (len2 <= 0.0) {
            const ddx = wpx - ax; const ddy = wpy - ay;
            d2 = ddx * ddx + ddy * ddy;
        } else {
            var t = ((wpx - ax) * abx + (wpy - ay) * aby) / len2;
            if (t < 0.0) t = 0.0 else if (t > 1.0) t = 1.0;
            const cx = ax + t * abx; const cy = ay + t * aby;
            const ddx = wpx - cx; const ddy = wpy - cy;
            d2 = ddx * ddx + ddy * ddy;
        }
        if (d2 < tol2) return i;
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════
// Private gesture handlers
// ═══════════════════════════════════════════════════════════════════════════

fn handleSpaceKey(cs: *CanvasState, action: anytype) void {
    switch (action) {
        .down => { cs.space_held = true; cs.space_drag_happened = false; },
        .up => {
            cs.space_held = false;
            if (!cs.space_drag_happened) cs.pan_mode = .grab;
            cs.space_drag_happened = false;
        },
        else => {},
    }
}

fn handleMousePress(cs: *CanvasState, app: *st.AppState, button: dvui.enums.Button, mp: Vec2, vp: RenderViewport, snap: f32) CanvasEvent {
    switch (button) {
        .left => {
            if (cs.pan_mode == .grab) {
                cs.pan_mode = .off; cs.dragging = false; cs.move_hit_idx = -1; cs.move_active = false;
                return .none;
            } else if (cs.space_held) {
                cs.dragging = true; cs.drag_is_pan = true; cs.drag_last = .{ mp[0], mp[1] };
                return .none;
            } else {
                primeMoveIfOnSelected(cs, app, mp, vp);
                if (cs.move_hit_idx < 0 and app.tool.active == .select) {
                    const world = h.p2w(mp, vp, snap);
                    cs.rubber_band_start = world; cs.rubber_band_end = world;
                    cs.rubber_band_active = false; cs.move_press_pixel = .{ mp[0], mp[1] };
                    cs.dragging = true; cs.drag_is_pan = false; cs.drag_last = .{ mp[0], mp[1] };
                }
                return handleClick(cs, mp, vp, snap);
            }
        },
        .middle => { cs.dragging = true; cs.drag_is_pan = true; cs.drag_last = .{ mp[0], mp[1] }; return .none; },
        .right => {
            const world = h.p2w(mp, vp, snap);
            const hit_result = hitTestCanvas(app, world);
            return .{ .right_click = .{ .pixel = mp, .world = world, .inst_idx = hit_result.inst_idx, .wire_idx = hit_result.wire_idx } };
        },
        else => return .none,
    }
}

fn handleMouseRelease(cs: *CanvasState, button: dvui.enums.Button) CanvasEvent {
    if (button == .left) {
        var result: CanvasEvent = .none;
        if (cs.rubber_band_active) {
            result = .{ .rubber_band_complete = .{
                .min = .{ @min(cs.rubber_band_start[0], cs.rubber_band_end[0]), @min(cs.rubber_band_start[1], cs.rubber_band_end[1]) },
                .max = .{ @max(cs.rubber_band_start[0], cs.rubber_band_end[0]), @max(cs.rubber_band_start[1], cs.rubber_band_end[1]) },
            } };
        }
        cs.rubber_band_active = false; cs.move_active = false; cs.move_hit_idx = -1;
        cs.dragging = false; cs.drag_is_pan = false;
        return result;
    } else if (button == .middle) {
        cs.dragging = false; cs.drag_is_pan = false;
    }
    return .none;
}

fn handleMouseMotion(cs: *CanvasState, app: *st.AppState, cur: Vec2, vp: RenderViewport, snap: f32) bool {
    // Drag-to-move promotion.
    if (!cs.move_active and cs.move_hit_idx >= 0) {
        const dx_px = cur[0] - cs.move_press_pixel[0];
        const dy_px = cur[1] - cs.move_press_pixel[1];
        if (dx_px * dx_px + dy_px * dy_px >= move_drag_threshold_px * move_drag_threshold_px) {
            cs.move_active = true; cs.drag_last = .{ cur[0], cur[1] };
        }
    }
    if (cs.move_active) { moveSelectedByMotion(app, cs, cur, vp, snap); cs.drag_last = .{ cur[0], cur[1] }; return true; }

    // Rubber-band selection drag.
    if (cs.dragging and !cs.drag_is_pan and cs.move_hit_idx < 0 and app.tool.active == .select) {
        if (!cs.rubber_band_active) {
            const pdx = cur[0] - cs.move_press_pixel[0]; const pdy = cur[1] - cs.move_press_pixel[1];
            if (pdx * pdx + pdy * pdy < move_drag_threshold_px * move_drag_threshold_px) return false;
            cs.rubber_band_active = true;
        }
        cs.rubber_band_end = h.p2w(cur, vp, snap);
        return true;
    }

    // Pan drag.
    if (cs.dragging and cs.drag_is_pan) {
        if (cs.space_held) cs.space_drag_happened = true;
        panBy(app, cs, cur, vp);
        return true;
    }

    // Sticky grab mode.
    if (cs.pan_mode == .grab) {
        if (cs.drag_last[0] == 0 and cs.drag_last[1] == 0) cs.drag_last = .{ cur[0], cur[1] } else panBy(app, cs, cur, vp);
        return true;
    }
    return false;
}

fn handleWheelZoom(app: *st.AppState, cursor: Vec2, dy: f32, vp: RenderViewport) void {
    const world_before = h.p2w_raw(cursor, vp);
    const factor: f32 = if (dy > 0) 1.25 else (1.0 / 1.25);
    const ad = app.active() orelse return;
    ad.view.zoom = std.math.clamp(ad.view.zoom * factor, 0.01, 50.0);
    const new_vp = RenderViewport{ .cx = vp.cx, .cy = vp.cy, .scale = vp.scale * factor, .rs_s = vp.rs_s, .pan = ad.view.pan, .bounds = vp.bounds };
    const world_after = h.p2w_raw(cursor, new_vp);
    ad.view.pan[0] += world_before[0] - world_after[0];
    ad.view.pan[1] += world_before[1] - world_after[1];
}

fn panBy(app: *st.AppState, cs: *CanvasState, cur: Vec2, vp: RenderViewport) void {
    const drag_last_vec: Vec2 = .{ cs.drag_last[0], cs.drag_last[1] };
    const delta = cur - drag_last_vec;
    const inv_s: Vec2 = @splat(1.0 / vp.scale);
    const pan_delta = delta * inv_s;
    if (app.active()) |ad| { ad.view.pan[0] -= pan_delta[0]; ad.view.pan[1] -= pan_delta[1]; }
    cs.drag_last = .{ cur[0], cur[1] };
}

fn moveSelectedByMotion(app: *st.AppState, cs: *CanvasState, cur: Vec2, vp: RenderViewport, snap: f32) void {
    const doc = app.active() orelse return;
    const sch = &doc.sch;
    const prev_world = h.p2w(.{ cs.drag_last[0], cs.drag_last[1] }, vp, snap);
    const curr_world = h.p2w(cur, vp, snap);
    const dx = curr_world[0] - prev_world[0];
    const dy = curr_world[1] - prev_world[1];
    if (dx == 0 and dy == 0) return;

    var moved = false;
    const xs = sch.instances.items(.x); const ys = sch.instances.items(.y);
    if (doc.selection.instances.bit_length > 0) {
        var it = doc.selection.instances.iterator(.{}); while (it.next()) |idx| { if (idx >= xs.len) continue; xs[idx] += dx; ys[idx] += dy; moved = true; }
    }
    const x0s = sch.wires.items(.x0); const y0s = sch.wires.items(.y0);
    const x1s = sch.wires.items(.x1); const y1s = sch.wires.items(.y1);
    if (doc.selection.wires.bit_length > 0) {
        var wit = doc.selection.wires.iterator(.{}); while (wit.next()) |idx| { if (idx >= sch.wires.len) continue; x0s[idx] += dx; y0s[idx] += dy; x1s[idx] += dx; y1s[idx] += dy; moved = true; }
    }
    if (moved) doc.dirty = true;
}

fn primeMoveIfOnSelected(cs: *CanvasState, app: *st.AppState, mp: Vec2, vp: RenderViewport) void {
    cs.move_hit_idx = -1; cs.move_active = false;
    if (cs.space_held or cs.pan_mode != .off) return;
    const doc = app.active() orelse return;
    const sch = &doc.sch;
    if (sch.instances.len == 0 and sch.wires.len == 0) return;

    const world = h.p2w_raw(mp, vp);
    const wx: i32 = @intFromFloat(@round(world[0]));
    const wy: i32 = @intFromFloat(@round(world[1]));
    const world_pt: Point = .{ wx, wy };

    if (hitTestInstance(sch, world_pt)) |hit_idx| {
        const d = app.active() orelse return;
        if (hit_idx < d.selection.instances.bit_length and d.selection.instances.isSet(hit_idx)) {
            cs.move_hit_idx = @intCast(hit_idx);
            cs.move_press_pixel = .{ mp[0], mp[1] }; cs.move_start_world = .{ wx, wy }; cs.drag_last = .{ mp[0], mp[1] };
            return;
        }
    }
    if (hitTestWire(sch, world_pt)) |hit_idx| {
        const d = app.active() orelse return;
        if (hit_idx < d.selection.wires.bit_length and d.selection.wires.isSet(hit_idx)) {
            cs.move_hit_idx = @intCast(hit_idx);
            cs.move_press_pixel = .{ mp[0], mp[1] }; cs.move_start_world = .{ wx, wy }; cs.drag_last = .{ mp[0], mp[1] };
        }
    }
}

fn handleClick(cs: *CanvasState, mp: Vec2, vp: RenderViewport, snap: f32) CanvasEvent {
    const now: f64 = @as(f64, @floatFromInt(dvui.frameTimeNS())) / 1_000_000_000.0;
    const dt = now - cs.last_click_time;
    const last_pos: Vec2 = .{ cs.last_click_pos[0], cs.last_click_pos[1] };
    const dp = mp - last_pos;
    const dist = @sqrt(dp[0] * dp[0] + dp[1] * dp[1]);
    const world_pt = h.p2w(mp, vp, snap);

    if (dt < 0.4 and dist < 10.0) { cs.last_click_time = 0; return .{ .double_click = world_pt }; }
    cs.last_click_time = now; cs.last_click_pos = .{ mp[0], mp[1] };
    return .{ .click = world_pt };
}

const HitResult = struct { inst_idx: i32, wire_idx: i32 };

fn hitTestCanvas(app: *st.AppState, world: Point) HitResult {
    const doc = app.active() orelse return .{ .inst_idx = -1, .wire_idx = -1 };
    const sch = &doc.sch;
    if (hitTestInstance(sch, world)) |idx| return .{ .inst_idx = @intCast(idx), .wire_idx = -1 };
    if (hitTestWire(sch, world)) |idx| return .{ .inst_idx = -1, .wire_idx = @intCast(idx) };
    return .{ .inst_idx = -1, .wire_idx = -1 };
}

fn inverseRotFlip(dx: f32, dy: f32, rot: u2, flip: bool) [2]f32 {
    const ur: [2]f32 = switch (rot) { 0 => .{ dx, dy }, 1 => .{ dy, -dx }, 2 => .{ -dx, -dy }, 3 => .{ -dy, dx } };
    return .{ if (flip) -ur[0] else ur[0], ur[1] };
}

fn lookupPrimEntry(sch: *const Schemify, idx: usize) ?*const core.devices.primitives.PrimEntry {
    const kinds = sch.instances.items(.kind);
    if (idx >= kinds.len) return null;
    return core.devices.primitives.findByNameRuntime(@tagName(kinds[idx]));
}

fn instanceShapeHit(sch: *const Schemify, idx: usize, dx: f32, dy: f32, rot: u2, flip: bool) bool {
    const prim = lookupPrimEntry(sch, idx);
    if (prim) |entry| {
        if (entry.hasDrawing()) {
            const local = inverseRotFlip(dx, dy, rot, flip);
            var min_x: f32 = std.math.floatMax(f32); var max_x: f32 = -std.math.floatMax(f32);
            var min_y: f32 = std.math.floatMax(f32); var max_y: f32 = -std.math.floatMax(f32);
            for (entry.segs()) |s| {
                const ax: f32 = @floatFromInt(s.x0); const ay: f32 = @floatFromInt(s.y0);
                const bx: f32 = @floatFromInt(s.x1); const by: f32 = @floatFromInt(s.y1);
                min_x = @min(min_x, @min(ax, bx)); max_x = @max(max_x, @max(ax, bx));
                min_y = @min(min_y, @min(ay, by)); max_y = @max(max_y, @max(ay, by));
            }
            for (entry.drawCircles()) |c| {
                const r: f32 = @floatFromInt(c.r); const cx: f32 = @floatFromInt(c.cx); const cy: f32 = @floatFromInt(c.cy);
                min_x = @min(min_x, cx - r); max_x = @max(max_x, cx + r); min_y = @min(min_y, cy - r); max_y = @max(max_y, cy + r);
            }
            for (entry.drawRects()) |r| {
                const ax: f32 = @floatFromInt(r.x0); const ay: f32 = @floatFromInt(r.y0);
                const bx: f32 = @floatFromInt(r.x1); const by: f32 = @floatFromInt(r.y1);
                min_x = @min(min_x, @min(ax, bx)); max_x = @max(max_x, @max(ax, bx));
                min_y = @min(min_y, @min(ay, by)); max_y = @max(max_y, @max(ay, by));
            }
            const pad_val: f32 = 8.0;
            return local[0] >= min_x - pad_val and local[0] <= max_x + pad_val and local[1] >= min_y - pad_val and local[1] <= max_y + pad_val;
        }
    }
    const r2: f32 = @floatFromInt(select_hit_radius_sq);
    return dx * dx + dy * dy < r2;
}
