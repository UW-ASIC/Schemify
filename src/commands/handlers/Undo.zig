//! Undo/redo: inverse-command types, the History ring, and the handler.

const std = @import("std");
const st = @import("state");
const core = @import("core");
const Wire = st.Wire;
const DeviceKind = core.DeviceKind;

const cmd          = @import("../utils/command.zig");
const Immediate    = cmd.Immediate;
const Undoable     = cmd.Undoable;
const PlaceDevice  = cmd.PlaceDevice;
const DeleteDevice = cmd.DeleteDevice;
const MoveDevice   = cmd.MoveDevice;
const SetProp      = cmd.SetProp;
const AddWire      = cmd.AddWire;
const DeleteWire   = cmd.DeleteWire;
const Edit         = @import("Edit.zig");

pub const Error = error{OutOfMemory};

// ── Inverse payload types ─────────────────────────────────────────────────────

/// Slim snapshot of a deleted instance — only the fields needed to re-insert.
/// prop/conn indices are NOT stored; undo re-appends without restoring connections.
pub const SnapInst = struct {
    x: i32,
    y: i32,
    kind: DeviceKind,
    rot: u2,
    flip: bool,
    name: []const u8,
    symbol: []const u8,
};

/// Slim snapshot of deleted items; allocated on demand.
pub const RestoreSnapshot = struct { instances: []SnapInst, wires: []Wire };
/// How many items were appended by duplicate_selected; pop them to undo.
pub const DeleteLastN     = struct { n: u32 };

pub const CommandInverse = union(enum) {
    none,
    place_device:        DeleteDevice,   // undo place  → delete by idx
    delete_device:       PlaceDevice,    // undo delete → re-place
    move_device:         MoveDevice,     // undo move   → move by -delta (negated at push time)
    set_prop:            SetProp,        // undo set    → restore old kv
    add_wire:            DeleteWire,     // undo add    → delete by idx
    delete_wire:         AddWire,        // undo delete → re-add segment
    delete_selected:     RestoreSnapshot,
    duplicate_selected:  DeleteLastN,
};

// ── History ───────────────────────────────────────────────────────────────────

/// One entry in the undo ring — stores both the inverse (for undo) and the
/// original forward command (for redo).
const UndoEntry = struct {
    inv: CommandInverse,
    forward: ?Undoable,
};

/// Undo history backed by a fixed ring buffer (no heap allocation).
/// Default value `.{}` is valid; `deinit` is a no-op.
pub const History = struct {
    pub const CAP = 64;

    entries: [CAP]UndoEntry = undefined,
    head: u8 = 0,
    len: u8 = 0,

    /// Record an inverse command paired with its forward undoable command.
    /// When the ring is full the oldest entry is silently overwritten.
    pub fn push(self: *History, inv: CommandInverse, forward: ?Undoable) void {
        self.entries[self.head] = .{ .inv = inv, .forward = forward };
        self.head = (self.head +% 1) % CAP;
        if (self.len < CAP) self.len += 1;
    }

    pub fn popUndo(self: *History) ?CommandInverse {
        if (self.len == 0) return null;
        self.head = if (self.head == 0) CAP - 1 else self.head - 1;
        self.len -= 1;
        return self.entries[self.head].inv;
    }

    pub fn popRedo(self: *History) ?Undoable {
        if (self.len == 0) return null;
        // The redo stack is the inverse of the undo stack: we need the entry
        // just after head (the oldest entry in the ring that hasn't been undone).
        // head always points to the next free slot, so last valid entry is
        // (head + CAP - 1) % CAP before push, but we already decremented head in popUndo.
        // The redo target is the entry at position (head + 1) % CAP relative to current head.
        const redo_head = (self.head +% 1) % CAP;
        const entry = self.entries[redo_head];
        if (entry.forward == null) return null;
        // Move this entry out of the redo path — set its forward to null so it
        // won't be returned again on a second popRedo without a subsequent undo.
        const forward = entry.forward;
        self.entries[redo_head].forward = null;
        return forward;
    }

    /// Free heap memory owned by any `delete_selected` snapshot before
    /// overwriting or resetting the ring entry.
    pub fn deinit(self: *History, a: std.mem.Allocator) void {
        for (0..self.len) |i| {
            const idx = (self.head +% CAP - self.len +% i) % CAP;
            if (self.entries[idx].inv == .delete_selected) {
                const snap = self.entries[idx].inv.delete_selected;
                for (snap.instances) |si| {
                    a.free(si.name);
                    a.free(si.symbol);
                }
                a.free(snap.instances);
                a.free(snap.wires);
            }
        }
    }
};

