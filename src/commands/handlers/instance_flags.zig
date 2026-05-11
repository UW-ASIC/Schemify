//! Instance lock / hide / spice-ignore toggle handlers.

const std = @import("std");
const h = @import("helpers.zig");
const Immediate = h.Immediate;
const selInst = h.selInst;

pub fn handleLockHide(imm: Immediate, state: anytype) void {
    switch (imm) {
        .toggle_lock_selected => toggleInstanceFlag(state, "locked", "Lock"),
        .toggle_hide_selected => toggleInstanceFlag(state, "hidden", "Hide"),
        .toggle_spice_ignore => toggleInstanceFlag(state, "spice_ignore", "SPICE ignore"),
        else => {},
    }
}

fn toggleInstanceFlag(state: anytype, comptime field: []const u8, comptime label: []const u8) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const flags = sch.instances.items(.flags);
    var count: usize = 0;
    for (0..sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        @field(flags[i], field) = !@field(flags[i], field);
        count += 1;
    }
    if (count > 0) {
        fio.dirty = true;
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} toggled on {d} instance(s)", .{ label, count }) catch label ++ " toggled";
        state.setStatusBuf(msg);
    } else {
        state.setStatus("No instances selected");
    }
}
