//! Edit command handlers (transforms, delete, nudge, align, payloads).

const std = @import("std");
const st = @import("state");
const Point = st.Point;
const Instance = st.Instance;
const Wire = st.Wire;
const cmd = @import("command.zig");
const Immediate = cmd.Immediate;
const Undoable  = cmd.Undoable;

pub const Error = error{OutOfMemory};

// ── Immediate (non-history) ───────────────────────────────────────────────────

pub fn handleImmediate(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .align_to_grid => {
            const fio  = state.active() orelse return;
            const sch  = &fio.sch;
            const snap = state.tool.snap_size;
            var changed = false;
            const xs = sch.instances.items(.x);
            const ys = sch.instances.items(.y);
            for (0..sch.instances.len) |i| {
                if (!selInst(state, i)) continue;
                // Round both axes in one vector operation.
                const fpos: @Vector(2, f32) = .{ @floatFromInt(xs[i]), @floatFromInt(ys[i]) };
                const sv:   @Vector(2, f32) = @splat(snap);
                const rounded = @round(fpos / sv) * sv;
                xs[i] = @intFromFloat(rounded[0]);
                ys[i] = @intFromFloat(rounded[1]);
                changed = true;
            }
            if (changed) { fio.dirty = true; state.setStatus("Aligned to grid"); }
            else state.setStatus("Nothing selected to align");
        },
        .move_interactive => { state.tool.active = .move; state.setStatus("Move interactive"); },
        .move_interactive_stretch => {
            // TODO: stretch mode — move selected instances while keeping connected
            // wires attached (rubber-band). Currently behaves the same as plain move.
            state.tool.active = .move;
            state.setStatus("Move interactive stretch");
        },
        .move_interactive_insert => {
            // TODO: insert mode — move selected instances and auto-insert wire
            // segments to maintain connectivity. Currently behaves like plain move.
            state.tool.active = .move;
            state.setStatus("Move interactive insert wires");
        },
        .escape_mode => {
            state.tool.wire_start = null;
            state.tool.active = .select;
            state.selection.clear();
            state.setStatus("Ready");
        },
        else => unreachable,
    }
}

// ── Undoable mutations ────────────────────────────────────────────────────────