// ── Handler ───────────────────────────────────────────────────────────────────

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .undo => {
            const fio_undo = state.active() orelse { state.setStatus("Nothing to undo"); return; };
            const inv = fio_undo.history.popUndo() orelse {
                state.setStatus("Nothing to undo");
                return;
            };
            // fio already obtained above as fio_undo
            const fio = fio_undo;
            try applyInverse(inv, fio, state);
        },
        .redo => {
            const fio_redo = state.active() orelse { state.setStatus("Nothing to redo"); return; };
            const forward = fio_redo.history.popRedo() orelse {
                state.setStatus("Nothing to redo");
                return;
            };
            // Re-apply the forward command. This re-executes the operation and pushes
            // its inverse onto the undo stack, keeping the stacks symmetric.
            Edit.handleUndoable(forward, state) catch return;
            state.setStatus("Redo");
        },
        else => unreachable,
    }
}

fn applyInverse(inv: CommandInverse, fio: anytype, state: anytype) Error!void {
    switch (inv) {
        .none => {},

        .place_device => |pd| {
            _ = fio.deleteInstanceAt(@as(usize, pd.idx));
        },

        .delete_device => |dd| {
            _ = try fio.placeSymbol(dd.sym_path, dd.name, dd.pos, .{});
            // Snapshot (sym_path, name) strings consumed; caller owns them.
        },

        .move_device => |md| {
            _ = fio.moveInstanceBy(@as(usize, md.idx), md.delta[0], md.delta[1]);
        },

        .set_prop => |sp| try fio.setProp(@as(usize, sp.idx), sp.key, sp.val),

        .add_wire => |aw| {
            _ = fio.deleteWireAt(@as(usize, aw.idx));
        },

        .delete_wire => |dw| {
            try fio.addWireSeg(dw.start, dw.end, null);
        },

        .delete_selected => |snap| {
            const sch = &fio.sch;
            const a = state.allocator();
            for (snap.instances) |si| {
                const inst: st.Instance = .{
                    .name       = si.name,
                    .symbol     = si.symbol,
                    .x          = si.x,
                    .y          = si.y,
                    .kind       = si.kind,
                    .rot        = si.rot,
                    .flip       = si.flip,
                };
                sch.instances.append(a, inst) catch {};
            }
            for (snap.wires) |w| sch.wires.append(a, w) catch {};
            // Snapshot strings were owned by the snapshot; free them now.
            for (snap.instances) |si| {
                a.free(si.name);
                a.free(si.symbol);
            }
            a.free(snap.instances);
            a.free(snap.wires);
            fio.dirty = true;
            state.setStatus("Undo: restored deleted objects");
        },

        .duplicate_selected => |d| {
            const sch = &fio.sch;
            const n   = @min(d.n, sch.instances.len);
            sch.instances.shrinkRetainingCapacity(sch.instances.len - n);
            fio.dirty = true;
            state.setStatus("Undo: removed duplicated objects");
        },
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Expose struct size for History" {
    const print = @import("std").debug.print;
    print("History:        {d}B\n", .{@sizeOf(History)});
    print("CommandInverse: {d}B\n", .{@sizeOf(CommandInverse)});
    print("RestoreSnapshot:{d}B\n", .{@sizeOf(RestoreSnapshot)});
}
