//! Wire placement command handlers.

const core = @import("core");
const CT = core.CT;
const Immediate = @import("command.zig").Immediate;

pub const Error = error{OutOfMemory};

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .start_wire => {
            state.tool.active     = .wire;
            state.tool.wire_start = null;
            state.setStatus("Wire mode — click to start");
        },
        .start_wire_snap => {
            state.tool.active     = .wire;
            state.tool.wire_start = null;
            state.setStatus("Wire mode (snap) — click to start");
        },
        .cancel_wire => {
            state.tool.wire_start = null;
            state.tool.active     = .select;
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

        .break_wires_at_connections => {
            const fio   = state.active() orelse return;
            const sch   = fio.schematic();
            const alloc = sch.alloc();
            var i: usize = 0;
            while (i < sch.wires.items.len) {
                const w        = sch.wires.items[i];
                var split_pt: ?CT.Point = null;
                outer: for (sch.wires.items, 0..) |other, j| {
                    if (i == j) continue;
                    for ([_]CT.Point{ other.start, other.end }) |p| {
                        if (ptEq(p, w.start) or ptEq(p, w.end)) continue;
                        // p must be collinear with w (cross product = 0) …
                        const d  = w.end - w.start;
                        const wv = p - w.start;
                        if (d[0] * wv[1] != d[1] * wv[0]) continue;
                        // … and strictly interior (not at an endpoint).
                        if (isInterior(p[0], w.start[0], w.end[0]) or
                            isInterior(p[1], w.start[1], w.end[1]))
                        {
                            split_pt = p;
                            break :outer;
                        }
                    }
                }
                if (split_pt) |sp| {
                    _ = sch.wires.orderedRemove(i);
                    try sch.wires.insert(alloc, i,     .{ .start = w.start, .end = sp,    .net_name = w.net_name });
                    try sch.wires.insert(alloc, i + 1, .{ .start = sp,      .end = w.end, .net_name = w.net_name });
                    i += 2;
                } else i += 1;
            }
            fio.dirty = true;
            state.setStatus("Wires broken at connections");
        },

        .join_collapse_wires => {
            const fio   = state.active() orelse return;
            const sch   = fio.schematic();
            const alloc = sch.alloc();
            var i: usize = 0;
            while (i < sch.wires.items.len) {
                const wa   = sch.wires.items[i];
                const da   = wa.end - wa.start;
                var merged = false;
                var j: usize = i + 1;
                while (j < sch.wires.items.len) {
                    const wb = sch.wires.items[j];
                    const db = wb.end - wb.start;
                    // Parallel direction vectors ↔ cross product = 0.
                    if (da[0] * db[1] == da[1] * db[0]) {
                        const mw: ?CT.Wire =
                            if      (ptEq(wa.end,   wb.start)) .{ .start = wa.start, .end = wb.end,   .net_name = wa.net_name }
                            else if (ptEq(wa.start, wb.end  )) .{ .start = wb.start, .end = wa.end,   .net_name = wa.net_name }
                            else if (ptEq(wa.start, wb.start)) .{ .start = wa.end,   .end = wb.end,   .net_name = wa.net_name }
                            else if (ptEq(wa.end,   wb.end  )) .{ .start = wa.start, .end = wb.start, .net_name = wa.net_name }
                            else null;
                        if (mw) |m| {
                            _ = sch.wires.orderedRemove(j);
                            _ = sch.wires.orderedRemove(i);
                            try sch.wires.insert(alloc, i, m);
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
        },

        .start_line    => { state.tool.active = .line;    state.setStatus("Line draw mode (stub)"); },
        .start_rect    => { state.tool.active = .rect;    state.setStatus("Rect draw mode (stub)"); },
        .start_polygon => { state.tool.active = .polygon; state.setStatus("Polygon draw mode (stub)"); },
        .start_arc     => { state.tool.active = .arc;     state.setStatus("Arc draw mode (stub)"); },
        .start_circle  => { state.tool.active = .circle;  state.setStatus("Circle draw mode (stub)"); },
        else => unreachable,
    }
}

// ── Private helpers ──────────────────────────────────────────────────────────

/// Point equality via SIMD reduce.
inline fn ptEq(a: CT.Point, b: CT.Point) bool { return @reduce(.And, a == b); }

/// Returns true when `v` lies strictly between `a` and `b` (exclusive).
inline fn isInterior(v: i32, a: i32, b: i32) bool {
    return v > @min(a, b) and v < @max(a, b);
}
