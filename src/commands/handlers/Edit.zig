const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const types = @import("../types.zig");
const Immediate = types.Immediate;
const Undoable = types.Undoable;

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

pub fn handleEdit(und: Undoable, state: anytype) Error!void {
    switch (und) {
        // ── Transforms ───────────────────────────────────────────────────────
        .rotate_cw => rotateSelected(state, 1),
        .rotate_ccw => rotateSelected(state, 3),
        .flip_horizontal => flipSelectedH(state),
        .flip_vertical => flipSelectedV(state),

        .nudge_left => nudgeSelected(state, -10, 0),
        .nudge_right => nudgeSelected(state, 10, 0),
        .nudge_up => nudgeSelected(state, 0, -10),
        .nudge_down => nudgeSelected(state, 0, 10),

        .align_to_grid => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const snap = state.tool.snap_size;
            const xs = sch.instances.items(.x);
            const ys = sch.instances.items(.y);
            var changed = false;
            for (0..sch.instances.len) |i| {
                if (!fio.selection.isInstSelected(i)) continue;
                const fpos: @Vector(2, f32) = .{ @floatFromInt(xs[i]), @floatFromInt(ys[i]) };
                const sv: @Vector(2, f32) = @splat(snap);
                const rounded = @round(fpos / sv) * sv;
                xs[i] = @intFromFloat(rounded[0]);
                ys[i] = @intFromFloat(rounded[1]);
                changed = true;
            }
            if (changed) { fio.dirty = true; state.setStatus("Aligned to grid"); } else state.setStatus("Nothing selected to align");
        },

        // ── Delete / Duplicate ───────────────────────────────────────────────
        .delete_selected => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            var wi = sch.wires.len;
            while (wi > 0) { wi -= 1; if (fio.selection.isWireSelected(wi)) sch.wires.orderedRemove(wi); }
            var ii = sch.instances.len;
            while (ii > 0) { ii -= 1; if (selInst(fio, ii)) sch.instances.orderedRemove(ii); }
            // Delete selected shapes
            var li = sch.lines.len;
            while (li > 0) { li -= 1; if (fio.selection.lines.bit_length > li and fio.selection.lines.isSet(li)) sch.lines.orderedRemove(li); }
            var ri = sch.rects.len;
            while (ri > 0) { ri -= 1; if (fio.selection.rects.bit_length > ri and fio.selection.rects.isSet(ri)) sch.rects.orderedRemove(ri); }
            var ci = sch.circles.len;
            while (ci > 0) { ci -= 1; if (fio.selection.circles.bit_length > ci and fio.selection.circles.isSet(ci)) sch.circles.orderedRemove(ci); }
            var ai = sch.arcs.len;
            while (ai > 0) { ai -= 1; if (fio.selection.arcs.bit_length > ai and fio.selection.arcs.isSet(ai)) sch.arcs.orderedRemove(ai); }
            var ti = sch.texts.len;
            while (ti > 0) { ti -= 1; if (fio.selection.texts.bit_length > ti and fio.selection.texts.isSet(ti)) sch.texts.orderedRemove(ti); }
            fio.selection.clear();
            fio.dirty = true;
        },

        .duplicate_selected => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const sa = fio.alloc;
            const before_len = sch.instances.len;
            for (0..before_len) |i| {
                if (!fio.selection.isInstSelected(i)) continue;
                var copy = sch.instances.get(i);
                copy.x += 20;
                copy.y += 20;
                sch.instances.append(sa, copy) catch continue;
            }
            fio.dirty = true;
        },

        // ── Place device / wire / prop ───────────────────────────────────────
        .place_device => |p| {
            const fio = state.active() orelse return;
            const core = @import("schematic");
            const kind = core.Schemify.symToKind(p.sym_path);
            const pfx: u8 = core.devices.Devices.prefix_lut[@intFromEnum(kind)];
            const pfx_ch: u8 = if (pfx != 0) pfx else 'X';
            var inst_name: []const u8 = p.name;
            var name_buf: [32]u8 = undefined;
            if (p.name.len == 0 or p.name[0] != pfx_ch) {
                var counter: u32 = 1;
                const names = fio.sch.instances.items(.name);
                for (0..fio.sch.instances.len) |ci| {
                    const n = fio.sch.str(names[ci]);
                    if (n.len > 0 and n[0] == pfx_ch) counter += 1;
                }
                inst_name = std.fmt.bufPrint(&name_buf, "{c}{d}", .{ pfx_ch, counter }) catch "X1";
            }
            _ = try fio.sch.addComponent(fio.alloc, .{ .name = inst_name, .symbol = p.sym_path, .x = p.x, .y = p.y, .rot = p.rot, .flip = p.flip });
            fio.dirty = true;
        },

        .add_wire => |p| {
            const fio = state.active() orelse return;
            try fio.addWireSegBus(.{ p.x0, p.y0 }, .{ p.x1, p.y1 }, p.net_name, p.bus);
        },

        .set_instance_prop => |p| {
            const fio = state.active() orelse return;
            fio.sch.setInstanceProperty(fio.alloc, p.idx, p.key, p.val) catch {
                state.setStatus("Failed to set property");
                return;
            };
            fio.dirty = true;
            state.setStatus("Property set");
        },

        .delete_instance => |p| {
            const fio = state.active() orelse return;
            fio.deleteInstanceAt(@as(usize, p.idx));
        },

        .delete_wire => |p| {
            const fio = state.active() orelse return;
            fio.deleteWireAt(@as(usize, p.idx));
        },

        .move_instance => |p| {
            const fio = state.active() orelse return;
            fio.moveInstanceBy(@as(usize, p.idx), p.dx, p.dy);
        },

        .move_wire => |p| {
            const fio = state.active() orelse return;
            fio.sch.moveWire(p.idx, p.dx, p.dy);
            fio.dirty = true;
        },

        .rename_instance => |p| {
            const fio = state.active() orelse return;
            if (p.idx >= fio.sch.instances.len) {
                state.setStatus("Invalid instance index");
                return;
            }
            fio.sch.setInstanceName(fio.alloc, p.idx, p.new_name) catch {};
            fio.dirty = true;
            state.setStatus("Instance renamed");
        },

        .rename_net => |p| {
            const fio = state.active() orelse return;
            if (p.wire_idx >= fio.sch.wires.len) {
                state.setStatus("Invalid wire index");
                return;
            }
            fio.sch.setWireNetName(fio.alloc, p.wire_idx, p.new_name) catch {};
            fio.dirty = true;
            state.setStatus("Net renamed");
        },

        .set_wire_color => |p| {
            const fio = state.active() orelse return;
            if (p.wire_idx >= fio.sch.wires.len) {
                state.setStatus("Invalid wire index");
                return;
            }
            fio.sch.wires.items(.color)[p.wire_idx] = p.color;
            fio.dirty = true;
            state.setStatus(if (p.color == 0) "Wire color cleared" else "Wire color set");
        },

        .set_spice_code => |p| {
            const fio = state.active() orelse return;
            fio.sch.spice_body = fio.sch.strings.add(fio.alloc, p.code) catch .empty;
            fio.dirty = true;
            state.setStatus("SPICE code updated");
        },

        .set_documentation => |p| {
            const fio = state.active() orelse return;
            fio.sch.setDocumentation(fio.alloc, p.content) catch {};
            fio.dirty = true;
            state.setStatus("Documentation updated");
        },

        // ── Geometry ─────────────────────────────────────────────────────────
        .add_line => |p| {
            const fio = state.active() orelse return;
            fio.sch.drawLine(fio.alloc, .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .layer = p.layer }) catch return;
            fio.dirty = true;
            state.setStatus("Line placed");
        },

        .add_rect => |p| {
            const fio = state.active() orelse return;
            fio.sch.drawRect(fio.alloc, .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .layer = p.layer }) catch return;
            fio.dirty = true;
            state.setStatus("Rect placed");
        },

        .add_circle => |p| {
            const fio = state.active() orelse return;
            fio.sch.drawCircle(fio.alloc, .{ .cx = p.cx, .cy = p.cy, .radius = p.radius, .layer = p.layer }) catch return;
            fio.dirty = true;
            state.setStatus("Circle placed");
        },

        .add_arc => |p| {
            const fio = state.active() orelse return;
            fio.sch.drawArc(fio.alloc, .{ .cx = p.cx, .cy = p.cy, .radius = p.radius, .start_angle = p.start_angle, .sweep_angle = p.sweep_angle, .layer = p.layer }) catch return;
            fio.dirty = true;
            state.setStatus("Arc placed");
        },

        .add_text => |p| {
            const fio = state.active() orelse return;
            fio.sch.drawTextStr(fio.alloc, p.content, p.x, p.y) catch return;
            fio.dirty = true;
            state.setStatus("Text placed");
        },

        // Handled by dispatchUndoable in Dispatch.zig directly.
        .run_sim, .plugin_mutation, .auto_layout => {},
    }
}

