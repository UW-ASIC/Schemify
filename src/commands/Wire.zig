//! Wire placement command handlers.

const st = @import("state");
const Point = st.Point;
const Wire = st.Wire;
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
        .finish_wire => state.setStatus("Wire finished"),

        .toggle_wire_routing => {
            state.cmd_flags.wire_routing = !state.cmd_flags.wire_routing;
            state.setStatus(if (state.cmd_flags.wire_routing) "Wire routing on" else "Wire routing off");
        },
        .toggle_orthogonal_routing => {
            state.cmd_flags.orthogonal_routing = !state.cmd_flags.orthogonal_routing;
            state.setStatus(if (state.cmd_flags.orthogonal_routing) "Orthogonal routing on" else "Orthogonal routing off");
        },

        .break_wires_at_connections => {
            const fio   = state.active() orelse return;
            const sch   = &fio.sch;
            const alloc = sch.alloc();
            var i: usize = 0;
            while (i < sch.wires.len) {
                const w = sch.wires.get(i);
                const w_s: Point = .{ w.x0, w.y0 };
                const w_e: Point = .{ w.x1, w.y1 };
                var split_pt: ?Point = null;
                outer: for (0..sch.wires.len) |j| {
                    if (i == j) continue;
                    const other = sch.wires.get(j);
                    for ([_]Point{ .{ other.x0, other.y0 }, .{ other.x1, other.y1 } }) |p| {
                        if (ptEq(p, w_s) or ptEq(p, w_e)) continue;
                        // p must be collinear with w (cross product = 0) …
                        const d: Point  = .{ w_e[0] - w_s[0], w_e[1] - w_s[1] };
                        const wv: Point = .{ p[0] - w_s[0], p[1] - w_s[1] };
                        if (d[0] * wv[1] != d[1] * wv[0]) continue;
                        // … and strictly interior (not at an endpoint).
                        if (isInterior(p[0], w_s[0], w_e[0]) or
                            isInterior(p[1], w_s[1], w_e[1]))
                        {
                            split_pt = p;
                            break :outer;
                        }
                    }
                }
                if (split_pt) |sp| {
                    sch.wires.orderedRemove(i);
                    try sch.wires.insert(alloc, i,     .{ .x0 = w.x0, .y0 = w.y0, .x1 = sp[0], .y1 = sp[1], .net_name = w.net_name });
                    try sch.wires.insert(alloc, i + 1, .{ .x0 = sp[0], .y0 = sp[1], .x1 = w.x1, .y1 = w.y1, .net_name = w.net_name });
                    i += 2;
                } else i += 1;
            }
            fio.dirty = true;
            state.setStatus("Wires broken at connections");
        },

        .join_collapse_wires => {
            const fio   = state.active() orelse return;
            const sch   = &fio.sch;
            const alloc = sch.alloc();
            var i: usize = 0;
            while (i < sch.wires.len) {
                const wa = sch.wires.get(i);
                const wa_s: Point = .{ wa.x0, wa.y0 };
                const wa_e: Point = .{ wa.x1, wa.y1 };
                const da: Point   = .{ wa_e[0] - wa_s[0], wa_e[1] - wa_s[1] };
                var merged = false;
                var j: usize = i + 1;
                while (j < sch.wires.len) {
                    const wb = sch.wires.get(j);
                    const wb_s: Point = .{ wb.x0, wb.y0 };
                    const wb_e: Point = .{ wb.x1, wb.y1 };
                    const db: Point   = .{ wb_e[0] - wb_s[0], wb_e[1] - wb_s[1] };
                    // Parallel direction vectors ↔ cross product = 0.
                    if (da[0] * db[1] == da[1] * db[0]) {
                        const mw: ?Wire =
                            if      (ptEq(wa_e, wb_s)) .{ .x0 = wa.x0, .y0 = wa.y0, .x1 = wb.x1, .y1 = wb.y1, .net_name = wa.net_name }
                            else if (ptEq(wa_s, wb_e)) .{ .x0 = wb.x0, .y0 = wb.y0, .x1 = wa.x1, .y1 = wa.y1, .net_name = wa.net_name }
                            else if (ptEq(wa_s, wb_s)) .{ .x0 = wa.x1, .y0 = wa.y1, .x1 = wb.x1, .y1 = wb.y1, .net_name = wa.net_name }
                            else if (ptEq(wa_e, wb_e)) .{ .x0 = wa.x0, .y0 = wa.y0, .x1 = wb.x0, .y1 = wb.y0, .net_name = wa.net_name }
                            else null;
                        if (mw) |m| {
                            sch.wires.orderedRemove(j);
                            sch.wires.orderedRemove(i);
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

        .start_line    => { state.tool.active = .line;    state.setStatus("Line draw mode"); },
        .start_rect    => { state.tool.active = .rect;    state.setStatus("Rect draw mode"); },
        .start_polygon => { state.tool.active = .polygon; state.setStatus("Polygon draw mode"); },
        .start_arc     => { state.tool.active = .arc;     state.setStatus("Arc draw mode"); },
        .start_circle  => { state.tool.active = .circle;  state.setStatus("Circle draw mode"); },
        else => unreachable,
    }
}

// ── Private helpers ──────────────────────────────────────────────────────────

/// Point equality via SIMD reduce.
inline fn ptEq(a: Point, b: Point) bool { return a[0] == b[0] and a[1] == b[1]; }

/// Returns true when `v` lies strictly between `a` and `b` (exclusive).
inline fn isInterior(v: i32, a: i32, b: i32) bool {
    return v > @min(a, b) and v < @max(a, b);
}
