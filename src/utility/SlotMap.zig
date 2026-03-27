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
    pub fn toRaw(self: Handle) u32 { return @bitCast(self); }
    pub fn fromRaw(raw: u32) Handle { return @bitCast(raw); }
};

comptime { std.debug.assert(@sizeOf(Handle) == 4); }

/// Dense SlotMap: sparse->dense indirection for cache-optimal iteration.
pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();
        const Slot = struct { dense_idx_or_next: u20, generation: u12 };
        const Meta = struct { slot_index: u20 };
        const sentinel = std.math.maxInt(u20);

        slots: std.ArrayListUnmanaged(Slot) = .{},
        dense: std.ArrayListUnmanaged(T) = .{},
        meta: std.ArrayListUnmanaged(Meta) = .{},
        free_head: ?u20 = null,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self { return .{ .allocator = allocator }; }

        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
            self.dense.deinit(self.allocator);
            self.meta.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn insert(self: *Self, value: T) !Handle {
            const slot_idx: u20 = if (self.free_head) |fi| blk: {
                const nxt = self.slots.items[fi].dense_idx_or_next;
                self.free_head = if (nxt == sentinel) null else nxt;
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
            const di = slot.dense_idx_or_next;
            const last: u20 = @intCast(self.dense.items.len - 1);
            const removed = self.dense.items[di];
            if (di != last) {
                self.dense.items[di] = self.dense.items[last];
                self.meta.items[di] = self.meta.items[last];
                self.slots.items[self.meta.items[di].slot_index].dense_idx_or_next = di;
            }
            self.dense.items.len -= 1;
            self.meta.items.len -= 1;
            slot.generation +%= 1;
            slot.dense_idx_or_next = if (self.free_head) |fh| fh else sentinel;
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

        pub fn values(self: Self) []T { return self.dense.items; }
        pub fn count(self: Self) usize { return self.dense.items.len; }

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

        pub fn init(allocator: Allocator) Self { return .{ .allocator = allocator }; }
        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn set(self: *Self, handle: Handle, value: T) !void {
            const needed = @as(usize, handle.index) + 1;
            while (self.entries.items.len < needed)
                try self.entries.append(self.allocator, null);
            self.entries.items[handle.index] = .{ .gen = handle.generation, .val = value };
        }
        pub fn get(self: Self, handle: Handle) ?T {
            if (handle.index >= self.entries.items.len) return null;
            const e = self.entries.items[handle.index] orelse return null;
            return if (e.gen == handle.generation) e.val else null;
        }
        pub fn getPtr(self: *Self, handle: Handle) ?*T {
            if (handle.index >= self.entries.items.len) return null;
            const e = &(self.entries.items[handle.index] orelse return null);
            return if (e.gen == handle.generation) &e.val else null;
        }
        pub fn remove(self: *Self, handle: Handle) ?T {
            if (handle.index >= self.entries.items.len) return null;
            const e = self.entries.items[handle.index] orelse return null;
            if (e.gen != handle.generation) return null;
            self.entries.items[handle.index] = null;
            return e.val;
        }
        pub fn contains(self: Self, handle: Handle) bool { return self.get(handle) != null; }
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "Handle: size, invalid, eql, toRaw/fromRaw" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(Handle));
    try testing.expectEqual(@as(u20, 0), Handle.invalid.index);
    try testing.expectEqual(@as(u12, 0), Handle.invalid.generation);
    const a = Handle{ .index = 1, .generation = 2 };
    try testing.expect(Handle.eql(a, Handle{ .index = 1, .generation = 2 }));
    try testing.expect(!Handle.eql(a, Handle{ .index = 1, .generation = 3 }));
    try testing.expect(Handle.eql(a, Handle.fromRaw(a.toRaw())));
}

test "SlotMap: insert returns valid handle, get retrieves value" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    const h = try sm.insert(42);
    try testing.expect(!Handle.eql(h, Handle.invalid));
    try testing.expectEqual(@as(?u32, 42), sm.get(h));
}

test "SlotMap: insert 3, remove middle, verify A+C accessible" {
    var sm = SlotMap(u8).init(testing.allocator);
    defer sm.deinit();
    const ha = try sm.insert('A');
    const hb = try sm.insert('B');
    const hc = try sm.insert('C');
    try testing.expectEqual(@as(?u8, 'B'), sm.remove(hb));
    try testing.expectEqual(@as(?u8, null), sm.get(hb));
    try testing.expectEqual(@as(?u8, 'A'), sm.get(ha));
    try testing.expectEqual(@as(?u8, 'C'), sm.get(hc));
}

test "SlotMap: slot reuse after remove" {
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

test "SlotMap: values() contiguous, remove last, count" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    const ha = try sm.insert(10);
    _ = try sm.insert(20);
    const hc = try sm.insert(30);
    try testing.expectEqual(@as(usize, 3), sm.values().len);
    _ = sm.remove(hc);
    try testing.expectEqual(@as(?u32, 10), sm.get(ha));
    try testing.expectEqual(@as(usize, 2), sm.count());
}

test "SlotMap: generation wraps after 4095 reinsertions" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    var h = try sm.insert(0);
    for (0..4095) |i| {
        _ = sm.remove(h);
        h = try sm.insert(@intCast(i + 1));
    }
    try testing.expectEqual(@as(u12, 0), h.generation);
}

test "SlotMap: getPtr returns mutable pointer" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    const h = try sm.insert(10);
    sm.getPtr(h).?.* = 99;
    try testing.expectEqual(@as(?u32, 99), sm.get(h));
}

test "SlotMap: count tracks live elements" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();
    try testing.expectEqual(@as(usize, 0), sm.count());
    const h = try sm.insert(1);
    _ = try sm.insert(2);
    try testing.expectEqual(@as(usize, 2), sm.count());
    _ = sm.remove(h);
    try testing.expectEqual(@as(usize, 1), sm.count());
}

test "SecondaryMap: set+get, stale rejection, remove" {
    var sm = SlotMap(f32).init(testing.allocator);
    defer sm.deinit();
    var sec = SecondaryMap(u8).init(testing.allocator);
    defer sec.deinit();
    // set+get roundtrip
    const h = try sm.insert(1.0);
    try sec.set(h, 42);
    try testing.expectEqual(@as(?u8, 42), sec.get(h));
    try testing.expect(sec.contains(h));
    // stale handle rejection: remove+reinsert gives new generation
    _ = sm.remove(h);
    const h2 = try sm.insert(2.0);
    try testing.expectEqual(h.index, h2.index);
    try testing.expect(h2.generation != h.generation);
    try testing.expectEqual(@as(?u8, null), sec.get(h2));
    try testing.expect(!sec.contains(h2));
    // explicit remove
    try sec.set(h2, 99);
    try testing.expectEqual(@as(?u8, 99), sec.remove(h2));
    try testing.expectEqual(@as(?u8, null), sec.get(h2));
}
