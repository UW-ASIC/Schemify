const std = @import("std");
const Allocator = std.mem.Allocator;

pub const StringRef = packed struct(u64) {
    offset: u32 = 0,
    len: u32 = 0,

    pub const empty: StringRef = .{};

    pub fn isEmpty(self: StringRef) bool {
        return self.len == 0;
    }

    pub fn eql(a: StringRef, b: StringRef) bool {
        return a.offset == b.offset and a.len == b.len;
    }
};

pub const StringPool = struct {
    bytes: std.ArrayListUnmanaged(u8) = .{},

    /// Append a string to the pool, return a StringRef to it.
    /// Empty strings return StringRef.empty (no bytes stored).
    pub fn add(self: *StringPool, a: Allocator, s: []const u8) Allocator.Error!StringRef {
        if (s.len == 0) return StringRef.empty;
        const offset: u32 = @intCast(self.bytes.items.len);
        try self.bytes.appendSlice(a, s);
        return .{ .offset = offset, .len = @intCast(s.len) };
    }

    /// Like add, but safe when `s` may alias the pool's own buffer.
    /// Copies to a temp buffer before appending to avoid invalidation on realloc.
    pub fn addSafe(self: *StringPool, a: Allocator, s: []const u8) Allocator.Error!StringRef {
        if (s.len == 0) return StringRef.empty;
        // Check if s aliases our buffer
        if (self.bytes.items.len > 0) {
            const pool_start = @intFromPtr(self.bytes.items.ptr);
            const pool_end = pool_start + self.bytes.items.len;
            const s_start = @intFromPtr(s.ptr);
            if (s_start >= pool_start and s_start < pool_end) {
                // s aliases our buffer — copy to temp allocation
                const tmp = try a.dupe(u8, s);
                defer a.free(tmp);
                return self.add(a, tmp);
            }
        }
        return self.add(a, s);
    }

    /// Resolve a StringRef to its slice. Returns "" for empty refs.
    pub fn get(self: *const StringPool, ref: StringRef) []const u8 {
        if (ref.len == 0) return "";
        return self.bytes.items[ref.offset..][0..ref.len];
    }

    /// Clone the entire pool: one alloc + one memcpy.
    pub fn clonePool(self: *const StringPool, a: Allocator) Allocator.Error!StringPool {
        var new: StringPool = .{};
        if (self.bytes.items.len > 0) {
            try new.bytes.resize(a, self.bytes.items.len);
            @memcpy(new.bytes.items, self.bytes.items);
        }
        return new;
    }

    /// Free the backing buffer. One free for ALL strings.
    pub fn deinit(self: *StringPool, a: Allocator) void {
        self.bytes.deinit(a);
        self.* = .{};
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "add/get round-trip" {
    const alloc = std.testing.allocator;
    var pool: StringPool = .{};
    defer pool.deinit(alloc);

    const r1 = try pool.add(alloc, "hello");
    const r2 = try pool.add(alloc, "world");
    const r3 = try pool.add(alloc, "zig is great");

    try std.testing.expectEqualStrings("hello", pool.get(r1));
    try std.testing.expectEqualStrings("world", pool.get(r2));
    try std.testing.expectEqualStrings("zig is great", pool.get(r3));
}

test "empty ref" {
    const alloc = std.testing.allocator;
    var pool: StringPool = .{};
    defer pool.deinit(alloc);

    try std.testing.expect(StringRef.empty.isEmpty());
    try std.testing.expectEqualStrings("", pool.get(StringRef.empty));

    const r = try pool.add(alloc, "");
    try std.testing.expect(r.isEmpty());
    try std.testing.expectEqualStrings("", pool.get(r));
}

test "clone independence" {
    const alloc = std.testing.allocator;
    var pool: StringPool = .{};
    defer pool.deinit(alloc);

    const r1 = try pool.add(alloc, "alpha");
    const r2 = try pool.add(alloc, "beta");

    var clone = try pool.clonePool(alloc);
    defer clone.deinit(alloc);

    // Clone returns same content.
    try std.testing.expectEqualStrings("alpha", clone.get(r1));
    try std.testing.expectEqualStrings("beta", clone.get(r2));

    // Mutate original — add more data so the backing buffer may reallocate.
    _ = try pool.add(alloc, "gamma");

    // Clone is unaffected.
    try std.testing.expectEqualStrings("alpha", clone.get(r1));
    try std.testing.expectEqualStrings("beta", clone.get(r2));
}

test "growth stability" {
    const alloc = std.testing.allocator;
    var pool: StringPool = .{};
    defer pool.deinit(alloc);

    var refs: [256]StringRef = undefined;
    for (0..256) |i| {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "string_{d}", .{i}) catch unreachable;
        refs[i] = try pool.add(alloc, s);
    }

    // All refs still resolve correctly after many insertions.
    for (0..256) |i| {
        var buf: [32]u8 = undefined;
        const expected = std.fmt.bufPrint(&buf, "string_{d}", .{i}) catch unreachable;
        try std.testing.expectEqualStrings(expected, pool.get(refs[i]));
    }
}

test "StringRef.eql" {
    const a: StringRef = .{ .offset = 0, .len = 5 };
    const b: StringRef = .{ .offset = 0, .len = 5 };
    const c: StringRef = .{ .offset = 5, .len = 3 };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(StringRef.empty.eql(StringRef.empty));
    try std.testing.expect(!StringRef.empty.eql(a));
}

test "add returns correct offsets" {
    const alloc = std.testing.allocator;
    var pool: StringPool = .{};
    defer pool.deinit(alloc);

    const r1 = try pool.add(alloc, "abc"); // 3 bytes at offset 0
    try std.testing.expectEqual(@as(u32, 0), r1.offset);
    try std.testing.expectEqual(@as(u32, 3), r1.len);

    const r2 = try pool.add(alloc, "de"); // 2 bytes at offset 3
    try std.testing.expectEqual(@as(u32, 3), r2.offset);
    try std.testing.expectEqual(@as(u32, 2), r2.len);

    const r3 = try pool.add(alloc, "f"); // 1 byte at offset 5
    try std.testing.expectEqual(@as(u32, 5), r3.offset);
    try std.testing.expectEqual(@as(u32, 1), r3.len);

    // Empty string produces no offset advance.
    const r4 = try pool.add(alloc, "");
    try std.testing.expect(r4.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), r4.offset);

    const r5 = try pool.add(alloc, "gh"); // 2 bytes at offset 6
    try std.testing.expectEqual(@as(u32, 6), r5.offset);
    try std.testing.expectEqual(@as(u32, 2), r5.len);
}
