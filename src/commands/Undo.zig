//! Undo/redo: inverse-command types, the History ring, and the handler.
//! History stores only the inverse (CommandInverse); the forward command is
//! not kept because full redo is not yet implemented.

const std = @import("std");
const core = @import("core");
const CT   = core.CT;

const cmd          = @import("command.zig");
const Immediate    = cmd.Immediate;
const Undoable     = cmd.Undoable;
const PlaceDevice  = cmd.PlaceDevice;
const DeleteDevice = cmd.DeleteDevice;
const MoveDevice   = cmd.MoveDevice;
const SetProp      = cmd.SetProp;
const AddWire      = cmd.AddWire;
const DeleteWire   = cmd.DeleteWire;

pub const Error = error{OutOfMemory};

// ── Inverse payload types ─────────────────────────────────────────────────────

/// Full snapshot of deleted items; allocated on demand.
pub const RestoreSnapshot = struct { instances: []CT.Instance, wires: []CT.Wire };
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

/// Undo history backed by `ArrayListUnmanaged`. Capped at `max_depth` entries;
/// the oldest entry is evicted when the cap is exceeded. Default value `.{}`
/// is valid; call `deinit(alloc)` to release memory.
pub const History = struct {
    pub const max_depth = 64;

    entries: std.ArrayListUnmanaged(CommandInverse) = .{},

    /// Record an inverse command. If the history is at capacity the oldest
    /// entry is evicted (orderedRemove is acceptable here — undo is infrequent).
    pub fn push(self: *History, alloc: std.mem.Allocator, inv: CommandInverse) void {
        if (self.entries.items.len >= max_depth) _ = self.entries.orderedRemove(0);
        self.entries.append(alloc, inv) catch {};
    }

    pub fn popUndo(self: *History) ?CommandInverse {
        return self.entries.pop();
    }

    /// Redo not yet implemented — forward commands are not stored.
    pub fn popRedo(_: *History) ?Undoable { return null; }

    pub fn deinit(self: *History, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
    }
};

// ── Handler ───────────────────────────────────────────────────────────────────

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .undo => {
            const inv = state.history.popUndo() orelse {
                state.setStatus("Nothing to undo");
                return;
            };
            const fio = state.active() orelse return;
            try applyInverse(inv, fio, state);
        },
        .redo => state.setStatus("Redo not yet implemented"),
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
            const sch = fio.schematic();
            for (snap.instances) |inst| sch.instances.append(sch.alloc(), inst) catch {};
            for (snap.wires)     |w|    sch.wires.append(sch.alloc(), w)        catch {};
            fio.dirty = true;
            state.setStatus("Undo: restored deleted objects");
        },

        .duplicate_selected => |d| {
            const sch = fio.schematic();
            const n   = @min(d.n, sch.instances.items.len);
            sch.instances.items.len -= n;
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
