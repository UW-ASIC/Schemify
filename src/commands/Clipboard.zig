//! Clipboard command handlers.

const CT       = @import("core").CT;
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

const paste_off: CT.Point = .{ 20, 20 };

inline fn selInst(state: anytype, i: usize) bool {
    return i < state.selection.instances.bit_length and state.selection.instances.isSet(i);
}
inline fn selWire(state: anytype, i: usize) bool {
    return i < state.selection.wires.bit_length and state.selection.wires.isSet(i);
}

fn pasteFromClipboard(state: anytype) void {
    const fio   = state.active() orelse return;
    const sch   = fio.schematic();
    const sa    = sch.alloc();
    const alloc = state.allocator();
    state.selection.clear();

    for (state.clipboard.instances.items) |inst| {
        var copy    = inst;
        copy.pos    = copy.pos + paste_off;
        copy.name   = sa.dupe(u8, inst.name)   catch inst.name;
        copy.symbol = sa.dupe(u8, inst.symbol) catch inst.symbol;
        copy.props  = .{};
        sch.instances.append(sa, copy) catch continue;
        const idx = sch.instances.items.len - 1;
        state.selection.instances.resize(alloc, idx + 1, false) catch {};
        if (idx < state.selection.instances.bit_length) state.selection.instances.set(idx);
    }

    for (state.clipboard.wires.items) |w| {
        var copy      = w;
        copy.start    = copy.start + paste_off;
        copy.end      = copy.end   + paste_off;
        copy.net_name = if (w.net_name) |n| sa.dupe(u8, n) catch n else null;
        sch.wires.append(sa, copy) catch continue;
        const idx = sch.wires.items.len - 1;
        state.selection.wires.resize(alloc, idx + 1, false) catch {};
        if (idx < state.selection.wires.bit_length) state.selection.wires.set(idx);
    }

    fio.dirty = true;
    state.setStatus("Pasted from clipboard");
}

fn copyToClipboard(state: anytype) void {
    const fio   = state.active() orelse return;
    const sch   = fio.schematic();
    const alloc = state.allocator();
    state.clipboard.clear();

    for (sch.instances.items, 0..) |inst, i| {
        if (!selInst(state, i)) continue;
        var copy    = inst;
        copy.name   = alloc.dupe(u8, inst.name)   catch inst.name;
        copy.symbol = alloc.dupe(u8, inst.symbol) catch inst.symbol;
        copy.props  = .{};
        state.clipboard.instances.append(alloc, copy) catch {};
    }

    for (sch.wires.items, 0..) |w, i| {
        if (!selWire(state, i)) continue;
        var copy      = w;
        copy.net_name = if (w.net_name) |n| alloc.dupe(u8, n) catch n else null;
        state.clipboard.wires.append(alloc, copy) catch {};
    }

    state.setStatus("Copied to clipboard");
}
