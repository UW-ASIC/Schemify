//! Undo/redo command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const CT = state_mod.CT;
const cmd = @import("../command.zig");
const Command = cmd.Command;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .undo => {
            const inv = state.history.popUndo() orelse {
                state.setStatus("Nothing to undo");
                return;
            };
            switch (inv) {
                .none => {},
                .place_device => |pd| {
                    const fio = state.active() orelse return;
                    _ = fio.deleteInstanceAt(pd.idx);
                },
                .delete_device => |dd| {
                    const fio = state.active() orelse return;
                    _ = try fio.placeSymbol(dd.sym_path, dd.name, pointFromF64(dd.x, dd.y), .{});
                },
                .move_device => |md| {
                    const fio = state.active() orelse return;
                    _ = fio.moveInstanceBy(
                        md.idx,
                        @as(i32, @intFromFloat(@round(md.dx))),
                        @as(i32, @intFromFloat(@round(md.dy))),
                    );
                },
                .set_prop => |sp| {
                    const fio = state.active() orelse return;
                    try fio.setProp(sp.idx, sp.key, sp.val);
                },
                .add_wire => |aw| {
                    const fio = state.active() orelse return;
                    _ = fio.deleteWireAt(aw.idx);
                },
                .delete_wire => |dw| {
                    const fio = state.active() orelse return;
                    try fio.addWireSeg(pointFromF64(dw.x0, dw.y0), pointFromF64(dw.x1, dw.y1), null);
                },
                .delete_selected => |snap| {
                    const fio = state.active() orelse return;
                    const sch = fio.schematic();
                    for (snap.instances) |inst| sch.instances.append(sch.alloc(), inst) catch {};
                    for (snap.wires)     |wire| sch.wires.append(sch.alloc(), wire)     catch {};
                    fio.dirty = true;
                    state.setStatus("Undo: restored deleted objects");
                },
                .duplicate_selected => |d| {
                    const fio = state.active() orelse return;
                    const sch = fio.schematic();
                    const n = @min(d.n, sch.instances.items.len);
                    sch.instances.items.len -= n;
                    fio.dirty = true;
                    state.setStatus("Undo: removed duplicated objects");
                },
            }
            return;
        },
        .redo => {
            state.setStatus("Redo not yet implemented");
            return;
        },
        else => unreachable,
    }
}

fn pointFromF64(x: f64, y: f64) CT.Point {
    return .{
        .x = @as(i32, @intFromFloat(@round(x))),
        .y = @as(i32, @intFromFloat(@round(y))),
    };
}