fn rotateSelected(state: anytype, comptime increment: u2) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const flags = sch.instances.items(.flags);

    var sum_x: i64 = 0;
    var sum_y: i64 = 0;
    var count: i64 = 0;
    for (0..sch.instances.len) |i| {
        if (!fio.selection.isInstSelected(i)) continue;
        sum_x += xs[i];
        sum_y += ys[i];
        count += 1;
    }
    if (count == 0) return;

    if (count == 1) {
        for (0..flags.len) |i| {
            if (!fio.selection.isInstSelected(i)) continue;
            flags[i].rot = flags[i].rot +% increment;
        }
    } else {
        const cx: i32 = @intCast(@divTrunc(sum_x, count));
        const cy: i32 = @intCast(@divTrunc(sum_y, count));
        const snap: i32 = @intFromFloat(state.tool.snap_size);
        const gcx = if (snap > 0) @divTrunc(cx + @divTrunc(snap, 2), snap) * snap else cx;
        const gcy = if (snap > 0) @divTrunc(cy + @divTrunc(snap, 2), snap) * snap else cy;

        for (0..sch.instances.len) |i| {
            if (!fio.selection.isInstSelected(i)) continue;
            const dx = xs[i] - gcx;
            const dy = ys[i] - gcy;
            if (increment == 1) {
                xs[i] = gcx + dy;
                ys[i] = gcy - dx;
            } else {
                xs[i] = gcx - dy;
                ys[i] = gcy + dx;
            }
            flags[i].rot = flags[i].rot +% increment;
        }
    }
    fio.dirty = true;
}

