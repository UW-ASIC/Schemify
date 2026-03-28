//! Selection command handlers.

const std = @import("std");
const st = @import("state");
const Point = st.Point;
const Immediate = @import("command.zig").Immediate;
const h = @import("helpers.zig");
const selInst = h.selInst;
const selWire = h.selWire;
const ptEq = h.ptEq;
const setBit = h.setBit;

pub const Error = error{OutOfMemory};

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .select_all => state.selectAll(),
        .select_none => state.selection.clear(),
        .select_connected => selectConnected(state, false),
        .select_connected_stop_junctions => selectConnected(state, true),
        .highlight_dup_refdes => highlightDupRefdes(state),
        .rename_dup_refdes => try renameDupRefdes(state),
        .find_select_dialog => {
            // TODO: open FindDialog GUI component that lets the user type a
            // query string, then selects matching instances/nets.
            state.setStatus("Find: type query then Enter");
        },

        // highlighted_nets |= selection.wires
        .highlight_selected_nets => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const alloc = state.allocator();
            try state.highlighted_nets.resize(alloc, sch.wires.len, false);
            // Grow selection bitset to match so setUnion is legal.
            try state.selection.wires.resize(alloc, sch.wires.len, false);
            state.highlighted_nets.setUnion(state.selection.wires);
            state.setStatus("Nets highlighted");
        },

        // highlighted_nets &= ~selection.wires  (remove selected from highlight)
        .unhighlight_selected_nets => {
            // Iterate only the *set* bits of the selection; unset each in highlighted_nets.
            // This avoids touching the full word range for sparse selections.
            var it = state.selection.wires.iterator(.{});
            while (it.next()) |wi| {
                if (wi < state.highlighted_nets.bit_length) state.highlighted_nets.unset(wi);
            }
            state.setStatus("Nets unhighlighted");
        },

        .unhighlight_all => state.highlighted_nets.unsetAll(),

        .select_attached_nets => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const alloc = state.allocator();
            for (0..sch.instances.len) |ii| {
                if (!selInst(state, ii)) continue;
                const inst = sch.instances.get(ii);
                const ip: Point = .{ inst.x, inst.y };
                for (0..sch.wires.len) |wi| {
                    const w = sch.wires.get(wi);
                    const ws: Point = .{ w.x0, w.y0 };
                    const we: Point = .{ w.x1, w.y1 };
                    if (ptEq(ws, ip) or ptEq(we, ip)) {
                        setBit(&state.selection.wires, alloc, wi) catch continue;
                    }
                }
            }
            state.setStatus("Attached nets selected");
        },
        else => unreachable,
    }
}

// ── Private helpers ──────────────────────────────────────────────────────────

fn selectConnected(state: anytype, stop_at_junctions: bool) void {
    // TODO: honour stop_at_junctions — stop BFS expansion at T/cross junctions
    // (nodes where 3+ wires meet). Requires junction detection from core.
    _ = stop_at_junctions;
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const alloc = state.allocator();
    // BFS: up to 8 expansion rounds; bail early when nothing new was added.
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        var added = false;
        for (0..sch.wires.len) |a| {
            if (!selWire(state, a)) continue;
            const wa = sch.wires.get(a);
            const wa_s: Point = .{ wa.x0, wa.y0 };
            const wa_e: Point = .{ wa.x1, wa.y1 };
            for (0..sch.wires.len) |b| {
                if (a == b or selWire(state, b)) continue;
                const wb = sch.wires.get(b);
                const wb_s: Point = .{ wb.x0, wb.y0 };
                const wb_e: Point = .{ wb.x1, wb.y1 };
                const shares = ptEq(wa_s, wb_s) or ptEq(wa_s, wb_e) or
                    ptEq(wa_e, wb_s) or ptEq(wa_e, wb_e);
                if (shares) {
                    setBit(&state.selection.wires, alloc, b) catch continue;
                    added = true;
                }
            }
        }
        if (!added) break;
    }
    state.setStatus("Select connected done");
}

fn highlightDupRefdes(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const alloc = state.allocator();
    var map = std.StringHashMap(usize).init(alloc);
    defer map.deinit();
    for (0..sch.instances.len) |i| {
        const inst = sch.instances.get(i);
        (map.getOrPutValue(inst.name, 0) catch continue).value_ptr.* += 1;
    }
    state.selection.clear();
    for (0..sch.instances.len) |i| {
        const inst = sch.instances.get(i);
        if ((map.get(inst.name) orelse 0) > 1) {
            setBit(&state.selection.instances, alloc, i) catch continue;
        }
    }
    state.setStatus("Duplicate refdes highlighted");
}

fn renameDupRefdes(state: anytype) Error!void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const alloc = state.allocator();
    var map = std.StringHashMap(u32).init(alloc);
    defer map.deinit();
    for (0..sch.instances.len) |i| {
        const inst = sch.instances.get(i);
        const res = try map.getOrPut(inst.name);
        if (res.found_existing) {
            res.value_ptr.* += 1;
            var buf: [128]u8 = undefined;
            const new_name = std.fmt.bufPrint(&buf, "{s}_{d}", .{ inst.name, res.value_ptr.* }) catch continue;
            try fio.setProp(i, "name", new_name);
        } else {
            res.value_ptr.* = 1;
        }
    }
    state.setStatus("Duplicate refdes renamed");
}
