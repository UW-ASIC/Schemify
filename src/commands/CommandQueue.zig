//! Fixed-capacity command queue drained once per frame.

const std = @import("std");
const Command = @import("utils/command.zig").Command;
const utility = @import("utility");

const Ring = utility.RingBuffer(Command, 64);

/// Fixed-capacity command queue backed by a ring buffer. Zero heap allocations.
/// Default value `.{}` is valid. The `alloc` parameters on `push`/`deinit` are
/// retained for call-site compatibility but are unused.
pub const CommandQueue = struct {
    pub const max_capacity = 64;
    pub const PushError = error{Full};

    ring: Ring = .{},

    /// Push a command. Returns `error.Full` when the ring buffer is at capacity.
    /// The `alloc` parameter is accepted for call-site compatibility but ignored.
    pub fn push(self: *CommandQueue, alloc: std.mem.Allocator, c: Command) PushError!void {
        _ = alloc;
        try self.ring.push(c);
    }

    pub fn pop(self: *CommandQueue) ?Command {
        return self.ring.pop();
    }

    pub fn isEmpty(self: *const CommandQueue) bool {
        return self.ring.isEmpty();
    }

    /// No-op — ring buffer holds no heap memory. Kept for call-site compatibility.
    pub fn deinit(self: *CommandQueue, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};
