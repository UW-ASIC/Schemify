const std = @import("std");
const Allocator = std.mem.Allocator;

/// Packed generational handle: 20-bit index + 12-bit generation.
pub const Handle = packed struct {
    index: u20,
    generation: u12,

    pub const invalid = Handle{ .index = 0, .generation = 0 };

    pub fn eql(a: Handle, b: Handle) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }

    pub fn toRaw(self: Handle) u32 {
        return @bitCast(self);
    }

    pub fn fromRaw(raw: u32) Handle {
        return @bitCast(raw);
    }
};

comptime {
    std.debug.assert(@sizeOf(Handle) == 4);
}

/// Dense SlotMap: sparse->dense indirection for cache-optimal iteration.
pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct { dense_idx_or_next: u20, generation: u12 };
        const Meta = struct { slot_index: u20 };

        slots: std.ArrayListUnmanaged(Slot) = .{},
        dense: std.ArrayListUnmanaged(T) = .{},
        meta: std.ArrayListUnmanaged(Meta) = .{},
        free_head: ?u20 = null,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
            self.dense.deinit(self.allocator);
            self.meta.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn insert(self: *Self, value: T) !Handle {
            const slot_idx: u20 = if (self.free_head) |fi| blk: {
                const nxt = self.slots.items[fi].dense_idx_or_next;
                self.free_head = if (nxt == std.math.maxInt(u20)) null else nxt;
                break :blk fi;
            } else blk: {
                const idx: u20 = @intCast(self.slots.items.len);
                try self.slots.append(self.allocator, .{ .dense_idx_or_next = undefined, .generation = 1 });
                break :blk idx;
            };

            const dense_idx: u20 = @intCast(self.dense.items.len);
            try self.dense.append(self.allocator, value);
            try self.meta.append(self.allocator, .{ .slot_index = slot_idx });

            self.slots.items[slot_idx].dense_idx_or_next = dense_idx;
            return .{ .index = slot_idx, .generation = self.slots.items[slot_idx].generation };
        }

        pub fn remove(self: *Self, handle: Handle) ?T {
            if (!self.isValid(handle)) return null;
            const slot = &self.slots.items[handle.index];
            const dense_idx = slot.dense_idx_or_next;
            const last_dense: u20 = @intCast(self.dense.items.len - 1);
            const removed = self.dense.items[dense_idx];

            if (dense_idx != last_dense) {
                self.dense.items[dense_idx] = self.dense.items[last_dense];
                self.meta.items[dense_idx] = self.meta.items[last_dense];
                self.slots.items[self.meta.items[dense_idx].slot_index].dense_idx_or_next = dense_idx;
            }
            self.dense.items.len -= 1;
            self.meta.items.len -= 1;

            slot.generation +%= 1;
            slot.dense_idx_or_next = if (self.free_head) |fh| fh else std.math.maxInt(u20);
            self.free_head = handle.index;
            return removed;
        }

        pub fn get(self: Self, handle: Handle) ?T {
            if (!self.isValid(handle)) return null;
            return self.dense.items[self.slots.items[handle.index].dense_idx_or_next];
        }

        pub fn getPtr(self: *Self, handle: Handle) ?*T {
            if (!self.isValid(handle)) return null;
            return &self.dense.items[self.slots.items[handle.index].dense_idx_or_next];
        }

        pub fn values(self: Self) []T {
            return self.dense.items;
        }

        pub fn count(self: Self) usize {
            return self.dense.items.len;
        }

        fn isValid(self: Self, handle: Handle) bool {
            if (handle.index >= self.slots.items.len) return false;
            return self.slots.items[handle.index].generation == handle.generation;
        }
    };
}

/// Companion container keyed by the same Handle as a primary SlotMap.
pub fn SecondaryMap(comptime T: type) type {
    const Entry = struct { gen: u12, val: T };
    return struct {
        const Self = @This();
        entries: std.ArrayListUnmanaged(?Entry) = .{},
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn set(self: *Self, handle: Handle, value: T) !void {
            _ = self;
            _ = handle;
            _ = value;
            // STUB
        }
        pub fn get(self: Self, handle: Handle) ?T {
            _ = self;
            _ = handle;
            return null; // STUB
        }
        pub fn getPtr(self: *Self, handle: Handle) ?*T {
            _ = self;
            _ = handle;
            return null; // STUB
        }
        pub fn remove(self: *Self, handle: Handle) ?T {
            _ = self;
            _ = handle;
            return null; // STUB
        }
        pub fn contains(self: Self, handle: Handle) bool {
            _ = self;
            _ = handle;
            return false; // STUB
        }
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Handle is 4 bytes" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(Handle));
}

test "Handle.invalid has index=0, generation=0" {
    try testing.expectEqual(@as(u20, 0), Handle.invalid.index);
    try testing.expectEqual(@as(u12, 0), Handle.invalid.generation);
}

test "Handle.eql compares correctly" {
    const a = Handle{ .index = 1, .generation = 2 };
    const b = Handle{ .index = 1, .generation = 2 };
    const c = Handle{ .index = 1, .generation = 3 };
    try testing.expect(Handle.eql(a, b));
    try testing.expect(!Handle.eql(a, c));
}

test "Handle.toRaw/fromRaw roundtrips" {
    const h = Handle{ .index = 42, .generation = 7 };
    const raw = h.toRaw();
    const h2 = Handle.fromRaw(raw);
    try testing.expect(Handle.eql(h, h2));
}

test "insert returns valid handle, get retrieves value" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    const h = try sm.insert(42);
    try testing.expect(!Handle.eql(h, Handle.invalid));
    try testing.expectEqual(@as(?u32, 42), sm.get(h));
}

