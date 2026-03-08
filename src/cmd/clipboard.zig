//! Clipboard command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const cmd = @import("../command.zig");
const Command = cmd.Command;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .copy_selected => copyToClipboard(state),
        .clipboard_copy => copyToClipboard(state),
        .clipboard_cut => {
            copyToClipboard(state);
            try @import("edit.zig").handle(.delete_selected, state);
            state.setStatus("Cut to clipboard");
        },
        .clipboard_paste => {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            const sa = sch.alloc();
            const alloc = state.allocator();
            state.selection.clear();
            const offset: i32 = 20;
            for (state.clipboard.instances.items) |inst| {
                var copy = inst;
                copy.pos.x += offset;
                copy.pos.y += offset;
                copy.name = sa.dupe(u8, inst.name) catch inst.name;
                copy.symbol = sa.dupe(u8, inst.symbol) catch inst.symbol;
                copy.props = .{};
                sch.instances.append(sa, copy) catch continue;
                const idx = sch.instances.items.len - 1;
                state.selection.instances.resize(alloc, idx + 1, false) catch {};
                if (idx < state.selection.instances.bit_length) state.selection.instances.set(idx);
            }
            for (state.clipboard.wires.items) |wire| {
                var copy = wire;
                copy.start.x += offset;
                copy.start.y += offset;
                copy.end.x += offset;
                copy.end.y += offset;
                copy.net_name = if (wire.net_name) |n| sa.dupe(u8, n) catch n else null;
                sch.wires.append(sa, copy) catch continue;
                const idx = sch.wires.items.len - 1;
                state.selection.wires.resize(alloc, idx + 1, false) catch {};
                if (idx < state.selection.wires.bit_length) state.selection.wires.set(idx);
            }
            fio.dirty = true;
            state.setStatus("Pasted from clipboard");
        },
        else => unreachable,
    }
}

fn copyToClipboard(state: *AppState) void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();
    state.clipboard.clear(alloc);
    for (sch.instances.items, 0..) |inst, i| {
        if (i >= state.selection.instances.bit_length or !state.selection.instances.isSet(i)) continue;
        var copy = inst;
        copy.name = alloc.dupe(u8, inst.name) catch inst.name;
        copy.symbol = alloc.dupe(u8, inst.symbol) catch inst.symbol;
        copy.props = .{};
        state.clipboard.instances.append(alloc, copy) catch {};
    }
    for (sch.wires.items, 0..) |wire, i| {
        if (i >= state.selection.wires.bit_length or !state.selection.wires.isSet(i)) continue;
        var copy = wire;
        copy.net_name = if (wire.net_name) |n| alloc.dupe(u8, n) catch n else null;
        state.clipboard.wires.append(alloc, copy) catch {};
    }
    state.setStatus("Copied to clipboard");
}
