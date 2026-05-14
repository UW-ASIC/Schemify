const std = @import("std");
const Command = @import("types.zig").Command;
const RingBuffer = @import("utility").RingBuffer;

pub const CommandQueue = struct {
    ring: RingBuffer(Command, 64) = .{},

    pub fn push(self: *CommandQueue, alloc: std.mem.Allocator, cmd: Command) error{Full}!void {
        _ = alloc;
        return self.ring.tryPush(cmd);
    }

    pub fn pop(self: *CommandQueue) ?Command {
        return self.ring.pop();
    }

    pub fn isEmpty(self: *const CommandQueue) bool {
        return self.ring.count == 0;
    }

    pub fn deinit(self: *CommandQueue, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

test "push pop round-trip" {
    var q: CommandQueue = .{};
    try q.push(undefined, .{ .immediate = .zoom_in });
    try q.push(undefined, .{ .immediate = .zoom_out });
    const a = q.pop() orelse return error.TestUnexpectedResult;
    try std.testing.expect(a.immediate == .zoom_in);
    const b = q.pop() orelse return error.TestUnexpectedResult;
    try std.testing.expect(b.immediate == .zoom_out);
    try std.testing.expect(q.pop() == null);
}

test "isEmpty" {
    var q: CommandQueue = .{};
    try std.testing.expect(q.isEmpty());
    try q.push(undefined, .{ .immediate = .undo });
    try std.testing.expect(!q.isEmpty());
    _ = q.pop();
    try std.testing.expect(q.isEmpty());
}
