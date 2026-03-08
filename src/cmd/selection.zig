//! Selection command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const CT = state_mod.CT;
const cmd = @import("../command.zig");
const Command = cmd.Command;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .select_all => state.selectAll(),
        .select_none => state.selection.clear(),
        .select_connected => selectConnected(state, false),
        .select_connected_stop_junctions => selectConnected(state, true),
        .highlight_dup_refdes => highlightDupRefdes(state),
        .rename_dup_refdes => try renameDupRefdes(state),
        .find_select_dialog => {
            state.setStatus("Find: type query then Enter (stub)");
        },
        .highlight_selected_nets => highlightSelectedNets(state),
        .unhighlight_selected_nets => unhighlightSelectedNets(state),
        .unhighlight_all => state.highlighted_nets.unsetAll(),
        .select_attached_nets => selectAttachedNets(state),
        else => unreachable,
    }
}

fn ptEq(a: CT.Point, b: CT.Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn selectConnected(state: *AppState, stop_at_junctions: bool) void {
    _ = stop_at_junctions;
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var added = false;
        for (sch.wires.items, 0..) |wa, a| {
            const a_sel = a < state.selection.wires.bit_length and state.selection.wires.isSet(a);
            if (!a_sel) continue;
            for (sch.wires.items, 0..) |wb, b| {
                if (a == b) continue;
                const b_sel = b < state.selection.wires.bit_length and state.selection.wires.isSet(b);
                if (b_sel) continue;
                const shares = ptEq(wa.start, wb.start) or ptEq(wa.start, wb.end) or
                    ptEq(wa.end, wb.start) or ptEq(wa.end, wb.end);
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

fn selectAttachedNets(state: *AppState) void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();
    for (sch.instances.items, 0..) |inst, ii| {
        if (ii >= state.selection.instances.bit_length or !state.selection.instances.isSet(ii)) continue;
        for (sch.wires.items, 0..) |wire, wi| {
            const touches = ptEq(wire.start, inst.pos) or ptEq(wire.end, inst.pos);
            if (touches) {
                state.selection.wires.resize(alloc, wi + 1, false) catch continue;
                state.selection.wires.set(wi);
            }
        }
    }
    state.setStatus("Attached nets selected");
}

fn highlightSelectedNets(state: *AppState) void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();
    state.highlighted_nets.resize(alloc, sch.wires.items.len, false) catch return;
    for (sch.wires.items, 0..) |_, wi| {
        if (wi < state.selection.wires.bit_length and state.selection.wires.isSet(wi)) {
            state.highlighted_nets.set(wi);
        }
    }
    state.setStatus("Nets highlighted");
}

fn unhighlightSelectedNets(state: *AppState) void {
    for (0..@min(state.selection.wires.bit_length, state.highlighted_nets.bit_length)) |wi| {
        if (state.selection.wires.isSet(wi)) {
            state.highlighted_nets.unset(wi);
        }
    }
    state.setStatus("Nets unhighlighted");
}

fn highlightDupRefdes(state: *AppState) void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();
    var map = std.StringHashMap(usize).init(alloc);
    defer map.deinit();
    for (sch.instances.items) |inst| {
        const entry = map.getOrPutValue(inst.name, 0) catch continue;
        entry.value_ptr.* += 1;
    }
    state.selection.clear();
    for (sch.instances.items, 0..) |inst, i| {
        const count = map.get(inst.name) orelse 0;
        if (count > 1) {
            state.selection.instances.resize(alloc, i + 1, false) catch continue;
            state.selection.instances.set(i);
        }
    }
    state.setStatus("Duplicate refdes highlighted");
}

fn renameDupRefdes(state: *AppState) !void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();
    var map = std.StringHashMap(u32).init(alloc);
    defer map.deinit();
    for (sch.instances.items, 0..) |inst, i| {
        const res = try map.getOrPut(inst.name);
        if (res.found_existing) {
            res.value_ptr.* += 1;
            const suffix = res.value_ptr.*;
            var new_name_buf: [128]u8 = undefined;
            const new_name = std.fmt.bufPrint(&new_name_buf, "{s}_{d}", .{ inst.name, suffix }) catch continue;
            try fio.setProp(i, "name", new_name);
        } else {
            res.value_ptr.* = 1;
        }
    }
    state.setStatus("Duplicate refdes renamed");
}
