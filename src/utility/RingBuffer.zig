const std = @import("std");

/// Power-of-two fixed-capacity FIFO ring buffer with branchless wrap.
/// Uses unbounded head/tail with wrapping subtraction for unambiguous empty vs full.
/// No Allocator needed -- buffer is comptime-sized inline array.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    comptime {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
    }
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        buf: [capacity]T = undefined,
        head: usize = 0, // next write position (unbounded)
        tail: usize = 0, // next read position (unbounded)

        /// Push an item. Returns error.BufferFull if at capacity.
        pub fn push(self: *Self, item: T) error{BufferFull}!void {
            if (self.len() == capacity) return error.BufferFull;
            self.buf[self.head & mask] = item;
            self.head +%= 1;
        }

        /// Pop the oldest item. Returns null if empty.
        pub fn pop(self: *Self) ?T {
            if (self.len() == 0) return null;
            const item = self.buf[self.tail & mask];
            self.tail +%= 1;
            return item;
        }

        /// Push an item, evicting the oldest if the buffer is full.
        pub fn pushOverwrite(self: *Self, item: T) void {
            if (self.len() == capacity) self.tail +%= 1;
            self.buf[self.head & mask] = item;
            self.head +%= 1;
        }

        /// Current number of items. O(1) via wrapping subtraction.
        pub fn len(self: Self) usize {
            return self.head -% self.tail;
        }

        pub fn isEmpty(self: Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: Self) bool {
            return self.len() == capacity;
        }

        /// Peek at the next item to be popped without removing it.
        pub fn peek(self: Self) ?T {
            if (self.len() == 0) return null;
            return self.buf[self.tail & mask];
        }

        /// Peek at the n-th item from the tail (0 = oldest).
        pub fn peekIndex(self: Self, n: usize) ?T {
            if (n >= self.len()) return null;
            return self.buf[(self.tail +% n) & mask];
        }
    };
}

// -- Tests --
const testing = std.testing;

test "RingBuffer: push 1, pop returns it, pop again null" {
    var rb = RingBuffer(u32, 4){};
    try rb.push(42);
    try testing.expectEqual(@as(?u32, 42), rb.pop());
    try testing.expectEqual(@as(?u32, null), rb.pop());
}

test "RingBuffer: push 4 into cap-4, len=4, push 5th returns BufferFull" {
    var rb = RingBuffer(u32, 4){};
    try rb.push(1);
    try rb.push(2);
    try rb.push(3);
    try rb.push(4);
    try testing.expectEqual(@as(usize, 4), rb.len());
    try testing.expectError(error.BufferFull, rb.push(5));
}

test "RingBuffer: wrap-around FIFO order" {
    var rb = RingBuffer(u32, 4){};
    try rb.push(1);
    try rb.push(2);
    try rb.push(3);
    try rb.push(4);
    _ = rb.pop(); // remove 1
    _ = rb.pop(); // remove 2
    try rb.push(5);
    try rb.push(6);
    // Should get 3, 4, 5, 6 in FIFO order
    try testing.expectEqual(@as(?u32, 3), rb.pop());
    try testing.expectEqual(@as(?u32, 4), rb.pop());
    try testing.expectEqual(@as(?u32, 5), rb.pop());
    try testing.expectEqual(@as(?u32, 6), rb.pop());
}

test "RingBuffer: pushOverwrite evicts oldest" {
    var rb = RingBuffer(u8, 4){};
    try rb.push('A');
    try rb.push('B');
    try rb.push('C');
    try rb.push('D');
    rb.pushOverwrite('E');
    // pop sequence should be B, C, D, E
    try testing.expectEqual(@as(?u8, 'B'), rb.pop());
    try testing.expectEqual(@as(?u8, 'C'), rb.pop());
    try testing.expectEqual(@as(?u8, 'D'), rb.pop());
    try testing.expectEqual(@as(?u8, 'E'), rb.pop());
}

test "RingBuffer: len, isEmpty, isFull" {
    var rb = RingBuffer(u32, 4){};
    try testing.expectEqual(@as(usize, 0), rb.len());
    try testing.expect(rb.isEmpty());
    try testing.expect(!rb.isFull());
    try rb.push(1);
    try rb.push(2);
    try rb.push(3);
    try rb.push(4);
    try testing.expectEqual(@as(usize, 4), rb.len());
    try testing.expect(!rb.isEmpty());
    try testing.expect(rb.isFull());
}

test "RingBuffer: peek and peekIndex" {
    var rb = RingBuffer(u32, 4){};
    try testing.expectEqual(@as(?u32, null), rb.peek());
    try rb.push(10);
    try rb.push(20);
    try rb.push(30);
    try testing.expectEqual(@as(?u32, 10), rb.peek());
    try testing.expectEqual(@as(?u32, 10), rb.peekIndex(0));
    try testing.expectEqual(@as(?u32, 20), rb.peekIndex(1));
    try testing.expectEqual(@as(?u32, 30), rb.peekIndex(2));
    try testing.expectEqual(@as(?u32, null), rb.peekIndex(3));
}
