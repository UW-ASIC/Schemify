//! Wire placement command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const CT = state_mod.CT;
const cmd = @import("../command.zig");
const Command = cmd.Command;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .start_wire => {
            state.tool.active = .wire;
            state.tool.wire_start = null;
            state.setStatus("Wire mode — click to start");
        },
        .start_wire_snap => {
            state.tool.active = .wire;
            state.tool.wire_start = null;
            state.setStatus("Wire mode (snap) — click to start");
        },
        .cancel_wire => {
            state.tool.wire_start = null;
            state.tool.active = .select;
            state.setStatus("Wire canceled");
        },
        .finish_wire => state.setStatus("Wire finished (stub)"),
        .toggle_wire_routing => {
            state.cmd_flags.wire_routing = !state.cmd_flags.wire_routing;
            state.setStatus(if (state.cmd_flags.wire_routing) "Wire routing on (stub)" else "Wire routing off (stub)");
        },
        .toggle_orthogonal_routing => {
            state.cmd_flags.orthogonal_routing = !state.cmd_flags.orthogonal_routing;
            state.setStatus(if (state.cmd_flags.orthogonal_routing) "Orthogonal routing on (stub)" else "Orthogonal routing off (stub)");
        },
        .break_wires_at_connections => try breakWiresAtConnections(state),
        .join_collapse_wires => try joinCollapseWires(state),
        .start_line => {
            state.tool.active = .line;
            state.setStatus("Line draw mode (stub)");
        },
        .start_rect => {
            state.tool.active = .rect;
            state.setStatus("Rect draw mode (stub)");
        },
        .start_polygon => {
            state.tool.active = .polygon;
            state.setStatus("Polygon draw mode (stub)");
        },
        .start_arc => {
            state.tool.active = .arc;
            state.setStatus("Arc draw mode (stub)");
        },
        .start_circle => {
            state.tool.active = .circle;
            state.setStatus("Circle draw mode (stub)");
        },
        else => unreachable,
    }
}

fn ptEq(a: CT.Point, b: CT.Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn breakWiresAtConnections(state: *AppState) !void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = sch.alloc();
    var i: usize = 0;
    while (i < sch.wires.items.len) {
        const w = sch.wires.items[i];
        var split_pt: ?CT.Point = null;
        for (sch.wires.items, 0..) |other, j| {
            if (i == j) continue;
            if (pointOnSegmentStrict(other.start, w.start, w.end)) { split_pt = other.start; break; }
            if (pointOnSegmentStrict(other.end, w.start, w.end)) { split_pt = other.end; break; }
        }
        if (split_pt) |sp| {
            const w0 = CT.Wire{ .start = w.start, .end = sp, .net_name = w.net_name };
            const w1 = CT.Wire{ .start = sp, .end = w.end, .net_name = w.net_name };
            _ = sch.wires.orderedRemove(i);
            try sch.wires.insert(alloc, i, w0);
            try sch.wires.insert(alloc, i + 1, w1);
            i += 2;
        } else {
            i += 1;
        }
    }
    fio.dirty = true;
    state.setStatus("Wires broken at connections");
}

fn joinCollapseWires(state: *AppState) !void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = sch.alloc();
    var i: usize = 0;
    while (i < sch.wires.items.len) {
        const wa = sch.wires.items[i];
        var merged = false;
        var j: usize = i + 1;
        while (j < sch.wires.items.len) {
            const wb = sch.wires.items[j];
            if (wiresCollinear(wa, wb)) {
                var merged_wire: ?CT.Wire = null;
                if (ptEq(wa.end, wb.start)) {
                    merged_wire = .{ .start = wa.start, .end = wb.end, .net_name = wa.net_name };
                } else if (ptEq(wa.start, wb.end)) {
                    merged_wire = .{ .start = wb.start, .end = wa.end, .net_name = wa.net_name };
                } else if (ptEq(wa.start, wb.start)) {
                    merged_wire = .{ .start = wa.end, .end = wb.end, .net_name = wa.net_name };
                } else if (ptEq(wa.end, wb.end)) {
                    merged_wire = .{ .start = wa.start, .end = wb.start, .net_name = wa.net_name };
                }
                if (merged_wire) |mw| {
                    _ = sch.wires.orderedRemove(j);
                    _ = sch.wires.orderedRemove(i);
                    try sch.wires.insert(alloc, i, mw);
                    merged = true;
                    break;
                }
            }
            j += 1;
        }
        if (!merged) i += 1;
    }
    fio.dirty = true;
    state.setStatus("Wires joined");
}

fn pointOnSegmentStrict(p: CT.Point, a: CT.Point, b: CT.Point) bool {
    if (ptEq(p, a) or ptEq(p, b)) return false;
    const cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
    if (cross != 0) return false;
    const min_x = @min(a.x, b.x);
    const max_x = @max(a.x, b.x);
    const min_y = @min(a.y, b.y);
    const max_y = @max(a.y, b.y);
    return p.x > min_x and p.x < max_x or p.y > min_y and p.y < max_y;
}

fn wiresCollinear(wa: CT.Wire, wb: CT.Wire) bool {
    const dx_a = wa.end.x - wa.start.x;
    const dy_a = wa.end.y - wa.start.y;
    const dx_b = wb.end.x - wb.start.x;
    const dy_b = wb.end.y - wb.start.y;
    return dx_a * dy_b == dy_a * dx_b;
}
