const std = @import("std");
const Allocator = std.mem.Allocator;

/// Inline+spill vector: stores <=N items with zero heap allocation,
/// spills to heap when exceeded. Like LLVM SmallVector.
pub fn SmallVec(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();

        buf: [N]T = undefined,
        heap_ptr: ?[*]T = null,
        heap_cap: usize = 0,
        len: usize = 0,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            if (self.heap_ptr) |hp| {
                self.allocator.free(hp[0..self.heap_cap]);
            }
            self.* = undefined;
        }

        pub fn append(self: *Self, item: T) Allocator.Error!void {
            if (self.len < N) {
                // Inline path: store directly in buf
                self.buf[self.len] = item;
            } else if (self.heap_ptr == null) {
                // First spill: allocate heap, copy inline data
                const new_cap = N * 2;
                const heap = try self.allocator.alloc(T, new_cap);
                @memcpy(heap[0..N], &self.buf);
                heap[N] = item;
                self.heap_ptr = heap.ptr;
                self.heap_cap = new_cap;
            } else {
                // Already on heap: grow if needed
                if (self.len == self.heap_cap) {
                    const new_cap = self.heap_cap * 2;
                    const old = self.heap_ptr.?[0..self.heap_cap];
                    const heap = try self.allocator.realloc(old, new_cap);
                    self.heap_ptr = heap.ptr;
                    self.heap_cap = new_cap;
                }
                self.heap_ptr.?[self.len] = item;
            }
            self.len += 1;
        }

        pub fn items(self: *const Self) []const T {
            if (self.heap_ptr) |hp| return hp[0..self.len];
            return self.buf[0..self.len];
        }

        pub fn itemsMut(self: *Self) []T {
            if (self.heap_ptr) |hp| return hp[0..self.len];
            return self.buf[0..self.len];
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            if (self.heap_ptr) |hp| return hp[self.len];
            return self.buf[self.len];
        }

        pub fn get(self: *const Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.items()[index];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn capacity(self: *const Self) usize {
            if (self.heap_ptr != null) return self.heap_cap;
            return N;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "SmallVec: inline storage (no heap alloc)" {
    var sv = SmallVec(u32, 4).init(testing.allocator);
    defer sv.deinit();
    try sv.append(10);
    try sv.append(20);
    try sv.append(30);
    try sv.append(40);
    try testing.expectEqual(@as(usize, 4), sv.len);
    try testing.expectEqual(null, sv.heap_ptr);
    const s = sv.items();
    try testing.expectEqual(@as(u32, 10), s[0]);
    try testing.expectEqual(@as(u32, 20), s[1]);
    try testing.expectEqual(@as(u32, 30), s[2]);
    try testing.expectEqual(@as(u32, 40), s[3]);
}

test "SmallVec: heap spill on N+1" {
    var sv = SmallVec(u32, 4).init(testing.allocator);
    defer sv.deinit();
    for (0..5) |i| try sv.append(@intCast(i));
    try testing.expectEqual(@as(usize, 5), sv.len);
    try testing.expect(sv.heap_ptr != null);
    const s = sv.items();
    for (0..5) |i| try testing.expectEqual(@as(u32, @intCast(i)), s[i]);
}

test "SmallVec: append N+5 items, all accessible" {
    var sv = SmallVec(u32, 4).init(testing.allocator);
    defer sv.deinit();
    for (0..9) |i| try sv.append(@intCast(i));
    try testing.expectEqual(@as(usize, 9), sv.len);
    const s = sv.items();
    for (0..9) |i| try testing.expectEqual(@as(u32, @intCast(i)), s[i]);
}

test "SmallVec: pop removes last item" {
    var sv = SmallVec(u32, 4).init(testing.allocator);
    defer sv.deinit();
    try sv.append(1);
    try sv.append(2);
    try sv.append(3);
    try testing.expectEqual(@as(?u32, 3), sv.pop());
    try testing.expectEqual(@as(usize, 2), sv.len);
    try testing.expectEqual(@as(?u32, 2), sv.pop());
    try testing.expectEqual(@as(?u32, 1), sv.pop());
    try testing.expectEqual(@as(?u32, null), sv.pop());
}

test "SmallVec: clear resets to empty" {
    var sv = SmallVec(u32, 4).init(testing.allocator);
    defer sv.deinit();
    try sv.append(1);
    try sv.append(2);
    sv.clear();
    try testing.expectEqual(@as(usize, 0), sv.len);
    try testing.expectEqual(@as(usize, 0), sv.items().len);
    // Can re-append after clear
    try sv.append(42);
    try testing.expectEqual(@as(usize, 1), sv.len);
    try testing.expectEqual(@as(u32, 42), sv.items()[0]);
}

test "SmallVec: items() returns empty slice when empty" {
    var sv = SmallVec(u32, 4).init(testing.allocator);
    defer sv.deinit();
    try testing.expectEqual(@as(usize, 0), sv.items().len);
}

test "SmallVec: get returns element or null for out of bounds" {
    var sv = SmallVec(u32, 4).init(testing.allocator);
    defer sv.deinit();
    try sv.append(10);
    try sv.append(20);
    try testing.expectEqual(@as(?u32, 10), sv.get(0));
    try testing.expectEqual(@as(?u32, 20), sv.get(1));
    try testing.expectEqual(@as(?u32, null), sv.get(2));
    try testing.expectEqual(@as(?u32, null), sv.get(100));
}
