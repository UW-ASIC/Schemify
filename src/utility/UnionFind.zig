const std = @import("std");
const Allocator = std.mem.Allocator;

pub const UnionFind = struct {
    parent: std.AutoHashMapUnmanaged(u64, u64) = .{},
    a: Allocator,

    pub fn find(self: *UnionFind, x: u64) u64 {
        var cur = x;
        while (true) {
            const p = self.parent.get(cur) orelse return cur;
            if (p == cur) return cur;
            const gp = self.parent.get(p) orelse p;
            self.parent.put(self.a, cur, gp) catch {};
            cur = gp;
        }
    }

    pub fn makeSet(self: *UnionFind, x: u64) void {
        const r = self.parent.getOrPut(self.a, x) catch return;
        if (!r.found_existing) r.value_ptr.* = x;
    }

    pub fn unite(self: *UnionFind, x: u64, y: u64) void {
        const rx = self.find(x);
        const ry = self.find(y);
        if (rx != ry) self.parent.put(self.a, ry, rx) catch {};
    }
};
