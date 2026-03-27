//! Clipboard command handlers.

const st = @import("state");
const Point = st.Point;
const Immediate = @import("command.zig").Immediate;
const edit      = @import("Edit.zig");

pub const Error = edit.Error;

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .copy_selected, .clipboard_copy => copyToClipboard(state),
        .clipboard_cut => {
            copyToClipboard(state);
            try edit.handleUndoable(.delete_selected, state);
            state.setStatus("Cut to clipboard");
        },
        .clipboard_paste => pasteFromClipboard(state),
        else => unreachable,
    }
}

// ── Private helpers ──────────────────────────────────────────────────────────

const paste_off: Point = .{ 20, 20 };

inline fn selInst(state: anytype, i: usize) bool {
    return i < state.selection.instances.bit_length and state.selection.instances.isSet(i);
}
inline fn selWire(state: anytype, i: usize) bool {
    return i < state.selection.wires.bit_length and state.selection.wires.isSet(i);
}

fn pasteFromClipboard(state: anytype) void {
    const fio   = state.active() orelse return;
    const sch   = &fio.sch;
    const sa    = sch.alloc();
    const alloc = state.allocator();
    state.selection.clear();

    for (state.clipboard.instances.items) |inst| {
        var copy    = inst;
        copy.x     += paste_off[0];
        copy.y     += paste_off[1];
        copy.name   = sa.dupe(u8, inst.name)   catch inst.name;
        copy.symbol = sa.dupe(u8, inst.symbol) catch inst.symbol;
        copy.prop_start = 0;
        copy.prop_count = 0;
        sch.instances.append(sa, copy) catch continue;
        const idx = sch.instances.len - 1;
        state.selection.instances.resize(alloc, idx + 1, false) catch {};
        if (idx < state.selection.instances.bit_length) state.selection.instances.set(idx);
    }

    for (state.clipboard.wires.items) |w| {
        var copy    = w;
        copy.x0    += paste_off[0];
        copy.y0    += paste_off[1];
        copy.x1    += paste_off[0];
        copy.y1    += paste_off[1];
        copy.net_name = if (w.net_name) |n| sa.dupe(u8, n) catch n else null;
        sch.wires.append(sa, copy) catch continue;
        const idx = sch.wires.len - 1;
        state.selection.wires.resize(alloc, idx + 1, false) catch {};
        if (idx < state.selection.wires.bit_length) state.selection.wires.set(idx);
    }

    fio.dirty = true;
    state.setStatus("Pasted from clipboard");
}

fn copyToClipboard(state: anytype) void {
    const fio   = state.active() orelse return;
    const sch   = &fio.sch;
    const alloc = state.allocator();
    state.clipboard.clear();

    for (0..sch.instances.len) |i| {
        if (!selInst(state, i)) continue;
        var copy    = sch.instances.get(i);
        copy.name   = alloc.dupe(u8, copy.name)   catch copy.name;
        copy.symbol = alloc.dupe(u8, copy.symbol) catch copy.symbol;
        copy.prop_start = 0;
        copy.prop_count = 0;
        state.clipboard.instances.append(alloc, copy) catch {};
    }

    for (0..sch.wires.len) |i| {
        if (!selWire(state, i)) continue;
        var copy      = sch.wires.get(i);
        copy.net_name = if (copy.net_name) |n| alloc.dupe(u8, n) catch n else null;
        state.clipboard.wires.append(alloc, copy) catch {};
    }

    state.setStatus("Copied to clipboard");
}
