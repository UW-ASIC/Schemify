const std = @import("std");

/// Fixed-capacity FIFO ring buffer. Zero heap allocations.
/// CAP must be a power of 2 for fast modulo via bitmasking.
pub fn RingBuffer(comptime T: type, comptime CAP: usize) type {
    return struct {
        buf:  [CAP]T = undefined,
        head: usize  = 0,
        len:  usize  = 0,

        const Self = @This();
        const MASK = CAP - 1;

        comptime {
            std.debug.assert(CAP > 0 and (CAP & MASK) == 0); // must be power of 2
        }

        pub fn push(self: *Self, item: T) error{Full}!void {
            if (self.len == CAP) return error.Full;
            self.buf[(self.head + self.len) & MASK] = item;
            self.len += 1;
        }

        pub fn pushOverwrite(self: *Self, item: T) void {
            if (self.len == CAP) {
                // overwrite oldest
                self.buf[self.head & MASK] = item;
                self.head = (self.head + 1) & MASK;
            } else {
                self.buf[(self.head + self.len) & MASK] = item;
                self.len += 1;
            }
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.buf[self.head & MASK];
            self.head = (self.head + 1) & MASK;
            self.len -= 1;
            return item;
        }

        pub fn peek(self: *const Self) ?T {
            if (self.len == 0) return null;
            return self.buf[self.head & MASK];
        }

        pub fn isEmpty(self: *const Self) bool { return self.len == 0; }
        pub fn isFull(self:  *const Self) bool { return self.len == CAP; }

        test "ring buffer basic" {
            var rb = Self{};
            try rb.push(1);
            try rb.push(2);
            try std.testing.expectEqual(@as(?T, 1), rb.pop());
            try std.testing.expectEqual(@as(?T, 2), rb.pop());
            try std.testing.expectEqual(@as(?T, null), rb.pop());
        }
    };
}
