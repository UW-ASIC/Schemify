const std = @import("std");
const types = @import("../types.zig");
const Immediate = types.Immediate;

pub fn handleCanvas(imm: Immediate, state: anytype) void {
    switch (imm) {
        .canvas_click => |pt| handleClick(state, .{ pt.x, pt.y }),
        .canvas_double_click => |pt| handleDoubleClick(state, .{ pt.x, pt.y }),
        .canvas_right_click => |pt| handleRightClick(state, .{ pt.x, pt.y }),
        .select_rect => |rb| handleSelectRect(state, rb),
        else => unreachable,
    }
}

// ── Drawing tool click handlers ──────────────────────────────────────────────

fn handleLineClick(state: anytype, pt: [2]i32) void {
    const draw = &state.tool.draw;
    if (draw.first_point) |fp| {
        enqueue(state, .{ .undoable = .{ .add_line = .{
            .x0 = fp[0], .y0 = fp[1], .x1 = pt[0], .y1 = pt[1],
        } } }, "Line placed");
        draw.first_point = null;
    } else {
        draw.first_point = pt;
        state.status_msg = "Line: click end point";
    }
}

fn handleRectClick(state: anytype, pt: [2]i32) void {
    const draw = &state.tool.draw;
    if (draw.first_point) |fp| {
        enqueue(state, .{ .undoable = .{ .add_rect = .{
            .x0 = fp[0], .y0 = fp[1], .x1 = pt[0], .y1 = pt[1],
        } } }, "Rect placed");
        draw.first_point = null;
    } else {
        draw.first_point = pt;
        state.status_msg = "Rect: click opposite corner";
    }
}

fn handleCircleClick(state: anytype, pt: [2]i32) void {
    const draw = &state.tool.draw;
    if (draw.first_point) |fp| {
        const dx: f64 = @floatFromInt(pt[0] - fp[0]);
        const dy: f64 = @floatFromInt(pt[1] - fp[1]);
        const radius: i32 = @intFromFloat(@round(@sqrt(dx * dx + dy * dy)));
        if (radius > 0) {
            enqueue(state, .{ .undoable = .{ .add_circle = .{
                .cx = fp[0], .cy = fp[1], .radius = radius,
            } } }, "Circle placed");
        }
        draw.first_point = null;
    } else {
        draw.first_point = pt;
        state.status_msg = "Circle: click edge point";
    }
}

fn handleArcClick(state: anytype, pt: [2]i32) void {
    const draw = &state.tool.draw;
    switch (draw.arc_step) {
        .center => {
            draw.first_point = pt;
            draw.arc_step = .radius_start;
            state.status_msg = "Arc: click start point on circumference";
        },
        .radius_start => {
            draw.arc_second = pt;
            draw.arc_step = .sweep;
            state.status_msg = "Arc: click end point for sweep";
        },
        .sweep => {
            const center = draw.first_point orelse return;
            const start_pt = draw.arc_second orelse return;
            const dx1: f64 = @floatFromInt(start_pt[0] - center[0]);
            const dy1: f64 = @floatFromInt(start_pt[1] - center[1]);
            const radius: i32 = @intFromFloat(@round(@sqrt(dx1 * dx1 + dy1 * dy1)));
            const start_angle: i16 = @intFromFloat(@round(std.math.atan2(
                -@as(f64, @floatFromInt(start_pt[1] - center[1])),
                @as(f64, @floatFromInt(start_pt[0] - center[0])),
            ) * 180.0 / std.math.pi));
            const dx2: f64 = @floatFromInt(pt[0] - center[0]);
            const dy2: f64 = @floatFromInt(pt[1] - center[1]);
            const end_angle: i16 = @intFromFloat(@round(std.math.atan2(-dy2, dx2) * 180.0 / std.math.pi));
            var sweep: i16 = end_angle - start_angle;
            if (sweep <= 0) sweep += 360;
            if (radius > 0) {
                enqueue(state, .{ .undoable = .{ .add_arc = .{
                    .cx = center[0], .cy = center[1], .radius = radius,
                    .start_angle = start_angle, .sweep_angle = sweep,
                } } }, "Arc placed");
            }
            draw.first_point = null;
            draw.arc_second = null;
            draw.arc_step = .center;
        },
    }
}