fn flipSelectedH(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const xs = sch.instances.items(.x);
    const flags = sch.instances.items(.flags);

    var sum_x: i64 = 0;
    var count: i64 = 0;
    for (0..sch.instances.len) |i| {
        if (!fio.selection.isInstSelected(i)) continue;
        sum_x += xs[i];
        count += 1;
    }
    if (count == 0) return;

    if (count == 1) {
        for (0..flags.len) |i| {
            if (!fio.selection.isInstSelected(i)) continue;
            flags[i].flip = !flags[i].flip;
        }
    } else {
        const cx: i32 = @intCast(@divTrunc(sum_x, count));
        for (0..sch.instances.len) |i| {
            if (!fio.selection.isInstSelected(i)) continue;
            xs[i] = 2 * cx - xs[i];
            flags[i].flip = !flags[i].flip;
        }
    }
    fio.dirty = true;
}

fn flipSelectedV(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const ys = sch.instances.items(.y);
    const flags = sch.instances.items(.flags);

    var sum_y: i64 = 0;
    var count: i64 = 0;
    for (0..sch.instances.len) |i| {
        if (!fio.selection.isInstSelected(i)) continue;
        sum_y += ys[i];
        count += 1;
    }
    if (count == 0) return;

    if (count == 1) {
        for (0..flags.len) |i| {
            if (!fio.selection.isInstSelected(i)) continue;
            flags[i].flip = !flags[i].flip;
            flags[i].rot = flags[i].rot +% 2;
        }
    } else {
        const cy: i32 = @intCast(@divTrunc(sum_y, count));
        for (0..sch.instances.len) |i| {
            if (!fio.selection.isInstSelected(i)) continue;
            ys[i] = 2 * cy - ys[i];
            flags[i].flip = !flags[i].flip;
            flags[i].rot = flags[i].rot +% 2;
        }
    }
    fio.dirty = true;
}

fn nudgeSelected(state: anytype, dx: i32, dy: i32) void {
    const fio = state.active() orelse return;
    const xs = fio.sch.instances.items(.x);
    const ys = fio.sch.instances.items(.y);
    var changed = false;
    for (0..fio.sch.instances.len) |i| {
        if (!fio.selection.isInstSelected(i)) continue;
        xs[i] += dx;
        ys[i] += dy;
        changed = true;
    }
    if (changed) fio.dirty = true;
}
