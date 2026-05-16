const std = @import("std");

pub fn RingBuffer(comptime T: type, comptime cap: usize) type {
    comptime std.debug.assert(cap > 0 and (cap & (cap - 1)) == 0);
    const mask = cap - 1;

    return struct {
        buf: [cap]T = undefined,
        head: usize = 0,
        count: usize = 0,

        const Self = @This();

        /// Push, overwriting oldest if full.
        pub fn push(self: *Self, item: T) void {
            self.buf[(self.head + self.count) & mask] = item;
            if (self.count == cap)
                self.head = (self.head + 1) & mask
            else
                self.count += 1;
        }

        /// Push, returning error.Full if at capacity.
        pub fn tryPush(self: *Self, item: T) error{Full}!void {
            if (self.count == cap) return error.Full;
            self.buf[(self.head + self.count) & mask] = item;
            self.count += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const v = self.buf[self.head & mask];
            self.head = (self.head + 1) & mask;
            self.count -= 1;
            return v;
        }

        pub fn peek(self: *const Self) ?T {
            if (self.count == 0) return null;
            return self.buf[self.head & mask];
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn full(self: *const Self) bool {
            return self.count == cap;
        }
    };
}

test "push pop peek" {
    var rb: RingBuffer(u32, 4) = .{};
    rb.push(10);
    rb.push(20);
    try std.testing.expectEqual(@as(?u32, 10), rb.peek());
    try std.testing.expectEqual(@as(?u32, 10), rb.pop());
    try std.testing.expectEqual(@as(?u32, 20), rb.pop());
    try std.testing.expectEqual(@as(?u32, null), rb.pop());
}

test "overwrite on full" {
    var rb: RingBuffer(u8, 2) = .{};
    rb.push(1);
    rb.push(2);
    rb.push(3); // overwrites 1
    try std.testing.expect(rb.full());
    try std.testing.expectEqual(@as(?u8, 2), rb.pop());
    try std.testing.expectEqual(@as(?u8, 3), rb.pop());
}