pub fn handleUndoable(und: Undoable, state: anytype) Error!void {
    switch (und) {

        // ── Bulk transform: rotate/flip/nudge ─────────────────────────────────
        .rotate_cw       => applyToSelected(state, xformRotCw),
        .rotate_ccw      => applyToSelected(state, xformRotCcw),
        .flip_horizontal => applyToSelected(state, xformFlipH),
        .flip_vertical   => applyToSelected(state, xformFlipV),
        .nudge_left      => applyToSelected(state, nudgeLeft),
        .nudge_right     => applyToSelected(state, nudgeRight),
        .nudge_up        => applyToSelected(state, nudgeUp),
        .nudge_down      => applyToSelected(state, nudgeDown),

        // ── Delete selected ───────────────────────────────────────────────────
        .delete_selected => {
            const fio   = state.active() orelse return;
            const sch   = &fio.sch;
            const alloc = state.allocator();

            // Count first so we allocate exactly.
            var si: usize = 0;
            var sw: usize = 0;
            for (0..sch.instances.len) |i| if (selInst(state, i)) { si += 1; };
            for (0..sch.wires.len)     |i| if (selWire(state, i)) { sw += 1; };

            const snap_inst = alloc.alloc(Instance, si) catch try alloc.alloc(Instance, 0);
            const snap_wire = alloc.alloc(Wire,     sw) catch try alloc.alloc(Wire,     0);
            si = 0; sw = 0;
            for (0..sch.instances.len) |i| {
                if (selInst(state, i) and si < snap_inst.len) { snap_inst[si] = sch.instances.get(i); si += 1; }
            }
            for (0..sch.wires.len) |i| {
                if (selWire(state, i) and sw < snap_wire.len) { snap_wire[sw] = sch.wires.get(i); sw += 1; }
            }

            // Remove in reverse index order to keep indices stable.
            var wi = sch.wires.len;
            while (wi > 0) { wi -= 1; if (selWire(state, wi)) sch.wires.orderedRemove(wi); }
            var ii = sch.instances.len;
            while (ii > 0) { ii -= 1; if (selInst(state, ii)) sch.instances.orderedRemove(ii); }

            state.selection.clear();
            fio.dirty = true;
            state.history.push(state.allocator(), .{ .delete_selected = .{ .instances = snap_inst, .wires = snap_wire } });
        },

        // ── Duplicate selected ────────────────────────────────────────────────
        .duplicate_selected => {
            const fio        = state.active() orelse return;
            const sch        = &fio.sch;
            const sa         = sch.alloc();
            const before_len = sch.instances.len;
            for (0..before_len) |i| {
                if (!selInst(state, i)) continue;
                var copy = sch.instances.get(i);
                copy.x += 20;
                copy.y += 20;
                sch.instances.append(sa, copy) catch continue;
            }
            fio.dirty = true;
            state.history.push(state.allocator(), .{ .duplicate_selected = .{ .n = @intCast(sch.instances.len - before_len) } });
        },

        // ── Place / delete / move device ──────────────────────────────────────
        .place_device => |p| {
            const fio     = state.active() orelse return;
            const new_idx = try fio.placeSymbol(p.sym_path, p.name, p.pos, .{});
            state.history.push(state.allocator(), .{ .place_device = .{ .idx = @intCast(new_idx) } });
        },

        .delete_device => |p| {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const idx: usize = p.idx;
            if (idx >= sch.instances.len) return;
            const inst = sch.instances.get(idx);
            state.history.push(state.allocator(), .{ .delete_device = .{
                .sym_path = inst.symbol, .name = inst.name, .pos = .{ inst.x, inst.y },
            } });
            _ = fio.deleteInstanceAt(idx);
        },

        .move_device => |p| {
            const fio = state.active() orelse return;
            _ = fio.moveInstanceBy(@as(usize, p.idx), p.delta[0], p.delta[1]);
            // Negate delta here so applyInverse can use it directly.
            state.history.push(state.allocator(), .{ .move_device = .{ .idx = p.idx, .delta = .{ -p.delta[0], -p.delta[1] } } });
        },

        .set_prop => |p| {
            const fio = state.active() orelse return;
            try fio.setProp(@as(usize, p.idx), p.key, p.val);
            state.history.push(state.allocator(), .none);
        },

        // ── Wire placement ────────────────────────────────────────────────────
        .add_wire => |p| {
            const fio = state.active() orelse return;
            try fio.addWireSeg(p.start, p.end, null);
            const new_idx = fio.sch.wires.len - 1;
            state.history.push(state.allocator(), .{ .add_wire = .{ .idx = @intCast(new_idx) } });
        },

        .delete_wire => |p| {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const idx: usize = p.idx;
            if (idx >= sch.wires.len) return;
            const wire = sch.wires.get(idx);
            state.history.push(state.allocator(), .{ .delete_wire = .{ .start = .{ wire.x0, wire.y0 }, .end = .{ wire.x1, wire.y1 } } });
            _ = fio.deleteWireAt(idx);
        },

        // Handled elsewhere (file.zig / sim.zig) — must not reach here.
        .load_schematic, .save_schematic, .run_sim => unreachable,
    }
}

// ── Selection-index helpers ───────────────────────────────────────────────────

inline fn selInst(state: anytype, i: usize) bool {
    return i < state.selection.instances.bit_length and state.selection.instances.isSet(i);
}
inline fn selWire(state: anytype, i: usize) bool {
    return i < state.selection.wires.bit_length and state.selection.wires.isSet(i);
}

// ── Per-instance transform functions ─────────────────────────────────────────

fn xformRotCw(inst:  *Instance) void { inst.rot = inst.rot +% 1; }
fn xformRotCcw(inst: *Instance) void { inst.rot = inst.rot +% 3; }
fn xformFlipH(inst:  *Instance) void { inst.flip = !inst.flip; }
fn xformFlipV(inst:  *Instance) void { inst.flip = !inst.flip; inst.rot = inst.rot +% 2; }
fn nudgeLeft(inst:   *Instance) void { inst.x -= 10; }
fn nudgeRight(inst:  *Instance) void { inst.x += 10; }
fn nudgeUp(inst:     *Instance) void { inst.y -= 10; }
fn nudgeDown(inst:   *Instance) void { inst.y += 10; }

/// Apply `xform` to every selected instance and mark the document dirty if anything changed.
fn applyToSelected(state: anytype, xform: fn (*Instance) void) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    var changed = false;
    for (0..sch.instances.len) |i| {
        if (!selInst(state, i)) continue;
        var inst = sch.instances.get(i);
        xform(&inst);
        sch.instances.set(i, inst);
        changed = true;
    }
    if (changed) fio.dirty = true;
}
