//! Fixed-capacity command queue drained once per frame.

const std = @import("std");
const Command = @import("types.zig").Command;

/// Dynamic command queue drained once per frame. Backed by ArrayListUnmanaged;
/// returns `error.Full` when the soft capacity ceiling is reached so callers
/// can surface a diagnostic. Default value `.{}` is valid; call `deinit` to
/// release memory.
pub const CommandQueue = struct {
    pub const max_capacity = 64;
    pub const PushError = error{ Full, OutOfMemory };

    buf: std.ArrayListUnmanaged(Command) = .{},

    /// Push a command; allocator only needed when the backing array must grow.
    pub fn push(self: *CommandQueue, alloc: std.mem.Allocator, c: Command) PushError!void {
        if (self.buf.items.len >= max_capacity) return error.Full;
        try self.buf.append(alloc, c);
    }

    pub fn pop(self: *CommandQueue) ?Command {
        if (self.buf.items.len == 0) return null;
        return self.buf.orderedRemove(0);
    }

    pub fn isEmpty(self: *const CommandQueue) bool {
        return self.buf.items.len == 0;
    }

    pub fn deinit(self: *CommandQueue, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }
};