fn handlePolygonClick(state: anytype, pt: [2]i32) void {
    const draw = &state.tool.draw;
    if (draw.polygon_len < draw.polygon_points.len) {
        draw.polygon_points[draw.polygon_len] = pt;
        draw.polygon_len += 1;
        state.status_msg = "Polygon: click next vertex (double-click or right-click to close)";
    } else {
        state.status_msg = "Polygon: max vertices reached, closing";
        closePolygon(state);
    }
}

fn closePolygon(state: anytype) void {
    const draw = &state.tool.draw;
    const n = draw.polygon_len;
    if (n < 2) {
        draw.polygon_len = 0;
        state.status_msg = "Polygon cancelled (need at least 2 points)";
        return;
    }
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const next = if (i + 1 < n) i + 1 else 0;
        enqueue(state, .{ .undoable = .{ .add_line = .{
            .x0 = draw.polygon_points[i][0], .y0 = draw.polygon_points[i][1],
            .x1 = draw.polygon_points[next][0], .y1 = draw.polygon_points[next][1],
        } } }, "Polygon edge");
    }
    draw.polygon_len = 0;
    state.status_msg = "Polygon placed";
}

fn handleTextClick(state: anytype, pt: [2]i32) void {
    const draw = &state.tool.draw;
    draw.text_pos = pt;
    draw.text_input_active = true;
    draw.text_len = 0;
    @memset(&draw.text_buf, 0);
    state.status_msg = "Text: type text, press Enter to place";
}

fn cancelDrawingTool(state: anytype) bool {
    const draw = &state.tool.draw;
    switch (state.tool.active) {
        .line, .rect, .circle => {
            if (draw.first_point != null) {
                draw.first_point = null;
                state.status_msg = "Cancelled";
                return true;
            }
        },
        .arc => {
            if (draw.first_point != null) {
                draw.first_point = null;
                draw.arc_second = null;
                draw.arc_step = .center;
                state.status_msg = "Arc cancelled";
                return true;
            }
        },
        .polygon => {
            if (draw.polygon_len > 0) {
                closePolygon(state);
                return true;
            }
        },
        .text => {
            if (draw.text_input_active) {
                draw.text_input_active = false;
                draw.text_pos = null;
                draw.text_len = 0;
                state.status_msg = "Text cancelled";
                return true;
            }
        },
        else => {},
    }
    return false;
}

// ── Main event handlers ──────────────────────────────────────────────────────

// File-scope buffer for placement name (avoids dangling slice from stack-local Placement copy)
var place_name_buf: [32]u8 = undefined;

