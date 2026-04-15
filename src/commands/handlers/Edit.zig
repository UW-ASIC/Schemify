//! Edit command handlers (transforms, delete, nudge, align, payloads).

const std = @import("std");
const st = @import("state");
const core = @import("core");
const Wire = st.Wire;
const Instance = core.Instance;
const cmd = @import("../utils/command.zig");
const Immediate = cmd.Immediate;
const Undoable = cmd.Undoable;
const SnapInst = @import("Undo.zig").SnapInst;
const h = @import("../utils/helpers.zig");
const selInst = h.selInst;
const selWire = h.selWire;

pub const Error = error{OutOfMemory};

// ── Immediate (non-history) ───────────────────────────────────────────────────

pub fn handleImmediate(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .align_to_grid => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const snap = state.tool.snap_size;
            var changed = false;
            const xs = sch.instances.items(.x);
            const ys = sch.instances.items(.y);
            for (0..sch.instances.len) |i| {
                if (!selInst(fio, i)) continue;
                // Round both axes in one vector operation.
                const fpos: @Vector(2, f32) = .{ @floatFromInt(xs[i]), @floatFromInt(ys[i]) };
                const sv: @Vector(2, f32) = @splat(snap);
                const rounded = @round(fpos / sv) * sv;
                xs[i] = @intFromFloat(rounded[0]);
                ys[i] = @intFromFloat(rounded[1]);
                changed = true;
            }
            if (changed) {
                fio.dirty = true;
                state.setStatus("Aligned to grid");
            } else state.setStatus("Nothing selected to align");
        },
        .move_interactive => setMoveMode(state, "Move interactive"),
        .move_interactive_stretch => {
            // TODO: stretch mode — move selected instances while keeping connected
            // wires attached (rubber-band). Currently behaves the same as plain move.
            setMoveMode(state, "Move interactive stretch");
        },
        .move_interactive_insert => {
            // TODO: insert mode — move selected instances and auto-insert wire
            // segments to maintain connectivity. Currently behaves like plain move.
            setMoveMode(state, "Move interactive insert wires");
        },
        .escape_mode => {
            state.tool.wire_start = null;
            state.tool.active = .select;
            if (state.active()) |fio| fio.selection.clear();
            state.setStatus("Ready");
        },
        else => unreachable,
    }
}

inline fn setMoveMode(state: anytype, status: []const u8) void {
    state.tool.active = .move;
    state.setStatus(status);
}

// ── Undoable mutations ────────────────────────────────────────────────────────

