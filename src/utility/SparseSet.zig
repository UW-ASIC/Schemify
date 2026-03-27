const std = @import("std");
const Allocator = std.mem.Allocator;

/// O(1) add/remove/contains with dense iteration over active elements.
/// Two-array architecture: dense packed array + sparse index array.
/// Membership check: `dense[sparse[id]] == id`.
pub const SparseSet = struct {
    const sentinel = std.math.maxInt(u32);

    dense: std.ArrayListUnmanaged(u32) = .{},
    sparse: std.ArrayListUnmanaged(u32) = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator) SparseSet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SparseSet) void {
        self.dense.deinit(self.allocator);
        self.sparse.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add an ID to the set. Idempotent -- adding an existing ID is a no-op.
    pub fn add(self: *SparseSet, id: u32) !void {
        if (self.contains(id)) return;
        // Ensure sparse capacity >= id+1, filling gaps with sentinel.
        while (self.sparse.items.len <= id)
            try self.sparse.append(self.allocator, sentinel);
        self.sparse.items[id] = @intCast(self.dense.items.len);
        try self.dense.append(self.allocator, id);
    }

    /// Remove an ID. No-op if not present.
    pub fn remove(self: *SparseSet, id: u32) void {
        if (!self.contains(id)) return;
        const dense_idx = self.sparse.items[id];
        const last_idx = self.dense.items.len - 1;
        if (dense_idx != last_idx) {
            const last_id = self.dense.items[last_idx];
            self.dense.items[dense_idx] = last_id;
            self.sparse.items[last_id] = dense_idx;
        }
        self.dense.items.len -= 1;
    }

    /// O(1) membership test via two-array invariant.
    pub fn contains(self: SparseSet, id: u32) bool {
        if (id >= self.sparse.items.len) return false;
        const dense_idx = self.sparse.items[id];
        return dense_idx < self.dense.items.len and
            self.dense.items[dense_idx] == id;
    }

    /// Number of active elements. O(1).
    pub fn count(self: SparseSet) usize {
        return self.dense.items.len;
    }

    /// Whether the set has no elements. O(1).
    pub fn isEmpty(self: SparseSet) bool {
        return self.dense.items.len == 0;
    }

    /// Contiguous slice of all active IDs. O(1).
    pub fn denseSlice(self: SparseSet) []const u32 {
        return self.dense.items;
    }

    /// Reset to empty. O(1) -- sparse entries become stale; contains handles this.
    pub fn clear(self: *SparseSet) void {
        self.dense.items.len = 0;
    }
};

// -- Tests --
const testing = std.testing;

test "SparseSet: add+contains" {
    var ss = SparseSet.init(testing.allocator);
    defer ss.deinit();
    try ss.add(5);
    try testing.expect(ss.contains(5));
    try testing.expect(!ss.contains(3));
}

test "SparseSet: add multiple, count, isEmpty" {
    var ss = SparseSet.init(testing.allocator);
    defer ss.deinit();
    try ss.add(5);
    try ss.add(10);
    try ss.add(3);
    try testing.expectEqual(@as(usize, 3), ss.count());
    try testing.expect(!ss.isEmpty());
}

test "SparseSet: add+remove+contains+count+isEmpty" {
    var ss = SparseSet.init(testing.allocator);
    defer ss.deinit();
    try ss.add(5);
    ss.remove(5);
    try testing.expect(!ss.contains(5));
    try testing.expectEqual(@as(usize, 0), ss.count());
    try testing.expect(ss.isEmpty());
}

test "SparseSet: remove middle, remaining accessible" {
    var ss = SparseSet.init(testing.allocator);
    defer ss.deinit();
    try ss.add(1);
    try ss.add(2);
    try ss.add(3);
    ss.remove(2);
    try testing.expect(ss.contains(1));
    try testing.expect(!ss.contains(2));
    try testing.expect(ss.contains(3));
    try testing.expectEqual(@as(usize, 2), ss.count());
}

test "SparseSet: denseSlice contiguity" {
    var ss = SparseSet.init(testing.allocator);
    defer ss.deinit();
    try ss.add(10);
    try ss.add(20);
    try ss.add(30);
    const slice = ss.denseSlice();
    try testing.expectEqual(@as(usize, 3), slice.len);
    // All three IDs present (order may vary due to swap-remove)
    var found: u32 = 0;
    for (slice) |id| {
        if (id == 10 or id == 20 or id == 30) found += 1;
    }
    try testing.expectEqual(@as(u32, 3), found);
}

test "SparseSet: clear resets to empty" {
    var ss = SparseSet.init(testing.allocator);
    defer ss.deinit();
    try ss.add(1);
    try ss.add(2);
    ss.clear();
    try testing.expectEqual(@as(usize, 0), ss.count());
    try testing.expect(ss.isEmpty());
    try testing.expect(!ss.contains(1));
    try testing.expect(!ss.contains(2));
}

test "SparseSet: idempotent add" {
    var ss = SparseSet.init(testing.allocator);
    defer ss.deinit();
    try ss.add(5);
    try ss.add(5);
    try testing.expectEqual(@as(usize, 1), ss.count());
}

test "SparseSet: remove non-existent is no-op" {
    var ss = SparseSet.init(testing.allocator);
    defer ss.deinit();
    ss.remove(99); // should not crash
    try ss.add(1);
    ss.remove(99);
    try testing.expectEqual(@as(usize, 1), ss.count());
}
