const std = @import("std");
const types = @import("../types.zig");
const Immediate = types.Immediate;
const Undoable = types.Undoable;
const Point = types.Point;
const edit_mod = @import("Edit.zig");

pub const Error = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    Unexpected,
    Full,
};

inline fn selInst(fio: anytype, i: usize) bool {
    return i < fio.selection.instances.bit_length and fio.selection.instances.isSet(i);
}

inline fn selWire(fio: anytype, i: usize) bool {
    return i < fio.selection.wires.bit_length and fio.selection.wires.isSet(i);
}

pub fn handleClipboard(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .clipboard_copy => copyToClipboard(state),
        .clipboard_cut => {
            copyToClipboard(state);
            try edit_mod.handleEdit(.delete_selected, state);
            state.setStatus("Cut to clipboard");
        },
        .clipboard_paste => pasteFromClipboard(state),
        else => {},
    }
}

fn copyToClipboard(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const alloc = state.allocator();
    state.clipboard.clear();
    for (0..sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        var copy = sch.instances.get(i);
        copy.name = alloc.dupe(u8, copy.name) catch copy.name;
        copy.symbol = alloc.dupe(u8, copy.symbol) catch copy.symbol;
        copy.prop_start = 0;
        copy.prop_count = 0;
        state.clipboard.instances.append(alloc, copy) catch {};
    }
    for (0..sch.wires.len) |i| {
        if (!selWire(fio, i)) continue;
        var copy = sch.wires.get(i);
        copy.net_name = if (copy.net_name) |n| alloc.dupe(u8, n) catch n else null;
        state.clipboard.wires.append(alloc, copy) catch {};
    }
    state.setStatus("Copied to clipboard");
}

fn pasteFromClipboard(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const sa = fio.alloc;
    fio.selection.clear();
    const paste_off: Point = .{ 20, 20 };
    for (state.clipboard.instances.items) |inst| {
        var copy = inst;
        copy.x += paste_off[0];
        copy.y += paste_off[1];
        copy.name = sa.dupe(u8, inst.name) catch inst.name;
        copy.symbol = sa.dupe(u8, inst.symbol) catch inst.symbol;
        copy.prop_start = 0;
        copy.prop_count = 0;
        sch.instances.append(sa, copy) catch continue;
    }
    for (state.clipboard.wires.items) |w| {
        var copy = w;
        copy.x0 += paste_off[0];
        copy.y0 += paste_off[1];
        copy.x1 += paste_off[0];
        copy.y1 += paste_off[1];
        copy.net_name = if (w.net_name) |n| sa.dupe(u8, n) catch n else null;
        sch.wires.append(sa, copy) catch continue;
    }
    fio.dirty = true;
    state.setStatus("Pasted from clipboard");
}
