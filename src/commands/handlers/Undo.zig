const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const Undoable = types.Undoable;
const edit_mod = @import("Edit.zig");
const Schemify = @import("schematic").Schemify;

pub const Error = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    Unexpected,
    Full,
};

/// A snapshot entry holds a heap-allocated deep copy of the schematic
/// taken before a non-invertible command was executed.
pub const SnapshotEntry = struct {
    sch: *Schemify,
    alloc: Allocator,

    pub fn deinit(self: *SnapshotEntry) void {
        self.sch.deinitClone(self.alloc);
    }
};

/// An undo/redo history entry: either a lightweight inverse command or
/// a full schematic snapshot for non-invertible mutations.
pub const Entry = union(enum) {
    inverse: Undoable,
    snapshot: SnapshotEntry,
};

/// Undo/redo history backed by a fixed ring buffer.
pub const History = struct {
    pub const CAP = 64;

    entries: [CAP]Entry = undefined,
    head: u8 = 0,
    len: u8 = 0,

    pub fn push(self: *History, entry: Entry) void {
        // If we are about to overwrite an existing snapshot (ring wrap), free it.
        if (self.len == CAP) {
            const oldest = (self.head +% CAP -% self.len) % CAP;
            switch (self.entries[oldest]) {
                .snapshot => |*s| s.deinit(),
                .inverse => {},
            }
        }
        self.entries[self.head] = entry;
        self.head = (self.head +% 1) % CAP;
        if (self.len < CAP) self.len += 1;
    }

    pub fn pop(self: *History) ?Entry {
        if (self.len == 0) return null;
        self.head = if (self.head == 0) CAP - 1 else self.head - 1;
        self.len -= 1;
        return self.entries[self.head];
    }

    pub fn clear(self: *History) void {
        // Free any snapshot entries before clearing.
        var i: u8 = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head +% CAP -% self.len +% i) % CAP;
            switch (self.entries[idx]) {
                .snapshot => |*s| s.deinit(),
                .inverse => {},
            }
        }
        self.len = 0;
        self.head = 0;
    }
};

/// Compute the inverse of an undoable command, if possible.
/// Returns null for commands that require captured state to invert.
pub fn invertCommand(cmd: Undoable) ?Undoable {
    return switch (cmd) {
        .rotate_cw => .rotate_ccw,
        .rotate_ccw => .rotate_cw,
        .flip_horizontal => .flip_horizontal,
        .flip_vertical => .flip_vertical,
        .nudge_left => .nudge_right,
        .nudge_right => .nudge_left,
        .nudge_up => .nudge_down,
        .nudge_down => .nudge_up,
        .move_instance => |p| .{ .move_instance = .{ .idx = p.idx, .dx = -p.dx, .dy = -p.dy } },
        .move_wire => |p| .{ .move_wire = .{ .idx = p.idx, .dx = -p.dx, .dy = -p.dy } },
        else => null,
    };
}

pub fn handleUndo(state: anytype) Error!void {
    const fio = state.active() orelse {
        state.setStatus("Nothing to undo");
        return;
    };
    const entry = fio.undo_history.pop() orelse {
        state.setStatus("Nothing to undo");
        return;
    };
    switch (entry) {
        .inverse => |cmd| {
            const inverse = invertCommand(cmd) orelse {
                // Should not happen — only invertible commands produce .inverse entries.
                fio.undo_history.push(.{ .inverse = cmd });
                state.setStatus("Cannot undo this action");
                return;
            };
            try edit_mod.handleEdit(inverse, state);
            fio.redo_history.push(.{ .inverse = cmd });
        },
        .snapshot => |snap| {
            // Save the current schematic as a redo snapshot, then restore.
            const redo_snap = fio.sch.clone(fio.alloc) catch {
                // OOM: put the snapshot back so we don't lose it.
                fio.undo_history.push(.{ .snapshot = snap });
                state.setStatus("Undo failed: out of memory");
                return;
            };
            // Tear down the current schematic and swap in the snapshot.
            fio.sch.deinit(fio.alloc);
            fio.sch = snap.sch.*;
            // Free the snapshot shell (the Schemify was moved out).
            snap.alloc.destroy(snap.sch);
            fio.redo_history.push(.{ .snapshot = .{ .sch = redo_snap, .alloc = fio.alloc } });
            fio.dirty = true;
        },
    }
    state.setStatus("Undone");
}

pub fn handleRedo(state: anytype) Error!void {
    const fio = state.active() orelse {
        state.setStatus("Nothing to redo");
        return;
    };
    const entry = fio.redo_history.pop() orelse {
        state.setStatus("Nothing to redo");
        return;
    };
    switch (entry) {
        .inverse => |cmd| {
            try edit_mod.handleEdit(cmd, state);
            fio.undo_history.push(.{ .inverse = cmd });
        },
        .snapshot => |snap| {
            // Save the current schematic as an undo snapshot, then restore.
            const undo_snap = fio.sch.clone(fio.alloc) catch {
                fio.redo_history.push(.{ .snapshot = snap });
                state.setStatus("Redo failed: out of memory");
                return;
            };
            fio.sch.deinit(fio.alloc);
            fio.sch = snap.sch.*;
            snap.alloc.destroy(snap.sch);
            fio.undo_history.push(.{ .snapshot = .{ .sch = undo_snap, .alloc = fio.alloc } });
            fio.dirty = true;
        },
    }
    state.setStatus("Redone");
}