fn handleClick(state: anytype, pt: [2]i32) void {
    // Placement mode: left-click places the component
    if (state.tool.placement) |pl| {
        const ks = pl.kindSlice();
        @memcpy(place_name_buf[0..ks.len], ks);
        const name = place_name_buf[0..ks.len];
        enqueue(state, .{ .undoable = .{ .place_device = .{
            .sym_path = name, .name = name, .x = pt[0], .y = pt[1],
            .rot = pl.rot, .flip = pl.flip,
        } } }, "Placed device");
        state.tool.placement = null;
        return;
    }
    switch (state.tool.active) {
        .wire => {
            if (state.tool.wire_start) |ws| {
                const dx: u64 = @abs(@as(i64, pt[0]) - ws[0]);
                const dy: u64 = @abs(@as(i64, pt[1]) - ws[1]);
                const end: [2]i32 = if (dx >= dy) .{ pt[0], ws[1] } else .{ ws[0], pt[1] };
                enqueue(state, .{ .undoable = .{ .add_wire = .{ .x0 = ws[0], .y0 = ws[1], .x1 = end[0], .y1 = end[1], .bus = state.tool.bus_mode } } }, if (state.tool.bus_mode) "Bus placed" else "Wire placed");
                state.tool.wire_start = end;
            } else {
                state.tool.wire_start = pt;
                state.status_msg = "Wire start set";
            }
        },
        .select => {
            const doc = state.active() orelse return;
            const a = state.allocator();
            if (hitTestInstance(&doc.sch, pt)) |idx| {
                const already = doc.selection.instances.bit_length > idx and doc.selection.instances.isSet(idx);
                if (!already) {
                    doc.selection.clear();
                    doc.selection.instances.resize(a, doc.sch.instances.len, false) catch return;
                    doc.selection.instances.set(idx);
                    state.status_msg = "Selected instance";
                }
            } else if (hitTestWire(&doc.sch, pt)) |idx| {
                const already = doc.selection.wires.bit_length > idx and doc.selection.wires.isSet(idx);
                if (!already) {
                    doc.selection.clear();
                    doc.selection.wires.resize(a, doc.sch.wires.len, false) catch return;
                    doc.selection.wires.set(idx);
                    state.status_msg = "Selected wire";
                }
            } else if (hitTestShape(&doc.sch, pt)) |sh| {
                doc.selection.clear();
                doc.selection.ensureShapeCapacity(a, &doc.sch, false) catch return;
                const bits = switch (sh.kind) {
                    .line => &doc.selection.lines,
                    .rect => &doc.selection.rects,
                    .circle => &doc.selection.circles,
                    .arc => &doc.selection.arcs,
                    .text => &doc.selection.texts,
                };
                bits.set(sh.idx);
                state.status_msg = "Selected shape";
            } else {
                doc.selection.clear();
                state.status_msg = "Ready";
            }
        },
        .line => handleLineClick(state, pt),
        .rect => handleRectClick(state, pt),
        .circle => handleCircleClick(state, pt),
        .arc => handleArcClick(state, pt),
        .polygon => handlePolygonClick(state, pt),
        .text => handleTextClick(state, pt),
        else => {},
    }
}

fn handleDoubleClick(state: anytype, pt: [2]i32) void {
    if (state.tool.active == .polygon) {
        closePolygon(state);
    } else {
        _ = pt;
        enqueue(state, .{ .immediate = .edit_properties }, "Edit properties");
    }
}

fn handleRightClick(state: anytype, pt: [2]i32) void {
    if (cancelDrawingTool(state)) return;
    if (state.tool.placement != null) {
        state.tool.placement = null;
        state.status_msg = "Placement cancelled";
        return;
    }
    if (state.tool.active == .wire and state.tool.wire_start != null) {
        state.tool.wire_start = null;
        state.status_msg = "Wire cancelled";
        return;
    }
    // Context menu handled by GUI (no state mutation needed here for headless)
    _ = pt;
}

