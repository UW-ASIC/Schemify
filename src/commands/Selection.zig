//! Selection command handlers.

const std = @import("std");
const core = @import("core");
const CT = core.CT;
const Immediate = @import("command.zig").Immediate;

pub const Error = error{OutOfMemory};

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .select_all                      => state.selectAll(),
        .select_none                     => state.selection.clear(),
        .select_connected                => selectConnected(state, false),
        .select_connected_stop_junctions => selectConnected(state, true),
        .highlight_dup_refdes            => highlightDupRefdes(state),
        .rename_dup_refdes               => try renameDupRefdes(state),
        .find_select_dialog              => state.setStatus("Find: type query then Enter (stub)"),

        // highlighted_nets |= selection.wires
        .highlight_selected_nets => {
            const fio   = state.active() orelse return;
            const sch   = fio.schematic();
            const alloc = state.allocator();
            try state.highlighted_nets.resize(alloc, sch.wires.items.len, false);
            // Grow selection bitset to match so setUnion is legal.
            try state.selection.wires.resize(alloc, sch.wires.items.len, false);
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

        .unhighlight_all      => state.highlighted_nets.unsetAll(),

        .select_attached_nets => {
            const fio   = state.active() orelse return;
            const sch   = fio.schematic();
            const alloc = state.allocator();
            for (sch.instances.items, 0..) |inst, ii| {
                if (!selInst(state, ii)) continue;
                for (sch.wires.items, 0..) |w, wi| {
                    if (ptEq(w.start, inst.pos) or ptEq(w.end, inst.pos)) {
                        state.selection.wires.resize(alloc, wi + 1, false) catch continue;
                        state.selection.wires.set(wi);
                    }
                }
            }
            state.setStatus("Attached nets selected");
        },
        else => unreachable,
    }
}

// ── Private helpers ──────────────────────────────────────────────────────────

inline fn ptEq(a: CT.Point, b: CT.Point) bool { return @reduce(.And, a == b); }

inline fn selInst(state: anytype, i: usize) bool {
    return i < state.selection.instances.bit_length and state.selection.instances.isSet(i);
}
inline fn selWire(state: anytype, i: usize) bool {
    return i < state.selection.wires.bit_length and state.selection.wires.isSet(i);
}

fn selectConnected(state: anytype, stop_at_junctions: bool) void {
    _ = stop_at_junctions;
    const fio   = state.active() orelse return;
    const sch   = fio.schematic();
    const alloc = state.allocator();
    // BFS: up to 8 expansion rounds; bail early when nothing new was added.
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        var added = false;
        for (sch.wires.items, 0..) |wa, a| {
            if (!selWire(state, a)) continue;
            for (sch.wires.items, 0..) |wb, b| {
                if (a == b or selWire(state, b)) continue;
                const shares = ptEq(wa.start, wb.start) or ptEq(wa.start, wb.end) or
                               ptEq(wa.end,   wb.start) or ptEq(wa.end,   wb.end);
                if (shares) {
                    state.selection.wires.resize(alloc, b + 1, false) catch continue;
                    state.selection.wires.set(b);
                    added = true;
                }
            }
        }
        if (!added) break;
    }
    state.setStatus("Select connected done");
}

fn highlightDupRefdes(state: anytype) void {
    const fio   = state.active() orelse return;
    const sch   = fio.schematic();
    const alloc = state.allocator();
    var map = std.StringHashMap(usize).init(alloc);
    defer map.deinit();
    for (sch.instances.items) |inst|
        (map.getOrPutValue(inst.name, 0) catch continue).value_ptr.* += 1;
    state.selection.clear();
    for (sch.instances.items, 0..) |inst, i| {
        if ((map.get(inst.name) orelse 0) > 1) {
            state.selection.instances.resize(alloc, i + 1, false) catch continue;
            state.selection.instances.set(i);
        }
    }
    state.setStatus("Duplicate refdes highlighted");
}

fn renameDupRefdes(state: anytype) Error!void {
    const fio   = state.active() orelse return;
    const sch   = fio.schematic();
    const alloc = state.allocator();
    var map = std.StringHashMap(u32).init(alloc);
    defer map.deinit();
    for (sch.instances.items, 0..) |inst, i| {
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
