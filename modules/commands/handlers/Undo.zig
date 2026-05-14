const std = @import("std");
const types = @import("../types.zig");
const Undoable = types.Undoable;
const edit_mod = @import("Edit.zig");

pub const Error = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    Unexpected,
    Full,
};

/// Undo/redo history backed by a fixed ring buffer.
pub const History = struct {
    pub const CAP = 64;

    entries: [CAP]Undoable = undefined,
    head: u8 = 0,
    len: u8 = 0,

    pub fn push(self: *History, cmd: Undoable) void {
        self.entries[self.head] = cmd;
        self.head = (self.head +% 1) % CAP;
        if (self.len < CAP) self.len += 1;
    }

    pub fn pop(self: *History) ?Undoable {
        if (self.len == 0) return null;
        self.head = if (self.head == 0) CAP - 1 else self.head - 1;
        self.len -= 1;
        return self.entries[self.head];
    }

    pub fn clear(self: *History) void {
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
    const fio = state.active() orelse { state.setStatus("Nothing to undo"); return; };
    const cmd = fio.undo_history.pop() orelse { state.setStatus("Nothing to undo"); return; };
    const inverse = invertCommand(cmd) orelse {
        fio.undo_history.push(cmd);
        state.setStatus("Cannot undo this action");
        return;
    };
    try edit_mod.handleEdit(inverse, state);
    fio.redo_history.push(cmd);
    state.setStatus("Undone");
}

pub fn handleRedo(state: anytype) Error!void {
    const fio = state.active() orelse { state.setStatus("Nothing to redo"); return; };
    const cmd = fio.redo_history.pop() orelse { state.setStatus("Nothing to redo"); return; };
    try edit_mod.handleEdit(cmd, state);
    fio.undo_history.push(cmd);
    state.setStatus("Redone");
}
