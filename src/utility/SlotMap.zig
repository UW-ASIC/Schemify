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
            _ = self;
            _ = value;
            return Handle.invalid; // STUB -- will fail tests
        }

        pub fn remove(self: *Self, handle: Handle) ?T {
            _ = self;
            _ = handle;
            return null; // STUB
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

        pub fn values(self: Self) []T {
            return self.dense.items;
        }

        pub fn count(self: Self) usize {
            return self.dense.items.len;
        }

        fn isValid(self: Self, handle: Handle) bool {
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