fn handleSelectRect(state: anytype, rb: anytype) void {
    const doc = state.active() orelse return;
    const a = state.allocator();
    const sch = &doc.sch;
    doc.selection.ensureCapacity(a, sch.instances.len, sch.wires.len, false) catch return;
    doc.selection.ensureShapeCapacity(a, sch, false) catch return;
    doc.selection.clear();
    var count: usize = 0;
    // Instances
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    for (0..sch.instances.len) |i| {
        if (xs[i] >= rb.x0 and xs[i] <= rb.x1 and ys[i] >= rb.y0 and ys[i] <= rb.y1) {
            doc.selection.instances.set(i);
            count += 1;
        }
    }
    // Wires
    for (0..sch.wires.len) |i| {
        if (@min(sch.wires.items(.x0)[i], sch.wires.items(.x1)[i]) >= rb.x0 and
            @max(sch.wires.items(.x0)[i], sch.wires.items(.x1)[i]) <= rb.x1 and
            @min(sch.wires.items(.y0)[i], sch.wires.items(.y1)[i]) >= rb.y0 and
            @max(sch.wires.items(.y0)[i], sch.wires.items(.y1)[i]) <= rb.y1)
        {
            doc.selection.wires.set(i);
            count += 1;
        }
    }
    // Lines
    for (0..sch.lines.len) |i| {
        if (@min(sch.lines.items(.x0)[i], sch.lines.items(.x1)[i]) >= rb.x0 and
            @max(sch.lines.items(.x0)[i], sch.lines.items(.x1)[i]) <= rb.x1 and
            @min(sch.lines.items(.y0)[i], sch.lines.items(.y1)[i]) >= rb.y0 and
            @max(sch.lines.items(.y0)[i], sch.lines.items(.y1)[i]) <= rb.y1)
        {
            doc.selection.lines.set(i);
            count += 1;
        }
    }
    // Rects
    for (0..sch.rects.len) |i| {
        if (@min(sch.rects.items(.x0)[i], sch.rects.items(.x1)[i]) >= rb.x0 and
            @max(sch.rects.items(.x0)[i], sch.rects.items(.x1)[i]) <= rb.x1 and
            @min(sch.rects.items(.y0)[i], sch.rects.items(.y1)[i]) >= rb.y0 and
            @max(sch.rects.items(.y0)[i], sch.rects.items(.y1)[i]) <= rb.y1)
        {
            doc.selection.rects.set(i);
            count += 1;
        }
    }
    // Circles
    for (0..sch.circles.len) |i| {
        const cx = sch.circles.items(.cx)[i];
        const cy = sch.circles.items(.cy)[i];
        const r = sch.circles.items(.radius)[i];
        if (cx - r >= rb.x0 and cx + r <= rb.x1 and cy - r >= rb.y0 and cy + r <= rb.y1) {
            doc.selection.circles.set(i);
            count += 1;
        }
    }
    // Arcs
    for (0..sch.arcs.len) |i| {
        const cx = sch.arcs.items(.cx)[i];
        const cy = sch.arcs.items(.cy)[i];
        const r = sch.arcs.items(.radius)[i];
        if (cx - r >= rb.x0 and cx + r <= rb.x1 and cy - r >= rb.y0 and cy + r <= rb.y1) {
            doc.selection.arcs.set(i);
            count += 1;
        }
    }
    // Texts
    for (0..sch.texts.len) |i| {
        const tx = sch.texts.items(.x)[i];
        const ty = sch.texts.items(.y)[i];
        if (tx >= rb.x0 and tx <= rb.x1 and ty >= rb.y0 and ty <= rb.y1) {
            doc.selection.texts.set(i);
            count += 1;
        }
    }
    state.status_msg = if (count > 0) "Selected" else "Ready";
}

// ── Hit-testing (pure functions over schematic data) ─────────────────────────

const select_hit_radius_sq: i64 = 400;

pub fn hitTestInstance(sch: anytype, world: [2]i32) ?usize {
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const px: f32 = @floatFromInt(world[0]);
    const py: f32 = @floatFromInt(world[1]);
    const r2: f32 = @floatFromInt(select_hit_radius_sq);
    for (0..sch.instances.len) |i| {
        const dx = px - @as(f32, @floatFromInt(xs[i]));
        const dy = py - @as(f32, @floatFromInt(ys[i]));
        if (dx * dx + dy * dy < r2) return i;
    }
    return null;
}

pub fn hitTestWire(sch: anytype, world: [2]i32) ?usize {
    const x0s = sch.wires.items(.x0);
    const y0s = sch.wires.items(.y0);
    const x1s = sch.wires.items(.x1);
    const y1s = sch.wires.items(.y1);
    const tol2: f64 = @floatFromInt(select_hit_radius_sq);
    const wpx: f64 = @floatFromInt(world[0]);
    const wpy: f64 = @floatFromInt(world[1]);
    for (0..sch.wires.len) |i| {
        const ax: f64 = @floatFromInt(x0s[i]);
        const ay: f64 = @floatFromInt(y0s[i]);
        const bx: f64 = @floatFromInt(x1s[i]);
        const by: f64 = @floatFromInt(y1s[i]);
        if (ptSegDist2(wpx, wpy, ax, ay, bx, by) < tol2) return i;
    }
    return null;
}

pub const ShapeKind = enum { line, rect, circle, arc, text };
pub const ShapeHit = struct { kind: ShapeKind, idx: usize };

