//! Selection command handlers.

const std = @import("std");
const types = @import("../types.zig");
const Immediate = types.Immediate;
const Point = types.Point;

inline fn selInst(fio: anytype, i: usize) bool {
    return i < fio.selection.instances.bit_length and fio.selection.instances.isSet(i);
}

inline fn selWire(fio: anytype, i: usize) bool {
    return i < fio.selection.wires.bit_length and fio.selection.wires.isSet(i);
}

inline fn ptEq(a: Point, b: Point) bool {
    return a[0] == b[0] and a[1] == b[1];
}

pub fn handleSelection(imm: Immediate, state: anytype) void {
    switch (imm) {
        .select_all => state.selectAll(),
        .select_none => { if (state.active()) |fio| fio.selection.clear(); },
        .invert_selection => {
            const fio = state.active() orelse return;
            const a = state.allocator();
            fio.selection.ensureCapacity(a, fio.sch.instances.len, fio.sch.wires.len, false) catch return;
            fio.selection.instances.toggleAll();
            fio.selection.wires.toggleAll();
            state.setStatus("Selection inverted");
        },
        .find_select_dialog => state.setStatus("Find: type query then Enter"),
        .highlight_selected_nets => {
            const fio = state.active() orelse return;
            const alloc = state.allocator();
            state.highlighted_nets.resize(alloc, fio.sch.wires.len, false) catch return;
            fio.selection.wires.resize(alloc, fio.sch.wires.len, false) catch return;
            state.highlighted_nets.setUnion(fio.selection.wires);
            state.setStatus("Nets highlighted");
        },
        .unhighlight_all => {
            state.highlighted_nets.unsetAll();
            state.setStatus("All highlights cleared");
        },
        .select_attached_nets => selectAttachedNets(state),
        else => {},
    }
}

fn selectAttachedNets(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    if (sch.instances.len == 0 or sch.wires.len == 0) return;
    const alloc = state.allocator();
    fio.selection.ensureCapacity(alloc, sch.instances.len, sch.wires.len, false) catch return;

    const ix = sch.instances.items(.x);
    const iy = sch.instances.items(.y);
    const iflags = sch.instances.items(.flags);
    const wx0 = sch.wires.items(.x0);
    const wy0 = sch.wires.items(.y0);
    const wx1 = sch.wires.items(.x1);
    const wy1 = sch.wires.items(.y1);

    var count: usize = 0;
    for (0..sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        if (i >= sch.sym_data.items.len) continue;
        const sd = sch.sym_data.items[i];
        for (sd.pins) |pin| {
            const rot = iflags[i].rot;
            const flip = iflags[i].flip;
            const fpx: i32 = if (flip) -pin.x else pin.x;
            const abs_x = ix[i] + switch (rot) {
                0 => fpx, 1 => -pin.y, 2 => -fpx, 3 => pin.y,
            };
            const abs_y = iy[i] + switch (rot) {
                0 => pin.y, 1 => fpx, 2 => -pin.y, 3 => -fpx,
            };
            for (0..sch.wires.len) |wi| {
                if ((abs_x == wx0[wi] and abs_y == wy0[wi]) or
                    (abs_x == wx1[wi] and abs_y == wy1[wi]))
                {
                    fio.selection.wires.set(wi);
                    count += 1;
                }
            }
        }
    }
    if (count > 0) {
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Selected {d} attached net(s)", .{count}) catch "Nets selected";
        state.setStatusBuf(msg);
    } else {
        state.setStatus("No attached nets found");
    }
}
