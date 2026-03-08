//! Edit command handlers (transforms, delete, nudge, align, payloads).

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const CT = state_mod.CT;
const cmd = @import("../command.zig");
const Command = cmd.Command;
const CommandInverse = cmd.CommandInverse;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .delete_selected => {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            const snap_alloc = state.allocator();

            // Snapshot for undo
            var sel_inst_count: usize = 0;
            for (0..sch.instances.items.len) |i| {
                if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i))
                    sel_inst_count += 1;
            }
            var sel_wire_count: usize = 0;
            for (0..sch.wires.items.len) |i| {
                if (i < state.selection.wires.bit_length and state.selection.wires.isSet(i))
                    sel_wire_count += 1;
            }
            const snap_inst: []CT.Instance = snap_alloc.alloc(CT.Instance, sel_inst_count) catch
                snap_alloc.alloc(CT.Instance, 0) catch unreachable;
            const snap_wire: []CT.Wire = snap_alloc.alloc(CT.Wire, sel_wire_count) catch
                snap_alloc.alloc(CT.Wire, 0) catch unreachable;
            var si: usize = 0;
            for (sch.instances.items, 0..) |inst, i| {
                if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i)) {
                    if (si < snap_inst.len) { snap_inst[si] = inst; si += 1; }
                }
            }
            var sw: usize = 0;
            for (sch.wires.items, 0..) |wire, i| {
                if (i < state.selection.wires.bit_length and state.selection.wires.isSet(i)) {
                    if (sw < snap_wire.len) { snap_wire[sw] = wire; sw += 1; }
                }
            }

            var wi = sch.wires.items.len;
            while (wi > 0) {
                wi -= 1;
                if (wi < state.selection.wires.bit_length and state.selection.wires.isSet(wi)) {
                    _ = sch.wires.orderedRemove(wi);
                }
            }

            var ii = sch.instances.items.len;
            while (ii > 0) {
                ii -= 1;
                if (ii < state.selection.instances.bit_length and state.selection.instances.isSet(ii)) {
                    _ = sch.instances.orderedRemove(ii);
                }
            }

            state.selection.clear();
            fio.dirty = true;
            state.history.push(c, .{ .delete_selected = .{ .instances = snap_inst, .wires = snap_wire } });
            return;
        },
        .duplicate_selected => {
            const fio = state.active() orelse return;
            const before_len = fio.schematic().instances.items.len;
            duplicateSelected(fio, state);
            const after_len = fio.schematic().instances.items.len;
            state.history.push(c, .{ .duplicate_selected = .{ .n = after_len - before_len } });
            return;
        },
        .rotate_cw => {
            const fio = state.active() orelse return;
            rotateSelected(fio, state, 1);
        },
        .rotate_ccw => {
            const fio = state.active() orelse return;
            rotateSelected(fio, state, 3);
        },
        .flip_horizontal => {
            const fio = state.active() orelse return;
            flipSelected(fio, state);
        },
        .flip_vertical => {
            const fio = state.active() orelse return;
            flipSelected(fio, state);
            rotateSelected(fio, state, 2);
        },
        .nudge_left => {
            const fio = state.active() orelse return;
            nudgeSelected(fio, state, -10, 0);
        },
        .nudge_right => {
            const fio = state.active() orelse return;
            nudgeSelected(fio, state, 10, 0);
        },
        .nudge_up => {
            const fio = state.active() orelse return;
            nudgeSelected(fio, state, 0, -10);
        },
        .nudge_down => {
            const fio = state.active() orelse return;
            nudgeSelected(fio, state, 0, 10);
        },
        .align_to_grid => {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            const snap = state.tool.snap_size;
            var changed = false;
            for (sch.instances.items, 0..) |*inst, i| {
                if (i >= state.selection.instances.bit_length or !state.selection.instances.isSet(i)) continue;
                inst.pos.x = @intFromFloat(@round(@as(f32, @floatFromInt(inst.pos.x)) / snap) * snap);
                inst.pos.y = @intFromFloat(@round(@as(f32, @floatFromInt(inst.pos.y)) / snap) * snap);
                changed = true;
            }
            if (changed) {
                fio.dirty = true;
                state.setStatus("Aligned to grid");
            } else {
                state.setStatus("Nothing selected to align");
            }
        },
        .move_interactive => {
            state.tool.active = .move;
            state.setStatus("Move interactive (stub)");
        },
        .move_interactive_stretch => {
            state.tool.active = .move;
            state.setStatus("Move interactive stretch (stub)");
        },
        .move_interactive_insert => {
            state.tool.active = .move;
            state.setStatus("Move interactive insert wires (stub)");
        },
        .escape_mode => {
            state.tool.wire_start = null;
            state.tool.active = .select;
            state.selection.clear();
            state.setStatus("Ready");
        },
        .place_device => |p| {
            const fio = state.active() orelse return;
            const new_idx = try fio.placeSymbol(p.sym_path, p.name, pointFromF64(p.x, p.y), .{});
            state.history.push(c, .{ .place_device = .{ .idx = @intCast(new_idx) } });
            return;
        },
        .delete_device => |p| {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            if (p.idx >= sch.instances.items.len) return;
            const inst = sch.instances.items[p.idx];
            const inv: CommandInverse = .{ .delete_device = .{
                .sym_path = inst.symbol,
                .name = inst.name,
                .x = @floatFromInt(inst.pos.x),
                .y = @floatFromInt(inst.pos.y),
            } };
            _ = fio.deleteInstanceAt(p.idx);
            state.history.push(c, inv);
            return;
        },
        .move_device => |p| {
            const fio = state.active() orelse return;
            _ = fio.moveInstanceBy(
                p.idx,
                @as(i32, @intFromFloat(@round(p.dx))),
                @as(i32, @intFromFloat(@round(p.dy))),
            );
            state.history.push(c, .{ .move_device = .{ .idx = p.idx, .dx = -p.dx, .dy = -p.dy } });
            return;
        },
        .set_prop => |p| {
            const fio = state.active() orelse return;
            try fio.setProp(p.idx, p.key, p.val);
            state.history.push(c, .none);
            return;
        },
        .add_wire => |p| {
            const fio = state.active() orelse return;
            try fio.addWireSeg(pointFromF64(p.x0, p.y0), pointFromF64(p.x1, p.y1), null);
            const new_wire_idx = fio.schematic().wires.items.len - 1;
            state.history.push(c, .{ .add_wire = .{ .idx = new_wire_idx } });
            return;
        },
        .delete_wire => |p| {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            if (p.idx >= sch.wires.items.len) return;
            const wire = sch.wires.items[p.idx];
            const inv: CommandInverse = .{ .delete_wire = .{
                .x0 = @floatFromInt(wire.start.x),
                .y0 = @floatFromInt(wire.start.y),
                .x1 = @floatFromInt(wire.end.x),
                .y1 = @floatFromInt(wire.end.y),
            } };
            _ = fio.deleteWireAt(p.idx);
            state.history.push(c, inv);
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

fn rotateSelected(fio: *state_mod.FileIO, state: *AppState, delta: u2) void {
    const sch = fio.schematic();
    var changed = false;
    for (sch.instances.items, 0..) |*inst, i| {
        if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i)) {
            inst.xform.rot = (inst.xform.rot + delta) & 0b11;
            changed = true;
        }
    }
    if (changed) fio.dirty = true;
}

fn flipSelected(fio: *state_mod.FileIO, state: *AppState) void {
    const sch = fio.schematic();
    var changed = false;
    for (sch.instances.items, 0..) |*inst, i| {
        if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i)) {
            inst.xform.flip = !inst.xform.flip;
            changed = true;
        }
    }
    if (changed) fio.dirty = true;
}

fn nudgeSelected(fio: *state_mod.FileIO, state: *AppState, dx: i32, dy: i32) void {
    const sch = fio.schematic();
    var changed = false;
    for (sch.instances.items, 0..) |*inst, i| {
        if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i)) {
            inst.pos.x += dx;
            inst.pos.y += dy;
            changed = true;
        }
    }
    if (changed) fio.dirty = true;
}

fn duplicateSelected(fio: *state_mod.FileIO, state: *AppState) void {
    const sch = fio.schematic();
    const sa = sch.alloc();
    const base_len = sch.instances.items.len;

    for (0..base_len) |i| {
        if (i >= state.selection.instances.bit_length or !state.selection.instances.isSet(i)) continue;
        var copy = sch.instances.items[i];
        copy.pos.x += 20;
        copy.pos.y += 20;
        sch.instances.append(sa, copy) catch continue;
    }
    fio.dirty = true;
}