pub fn handleUndoable(und: Undoable, state: anytype) Error!void {
    switch (und) {

        // ── Bulk transform: rotate/flip/nudge ─────────────────────────────────
        .rotate_cw => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const xs = sch.instances.items(.x);
            const ys = sch.instances.items(.y);
            const rots = sch.instances.items(.rot);

            // Count selected and compute centroid.
            var sum_x: i64 = 0;
            var sum_y: i64 = 0;
            var count: i64 = 0;
            for (0..sch.instances.len) |i| {
                const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                if (!isel) continue;
                sum_x += xs[i];
                sum_y += ys[i];
                count += 1;
            }
            if (count == 0) return;

            // For single selection, just rotate the component (no position change).
            if (count == 1) {
                for (0..rots.len) |i| {
                    const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                    if (!isel) continue;
                    rots[i] = rots[i] +% 1;
                }
            } else {
                // Group rotation: rotate positions around centroid + rotate each instance.
                const cx: i32 = @intCast(@divTrunc(sum_x, count));
                const cy: i32 = @intCast(@divTrunc(sum_y, count));
                // Snap centroid to grid.
                const snap: i32 = @intFromFloat(state.tool.snap_size);
                const gcx = if (snap > 0) @divTrunc(cx + @divTrunc(snap, 2), snap) * snap else cx;
                const gcy = if (snap > 0) @divTrunc(cy + @divTrunc(snap, 2), snap) * snap else cy;

                for (0..sch.instances.len) |i| {
                    const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                    if (!isel) continue;
                    // Rotate position 90 CW around centroid: (dx, dy) -> (dy, -dx)
                    const dx = xs[i] - gcx;
                    const dy = ys[i] - gcy;
                    xs[i] = gcx + dy;
                    ys[i] = gcy - dx;
                    rots[i] = rots[i] +% 1;
                }
            }
            fio.dirty = true;
        },
        .rotate_ccw => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const xs = sch.instances.items(.x);
            const ys = sch.instances.items(.y);
            const rots = sch.instances.items(.rot);

            var sum_x: i64 = 0;
            var sum_y: i64 = 0;
            var count: i64 = 0;
            for (0..sch.instances.len) |i| {
                const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                if (!isel) continue;
                sum_x += xs[i];
                sum_y += ys[i];
                count += 1;
            }
            if (count == 0) return;

            if (count == 1) {
                for (0..rots.len) |i| {
                    const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                    if (!isel) continue;
                    rots[i] = rots[i] +% 3;
                }
            } else {
                const cx: i32 = @intCast(@divTrunc(sum_x, count));
                const cy: i32 = @intCast(@divTrunc(sum_y, count));
                const snap: i32 = @intFromFloat(state.tool.snap_size);
                const gcx = if (snap > 0) @divTrunc(cx + @divTrunc(snap, 2), snap) * snap else cx;
                const gcy = if (snap > 0) @divTrunc(cy + @divTrunc(snap, 2), snap) * snap else cy;

                for (0..sch.instances.len) |i| {
                    const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                    if (!isel) continue;
                    // Rotate position 90 CCW around centroid: (dx, dy) -> (-dy, dx)
                    const dx = xs[i] - gcx;
                    const dy = ys[i] - gcy;
                    xs[i] = gcx - dy;
                    ys[i] = gcy + dx;
                    rots[i] = rots[i] +% 3;
                }
            }
            fio.dirty = true;
        },
        .flip_horizontal => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const xs = sch.instances.items(.x);
            const flips = sch.instances.items(.flip);

            var sum_x: i64 = 0;
            var count: i64 = 0;
            for (0..sch.instances.len) |i| {
                const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                if (!isel) continue;
                sum_x += xs[i];
                count += 1;
            }
            if (count == 0) return;

            if (count == 1) {
                for (0..flips.len) |i| {
                    const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                    if (!isel) continue;
                    flips[i] = !flips[i];
                }
            } else {
                const cx: i32 = @intCast(@divTrunc(sum_x, count));
                for (0..sch.instances.len) |i| {
                    const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                    if (!isel) continue;
                    xs[i] = 2 * cx - xs[i]; // Mirror x around centroid
                    flips[i] = !flips[i];
                }
            }
            fio.dirty = true;
        },
        .flip_vertical => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const ys = sch.instances.items(.y);
            const flips = sch.instances.items(.flip);
            const rots = sch.instances.items(.rot);

            var sum_y: i64 = 0;
            var count: i64 = 0;
            for (0..sch.instances.len) |i| {
                const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                if (!isel) continue;
                sum_y += ys[i];
                count += 1;
            }
            if (count == 0) return;

            if (count == 1) {
                for (0..flips.len) |i| {
                    const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                    if (!isel) continue;
                    flips[i] = !flips[i];
                    rots[i] = rots[i] +% 2;
                }
            } else {
                const cy: i32 = @intCast(@divTrunc(sum_y, count));
                for (0..sch.instances.len) |i| {
                    const isel = fio.selection.instances.bit_length > i and fio.selection.instances.isSet(i);
                    if (!isel) continue;
                    ys[i] = 2 * cy - ys[i]; // Mirror y around centroid
                    flips[i] = !flips[i];
                    rots[i] = rots[i] +% 2;
                }
            }
            fio.dirty = true;
        },
        .nudge_left => {
            const fio = state.active() orelse return;
            const xs = fio.sch.instances.items(.x);
            var changed = false;
            for (0..xs.len) |i| {
                if (!selInst(fio, i)) continue;
                xs[i] -= 10;
                changed = true;
            }
            if (changed) fio.dirty = true;
        },
        .nudge_right => {
            const fio = state.active() orelse return;
            const xs = fio.sch.instances.items(.x);
            var changed = false;
            for (0..xs.len) |i| {
                if (!selInst(fio, i)) continue;
                xs[i] += 10;
                changed = true;
            }
            if (changed) fio.dirty = true;
        },
        .nudge_up => {
            const fio = state.active() orelse return;
            const ys = fio.sch.instances.items(.y);
            var changed = false;
            for (0..ys.len) |i| {
                if (!selInst(fio, i)) continue;
                ys[i] -= 10;
                changed = true;
            }
            if (changed) fio.dirty = true;
        },
        .nudge_down => {
            const fio = state.active() orelse return;
            const ys = fio.sch.instances.items(.y);
            var changed = false;
            for (0..ys.len) |i| {
                if (!selInst(fio, i)) continue;
                ys[i] += 10;
                changed = true;
            }
            if (changed) fio.dirty = true;
        },

        // ── Delete selected ───────────────────────────────────────────────────
        .delete_selected => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const alloc = state.allocator();

            // Single pass: allocate worst-case capacity, fill, then shrink.
            var snap_inst = try std.ArrayListUnmanaged(SnapInst).initCapacity(alloc, sch.instances.len);
            for (0..sch.instances.len) |i| {
                if (!selInst(fio, i)) continue;
                const inst = sch.instances.get(i);
                const owned_name = alloc.dupe(u8, inst.name) catch {
                    // On partial failure, free what we already duplicated.
                    for (snap_inst.items) |si| {
                        alloc.free(si.name);
                        alloc.free(si.symbol);
                    }
                    snap_inst.deinit(alloc);
                    return error.OutOfMemory;
                };
                const owned_symbol = alloc.dupe(u8, inst.symbol) catch {
                    alloc.free(owned_name);
                    for (snap_inst.items) |si| {
                        alloc.free(si.name);
                        alloc.free(si.symbol);
                    }
                    snap_inst.deinit(alloc);
                    return error.OutOfMemory;
                };
                snap_inst.appendAssumeCapacity(.{
                    .x      = inst.x,
                    .y      = inst.y,
                    .kind   = inst.kind,
                    .rot    = inst.rot,
                    .flip   = inst.flip,
                    .name   = owned_name,
                    .symbol = owned_symbol,
                });
            }
            snap_inst.shrinkAndFree(alloc, snap_inst.items.len);

            var snap_wire = try std.ArrayListUnmanaged(Wire).initCapacity(alloc, sch.wires.len);
            for (0..sch.wires.len) |i| {
                if (selWire(fio, i)) snap_wire.appendAssumeCapacity(sch.wires.get(i));
            }
            snap_wire.shrinkAndFree(alloc, snap_wire.items.len);

            // Remove in reverse index order to keep indices stable.
            var wi = sch.wires.len;
            while (wi > 0) {
                wi -= 1;
                if (selWire(fio, wi)) sch.wires.orderedRemove(wi);
            }
            var ii = sch.instances.len;
            while (ii > 0) {
                ii -= 1;
                if (selInst(fio, ii)) sch.instances.orderedRemove(ii);
            }

            fio.selection.clear();
            fio.dirty = true;
            fio.history.push(.{ .delete_selected = .{ .instances = snap_inst.items, .wires = snap_wire.items } }, null);
        },

        // ── Duplicate selected ────────────────────────────────────────────────
        .duplicate_selected => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const sa = sch.alloc();
            const before_len = sch.instances.len;
            for (0..before_len) |i| {
                if (!selInst(fio, i)) continue;
                var copy = sch.instances.get(i);
                copy.x += 20;
                copy.y += 20;
                sch.instances.append(sa, copy) catch continue;
            }
            fio.dirty = true;
            fio.history.push(.{ .duplicate_selected = .{ .n = @intCast(sch.instances.len - before_len) } }, null);
        },

        // ── Place / delete / move device ──────────────────────────────────────
        .place_device => |p| {
            const fio = state.active() orelse return;
            const new_idx = try fio.placeSymbol(p.sym_path, p.name, p.pos, .{});
            fio.history.push(
                .{ .place_device = .{ .idx = @intCast(new_idx) } },
                .{ .place_device = .{ .sym_path = p.sym_path, .name = p.name, .pos = p.pos } },
            );
        },

        .delete_device => |p| {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const idx: usize = p.idx;
            if (idx >= sch.instances.len) return;
            const inst = sch.instances.get(idx);
            fio.history.push(
                .{ .delete_device = .{ .sym_path = inst.symbol, .name = inst.name, .pos = .{ inst.x, inst.y } } },
                .{ .delete_device = .{ .idx = @intCast(idx) } },
            );
            _ = fio.deleteInstanceAt(idx);
        },

        .move_device => |p| {
            const fio = state.active() orelse return;
            _ = fio.moveInstanceBy(@as(usize, p.idx), p.delta[0], p.delta[1]);
            // Negate delta here so applyInverse can use it directly.
            fio.history.push(
                .{ .move_device = .{ .idx = p.idx, .delta = .{ -p.delta[0], -p.delta[1] } } },
                .{ .move_device = .{ .idx = p.idx, .delta = p.delta } },
            );
        },

        .set_prop => |p| {
            const fio = state.active() orelse return;
            try fio.setProp(@as(usize, p.idx), p.key, p.val);
            fio.history.push(.none, null);
        },

        // ── Wire placement ────────────────────────────────────────────────────
        .add_wire => |p| {
            const fio = state.active() orelse return;
            try fio.addWireSeg(p.start, p.end, null);
            const new_idx = fio.sch.wires.len - 1;
            fio.history.push(.{ .add_wire = .{ .idx = @intCast(new_idx) } }, null);
        },

        .delete_wire => |p| {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const idx: usize = p.idx;
            if (idx >= sch.wires.len) return;
            const wire = sch.wires.get(idx);
            fio.history.push(.{ .delete_wire = .{ .start = .{ wire.x0, wire.y0 }, .end = .{ wire.x1, wire.y1 } } }, null);
            _ = fio.deleteWireAt(idx);
        },

        // Handled elsewhere (file.zig / sim.zig / Dispatch.zig) — must not reach here.
        .load_schematic, .save_schematic, .run_sim,
        .edit_spice_code => unreachable,
    }
}

// ── Per-instance transform functions ─────────────────────────────────────────

fn xformRotCw(inst: *Instance) void {
    inst.rot = inst.rot +% 1;
}
fn xformRotCcw(inst: *Instance) void {
    inst.rot = inst.rot +% 3;
}
fn xformFlipH(inst: *Instance) void {
    inst.flip = !inst.flip;
}
fn xformFlipV(inst: *Instance) void {
    inst.flip = !inst.flip;
    inst.rot = inst.rot +% 2;
}
fn nudgeLeft(inst: *Instance) void {
    inst.x -= 10;
}
fn nudgeRight(inst: *Instance) void {
    inst.x += 10;
}
fn nudgeUp(inst: *Instance) void {
    inst.y -= 10;
}
fn nudgeDown(inst: *Instance) void {
    inst.y += 10;
}

/// Apply `xform` to every selected instance and mark the document dirty if anything changed.
fn applyToSelected(state: anytype, xform: fn (*Instance) void) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    var changed = false;
    for (0..sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        var inst = sch.instances.get(i);
        xform(&inst);
        sch.instances.set(i, inst);
        changed = true;
    }
    if (changed) fio.dirty = true;
}