pub fn hitTestShape(sch: anytype, world: [2]i32) ?ShapeHit {
    const wpx: f64 = @floatFromInt(world[0]);
    const wpy: f64 = @floatFromInt(world[1]);
    const tol2: f64 = @floatFromInt(select_hit_radius_sq);

    for (0..sch.lines.len) |i| {
        const ax: f64 = @floatFromInt(sch.lines.items(.x0)[i]);
        const ay: f64 = @floatFromInt(sch.lines.items(.y0)[i]);
        const bx: f64 = @floatFromInt(sch.lines.items(.x1)[i]);
        const by: f64 = @floatFromInt(sch.lines.items(.y1)[i]);
        if (ptSegDist2(wpx, wpy, ax, ay, bx, by) < tol2) return .{ .kind = .line, .idx = i };
    }
    for (0..sch.rects.len) |i| {
        const rx0: f64 = @floatFromInt(sch.rects.items(.x0)[i]);
        const ry0: f64 = @floatFromInt(sch.rects.items(.y0)[i]);
        const rx1: f64 = @floatFromInt(sch.rects.items(.x1)[i]);
        const ry1: f64 = @floatFromInt(sch.rects.items(.y1)[i]);
        if (ptSegDist2(wpx, wpy, rx0, ry0, rx1, ry0) < tol2 or
            ptSegDist2(wpx, wpy, rx1, ry0, rx1, ry1) < tol2 or
            ptSegDist2(wpx, wpy, rx1, ry1, rx0, ry1) < tol2 or
            ptSegDist2(wpx, wpy, rx0, ry1, rx0, ry0) < tol2) return .{ .kind = .rect, .idx = i };
    }
    for (0..sch.circles.len) |i| {
        const cx: f64 = @floatFromInt(sch.circles.items(.cx)[i]);
        const cy: f64 = @floatFromInt(sch.circles.items(.cy)[i]);
        const r: f64 = @floatFromInt(sch.circles.items(.radius)[i]);
        const dx = wpx - cx;
        const dy = wpy - cy;
        const d = @sqrt(dx * dx + dy * dy);
        if ((d - r) * (d - r) < tol2) return .{ .kind = .circle, .idx = i };
    }
    for (0..sch.arcs.len) |i| {
        const cx: f64 = @floatFromInt(sch.arcs.items(.cx)[i]);
        const cy: f64 = @floatFromInt(sch.arcs.items(.cy)[i]);
        const r: f64 = @floatFromInt(sch.arcs.items(.radius)[i]);
        const dx = wpx - cx;
        const dy = wpy - cy;
        const d = @sqrt(dx * dx + dy * dy);
        if ((d - r) * (d - r) < tol2) return .{ .kind = .arc, .idx = i };
    }
    for (0..sch.texts.len) |i| {
        const tx: f64 = @floatFromInt(sch.texts.items(.x)[i]);
        const ty: f64 = @floatFromInt(sch.texts.items(.y)[i]);
        const ddx = wpx - tx;
        const ddy = wpy - ty;
        if (ddx * ddx + ddy * ddy < tol2 * 4) return .{ .kind = .text, .idx = i };
    }
    return null;
}

fn ptSegDist2(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) f64 {
    const abx = bx - ax;
    const aby = by - ay;
    const len2 = abx * abx + aby * aby;
    if (len2 <= 0.0) {
        const ddx = px - ax;
        const ddy = py - ay;
        return ddx * ddx + ddy * ddy;
    }
    var t = ((px - ax) * abx + (py - ay) * aby) / len2;
    if (t < 0.0) t = 0.0 else if (t > 1.0) t = 1.0;
    const cx = ax + t * abx;
    const cy = ay + t * aby;
    const ddx = px - cx;
    const ddy = py - cy;
    return ddx * ddx + ddy * ddy;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn enqueue(state: anytype, cmd: types.Command, ok_msg: []const u8) void {
    const alloc = state.allocator();
    state.queue.push(alloc, cmd) catch {
        state.status_msg = "Command queue is full";
        return;
    };
    state.status_msg = ok_msg;
}