test "insert 3, remove middle, get returns null for removed" {
    var sm = SlotMap(u8).init(testing.allocator);
    defer sm.deinit();
    const ha = try sm.insert('A');
    const hb = try sm.insert('B');
    const hc = try sm.insert('C');
    const removed = sm.remove(hb);
    try testing.expectEqual(@as(?u8, 'B'), removed);
    try testing.expectEqual(@as(?u8, null), sm.get(hb));
    try testing.expectEqual(@as(?u8, 'A'), sm.get(ha));
    try testing.expectEqual(@as(?u8, 'C'), sm.get(hc));
}

test "slot reuse after remove" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    _ = try sm.insert(1);
    const hb = try sm.insert(2);
    _ = try sm.insert(3);
    _ = sm.remove(hb);
    const hd = try sm.insert(4);
    try testing.expectEqual(hb.index, hd.index);
    try testing.expect(hd.generation > hb.generation);
    try testing.expectEqual(@as(?u32, 4), sm.get(hd));
}

test "values() returns contiguous slice" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    _ = try sm.insert(10);
    _ = try sm.insert(20);
    _ = try sm.insert(30);
    const vals = sm.values();
    try testing.expectEqual(@as(usize, 3), vals.len);
}

test "remove last element (no swap)" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    const ha = try sm.insert(1);
    const hb = try sm.insert(2);
    _ = sm.remove(hb);
    try testing.expectEqual(@as(?u32, 1), sm.get(ha));
    try testing.expectEqual(@as(usize, 1), sm.count());
}

test "generation wraps after 4095 reinsertions" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    var h = try sm.insert(0);
    for (0..4095) |i| {
        _ = sm.remove(h);
        h = try sm.insert(@intCast(i + 1));
    }
    // generation should have wrapped: started at 1, +4095 wraps mod 4096
    try testing.expectEqual(@as(u12, 0), h.generation);
}

test "getPtr returns mutable pointer" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    const h = try sm.insert(10);
    const ptr = sm.getPtr(h).?;
    ptr.* = 99;
    try testing.expectEqual(@as(?u32, 99), sm.get(h));
}

test "count returns live elements" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    try testing.expectEqual(@as(usize, 0), sm.count());
    const h = try sm.insert(1);
    try testing.expectEqual(@as(usize, 1), sm.count());
    _ = try sm.insert(2);
    try testing.expectEqual(@as(usize, 2), sm.count());
    _ = sm.remove(h);
    try testing.expectEqual(@as(usize, 1), sm.count());
}

test "SecondaryMap set+get roundtrip" {
    var sm = SlotMap(f32).init(testing.allocator);
    defer sm.deinit();
    var sec = SecondaryMap(bool).init(testing.allocator);
    defer sec.deinit();
    const h = try sm.insert(1.0);
    try sec.set(h, true);
    try testing.expectEqual(@as(?bool, true), sec.get(h));
    try testing.expect(sec.contains(h));
}

test "SecondaryMap rejects stale handle" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    var sec = SecondaryMap(u8).init(testing.allocator);
    defer sec.deinit();
    const h = try sm.insert(1);
    try sec.set(h, 42);
    _ = sm.remove(h); // generation incremented
    try testing.expectEqual(@as(?u8, null), sec.get(h));
    try testing.expect(!sec.contains(h));
}

test "SecondaryMap remove" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    var sec = SecondaryMap(u32).init(testing.allocator);
    defer sec.deinit();
    const h = try sm.insert(1);
    try sec.set(h, 100);
    const old = sec.remove(h);
    try testing.expectEqual(@as(?u32, 100), old);
    try testing.expectEqual(@as(?u32, null), sec.get(h));
}
