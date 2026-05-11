//! Edit handlers — undoable mutations: rotate, flip, nudge, place, move,
//! properties, duplicate, delete.

const std = @import("std");
const core = @import("core");
const h = @import("helpers.zig");
const Error = h.Error;
const Undoable = h.Undoable;
const selInst = h.selInst;
const selWire = h.selWire;

pub fn handleEdit(und: Undoable, state: anytype) Error!void {
    switch (und) {
        // -- Transforms -------------------------------------------------------
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
                if (!selInst(fio, i)) continue;
                const fpos: @Vector(2, f32) = .{ @floatFromInt(xs[i]), @floatFromInt(ys[i]) };
                const sv: @Vector(2, f32) = @splat(snap);
                const rounded = @round(fpos / sv) * sv;
                xs[i] = @intFromFloat(rounded[0]);
                ys[i] = @intFromFloat(rounded[1]);
                changed = true;
            }
            if (changed) { fio.dirty = true; state.setStatus("Aligned to grid"); } else state.setStatus("Nothing selected to align");
        },

        // -- Delete / Duplicate -----------------------------------------------
        .delete_selected => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            // Remove selected wires in reverse order.
            var wi = sch.wires.len;
            while (wi > 0) { wi -= 1; if (selWire(fio, wi)) sch.wires.orderedRemove(wi); }
            // Remove selected instances in reverse order.
            var ii = sch.instances.len;
            while (ii > 0) { ii -= 1; if (selInst(fio, ii)) sch.instances.orderedRemove(ii); }
            fio.selection.clear();
            fio.dirty = true;
        },

        .duplicate_selected => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const sa = fio.alloc;
            const before_len = sch.instances.len;
            for (0..before_len) |i| {
                if (!selInst(fio, i)) continue;
                var copy = sch.instances.get(i);
                copy.x += 20;
                copy.y += 20;
                sch.instances.append(sa, copy) catch continue;
            }
            fio.dirty = true;
            _ = sch.instances.len - before_len;
        },

        // -- Place device / wire / prop ---------------------------------------
        .place_device => |p| {
            const fio = state.active() orelse return;
            _ = try fio.placeSymbol(p.sym_path, p.name, .{ p.x, p.y });
        },

        .add_wire => |p| {
            const fio = state.active() orelse return;
            try fio.addWireSeg(.{ p.x0, p.y0 }, .{ p.x1, p.y1 }, p.net_name);
        },

        .set_instance_prop => |p| {
            const fio = state.active() orelse return;
            if (p.idx >= fio.sch.instances.len) {
                state.setStatus("Invalid instance index");
                return;
            }
            const sa = fio.alloc;
            const prop_starts = fio.sch.instances.items(.prop_start);
            const prop_counts = fio.sch.instances.items(.prop_count);
            const start: usize = prop_starts[p.idx];
            const count: usize = prop_counts[p.idx];
            // Search existing properties for matching key
            for (fio.sch.props.items[start .. start + count]) |*prop| {
                if (std.mem.eql(u8, prop.key, p.key)) {
                    prop.val = sa.dupe(u8, p.val) catch p.val;
                    fio.dirty = true;
                    state.setStatus("Property updated");
                    return;
                }
            }
            // New property -- relocate to end if not already there, then append
            const end: usize = fio.sch.props.items.len;
            if (start + count != end) {
                const new_start: u32 = @intCast(end);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    // Re-index each iteration since append may reallocate
                    const prop = fio.sch.props.items[start + i];
                    fio.sch.props.append(sa, prop) catch {
                        state.setStatus("Failed to add property");
                        return;
                    };
                }
                prop_starts[p.idx] = new_start;
            }
            fio.sch.props.append(sa, .{
                .key = sa.dupe(u8, p.key) catch p.key,
                .val = sa.dupe(u8, p.val) catch p.val,
            }) catch {
                state.setStatus("Failed to add property");
                return;
            };
            prop_counts[p.idx] += 1;
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
            if (p.idx < fio.sch.wires.len) {
                fio.sch.wires.items(.x0)[p.idx] += p.dx;
                fio.sch.wires.items(.y0)[p.idx] += p.dy;
                fio.sch.wires.items(.x1)[p.idx] += p.dx;
                fio.sch.wires.items(.y1)[p.idx] += p.dy;
                fio.dirty = true;
            }
        },

        .rename_instance => |p| {
            const fio = state.active() orelse return;
            if (p.idx >= fio.sch.instances.len) {
                state.setStatus("Invalid instance index");
                return;
            }
            fio.sch.instances.items(.name)[p.idx] = fio.alloc.dupe(u8, p.new_name) catch p.new_name;
            fio.dirty = true;
            state.setStatus("Instance renamed");
        },

        .rename_net => |p| {
            const fio = state.active() orelse return;
            if (p.wire_idx >= fio.sch.wires.len) {
                state.setStatus("Invalid wire index");
                return;
            }
            fio.sch.wires.items(.net_name)[p.wire_idx] = fio.alloc.dupe(u8, p.new_name) catch p.new_name;
            fio.dirty = true;
            state.setStatus("Net renamed");
        },

        .set_spice_code => |p| {
            const fio = state.active() orelse return;
            fio.sch.spice_body = fio.alloc.dupe(u8, p.code) catch p.code;
            fio.dirty = true;
            state.setStatus("SPICE code updated");
        },

        // Handled by dispatchUndoable in Dispatch.zig directly.
        .run_sim, .plugin_mutation => {},
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
        if (!selInst(fio, i)) continue;
        sum_x += xs[i];
        sum_y += ys[i];
        count += 1;
    }
    if (count == 0) return;

    if (count == 1) {
        for (0..flags.len) |i| {
            if (!selInst(fio, i)) continue;
            flags[i].rot = flags[i].rot +% increment;
        }
    } else {
        const cx: i32 = @intCast(@divTrunc(sum_x, count));
        const cy: i32 = @intCast(@divTrunc(sum_y, count));
        const snap: i32 = @intFromFloat(state.tool.snap_size);
        const gcx = if (snap > 0) @divTrunc(cx + @divTrunc(snap, 2), snap) * snap else cx;
        const gcy = if (snap > 0) @divTrunc(cy + @divTrunc(snap, 2), snap) * snap else cy;

        for (0..sch.instances.len) |i| {
            if (!selInst(fio, i)) continue;
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
        if (!selInst(fio, i)) continue;
        sum_x += xs[i];
        count += 1;
    }
    if (count == 0) return;

    if (count == 1) {
        for (0..flags.len) |i| {
            if (!selInst(fio, i)) continue;
            flags[i].flip = !flags[i].flip;
        }
    } else {
        const cx: i32 = @intCast(@divTrunc(sum_x, count));
        for (0..sch.instances.len) |i| {
            if (!selInst(fio, i)) continue;
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
        if (!selInst(fio, i)) continue;
        sum_y += ys[i];
        count += 1;
    }
    if (count == 0) return;

    if (count == 1) {
        for (0..flags.len) |i| {
            if (!selInst(fio, i)) continue;
            flags[i].flip = !flags[i].flip;
            flags[i].rot = flags[i].rot +% 2;
        }
    } else {
        const cy: i32 = @intCast(@divTrunc(sum_y, count));
        for (0..sch.instances.len) |i| {
            if (!selInst(fio, i)) continue;
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

    // Stretch unselected wire endpoints connected to selected instance pins
    // (must happen BEFORE instances are moved, so pin positions are still current)
    if (fio.selection.instances.bit_length > 0) {
        stretchWiresForSelection(fio, dx, dy);
    }

    for (0..fio.sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        xs[i] += dx;
        ys[i] += dy;
        changed = true;
    }
    if (changed) fio.dirty = true;
}

/// Rubber-band: shift unselected wire endpoints that match selected instance pins by (dx,dy).
/// Zero heap allocations; O(selected_instances * pins * wires).
fn stretchWiresForSelection(fio: anytype, dx: i32, dy: i32) void {
    const sch = &fio.sch;
    if (sch.wires.len == 0) return;

    const inst_xs = sch.instances.items(.x);
    const inst_ys = sch.instances.items(.y);
    const inst_flags = sch.instances.items(.flags);
    const x0s = sch.wires.items(.x0);
    const y0s = sch.wires.items(.y0);
    const x1s = sch.wires.items(.x1);
    const y1s = sch.wires.items(.y1);

    var inst_it = fio.selection.instances.iterator(.{});
    while (inst_it.next()) |inst_idx| {
        if (inst_idx >= sch.instances.len) continue;
        const ix = inst_xs[inst_idx];
        const iy = inst_ys[inst_idx];
        const rot = inst_flags[inst_idx].rot;
        const flip = inst_flags[inst_idx].flip;
        const pin_refs = nudgeGetPinRefs(sch, inst_idx);

        if (pin_refs.len == 0) {
            // Fallback: no pin data -- check instance origin
            nudgeStretchEndpoints(fio, x0s, y0s, x1s, y1s, sch.wires.len, ix, iy, dx, dy);
            continue;
        }

        for (pin_refs) |pin| {
            const wp = core.helpers.applyRotFlip(pin.x, pin.y, rot, flip, ix, iy);
            nudgeStretchEndpoints(fio, x0s, y0s, x1s, y1s, sch.wires.len, wp.x, wp.y, dx, dy);
        }
    }
}

fn nudgeStretchEndpoints(
    fio: anytype,
    x0s: []i32,
    y0s: []i32,
    x1s: []i32,
    y1s: []i32,
    wire_len: usize,
    wpx: i32,
    wpy: i32,
    dx: i32,
    dy: i32,
) void {
    for (0..wire_len) |wi| {
        if (selWire(fio, wi)) continue;
        if (x0s[wi] == wpx and y0s[wi] == wpy) { x0s[wi] += dx; y0s[wi] += dy; }
        if (x1s[wi] == wpx and y1s[wi] == wpy) { x1s[wi] += dx; y1s[wi] += dy; }
    }
}

fn nudgeGetPinRefs(sch: anytype, inst_idx: usize) []const core.types.PinRef {
    if (inst_idx < sch.sym_data.items.len) {
        const sd = sch.sym_data.items[inst_idx];
        if (sd.pins.len > 0) return sd.pins;
    }
    if (inst_idx < sch.prim_cache.len) {
        if (sch.prim_cache[inst_idx]) |entry| {
            return entry.pin_positions;
        }
    }
    return &.{};
}
