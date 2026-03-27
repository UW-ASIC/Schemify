const std = @import("std");

/// Fixed-size block allocator with intrusive free list.
/// O(1) alloc/free, zero fragmentation for same-size blocks.
/// No Allocator needed -- buffer is comptime-sized inline array.
pub fn Pool(comptime T: type, comptime max_count: usize) type {
    return struct {
        const Self = @This();
        const FreeNode = struct { next: ?*FreeNode };

        comptime {
            std.debug.assert(@sizeOf(T) >= @sizeOf(FreeNode));
        }

        buf: [max_count]T = undefined,
        free_head: ?*FreeNode = null,
        allocated: usize = 0,

        /// Initialize the pool with all blocks chained into the free list.
        /// Iterates backward so that alloc returns blocks in order (block 0 first).
        pub fn init() Self {
            var self = Self{};
            var i: usize = max_count;
            while (i > 0) {
                i -= 1;
                const node: *FreeNode = @ptrCast(@alignCast(&self.buf[i]));
                node.next = self.free_head;
                self.free_head = node;
            }
            return self;
        }

        /// Allocate a block from the free list. O(1). Returns null if exhausted.
        pub fn alloc(self: *Self) ?*T {
            const node = self.free_head orelse return null;
            self.free_head = node.next;
            self.allocated += 1;
            return @ptrCast(@alignCast(node));
        }

        /// Return a block to the free list. O(1).
        pub fn free(self: *Self, ptr: *T) void {
            const node: *FreeNode = @ptrCast(@alignCast(ptr));
            node.next = self.free_head;
            self.free_head = node;
            self.allocated -= 1;
        }

        /// Number of currently allocated blocks.
        pub fn allocatedCount(self: Self) usize {
            return self.allocated;
        }

        /// Number of available blocks.
        pub fn freeCount(self: Self) usize {
            return max_count - self.allocated;
        }
    };
}

// -- Tests --
const testing = std.testing;

// Use a struct large enough to hold a FreeNode (pointer-sized)
const TestBlock = struct { data: [16]u8 = undefined };

test "Pool: alloc returns valid pointer, write+read works" {
    var pool = Pool(TestBlock, 4).init();
    const ptr = pool.alloc() orelse return error.TestUnexpectedResult;
    ptr.data[0] = 42;
    try testing.expectEqual(@as(u8, 42), ptr.data[0]);
    pool.free(ptr);
}

test "Pool: exhaust capacity returns null" {
    var pool = Pool(TestBlock, 2).init();
    const a = pool.alloc();
    const b = pool.alloc();
    try testing.expect(a != null);
    try testing.expect(b != null);
    try testing.expectEqual(@as(?*TestBlock, null), pool.alloc());
}

test "Pool: free then alloc reuses block" {
    var pool = Pool(TestBlock, 2).init();
    const a = pool.alloc().?;
    pool.free(a);
    const b = pool.alloc().?;
    try testing.expectEqual(@intFromPtr(a), @intFromPtr(b));
}

test "Pool: alloc 3, free middle, alloc returns freed block" {
    var pool = Pool(TestBlock, 4).init();
    _ = pool.alloc(); // 0
    const mid = pool.alloc().?; // 1
    _ = pool.alloc(); // 2
    pool.free(mid);
    const reused = pool.alloc().?;
    try testing.expectEqual(@intFromPtr(mid), @intFromPtr(reused));
}

test "Pool: allocatedCount tracks correctly" {
    var pool = Pool(TestBlock, 4).init();
    try testing.expectEqual(@as(usize, 0), pool.allocatedCount());
    const a = pool.alloc().?;
    _ = pool.alloc();
    try testing.expectEqual(@as(usize, 2), pool.allocatedCount());
    try testing.expectEqual(@as(usize, 2), pool.freeCount());
    pool.free(a);
    try testing.expectEqual(@as(usize, 1), pool.allocatedCount());
    try testing.expectEqual(@as(usize, 3), pool.freeCount());
}

test "Pool: full reuse after free-all" {
    var pool = Pool(TestBlock, 3).init();
    var ptrs: [3]*TestBlock = undefined;
    for (&ptrs) |*p| p.* = pool.alloc().?;
    try testing.expectEqual(@as(?*TestBlock, null), pool.alloc());
    for (&ptrs) |p| pool.free(p);
    // All 3 should be allocable again
    for (&ptrs) |*p| p.* = pool.alloc().?;
    try testing.expectEqual(@as(usize, 3), pool.allocatedCount());
}
