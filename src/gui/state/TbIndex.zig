//! Reverse index: cell name → list of .chn_tb paths that instantiate it.
//! Maintained by AppState; updated on file open, save, and close.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const TbIndex = @This();

map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{},
alloc: Allocator,

pub fn init(a: Allocator) TbIndex {
    return .{ .alloc = a };
}

pub fn deinit(self: *TbIndex) void {
    var it = self.map.iterator();
    while (it.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
        for (entry.value_ptr.items) |path| self.alloc.free(path);
        entry.value_ptr.deinit(self.alloc);
    }
    self.map.deinit(self.alloc);
}

/// Record all instances in a testbench schematic under their normalized cell names.
pub fn indexTb(self: *TbIndex, tb_path: []const u8, sch: *const core.Schemify) void {
    const symbols = sch.instances.items(.symbol);
    for (symbols) |sym| {
        const cell = normalizeSymbol(sym);
        if (cell.len == 0) continue;
        const gop = self.map.getOrPut(self.alloc, cell) catch continue;
        if (!gop.found_existing) {
            const owned_key = self.alloc.dupe(u8, cell) catch {
                _ = self.map.remove(cell);
                continue;
            };
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{};
        }
        // Avoid duplicate path entries for the same testbench.
        for (gop.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, tb_path)) break;
        } else {
            const owned = self.alloc.dupe(u8, tb_path) catch continue;
            gop.value_ptr.append(self.alloc, owned) catch self.alloc.free(owned);
        }
    }
}

/// Remove all entries referencing this testbench path.
pub fn deindexTb(self: *TbIndex, tb_path: []const u8) void {
    var it = self.map.iterator();
    while (it.next()) |entry| {
        var i: usize = 0;
        while (i < entry.value_ptr.items.len) {
            if (std.mem.eql(u8, entry.value_ptr.items[i], tb_path)) {
                self.alloc.free(entry.value_ptr.swapRemove(i));
            } else {
                i += 1;
            }
        }
    }
}

/// Return all .chn_tb paths that instantiate this cell name (normalized).
pub fn testbenchesFor(self: *const TbIndex, cell_name: []const u8) []const []const u8 {
    const cell = normalizeSymbol(cell_name);
    if (self.map.get(cell)) |list| return list.items;
    return &.{};
}

/// Strip path prefix and known extensions to get a bare cell name.
/// "sky130_tests/inv.sym" → "inv", "chn/buffer" → "buffer", "nmos4" → "nmos4"
pub fn normalizeSymbol(sym: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, sym, '/')) |i|
        sym[i + 1 ..]
    else if (std.mem.lastIndexOfScalar(u8, sym, '\\')) |i|
        sym[i + 1 ..]
    else
        sym;
    const exts = [_][]const u8{ ".chn_prim", ".chn_tb", ".chn", ".sym" };
    inline for (exts) |ext| {
        if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    }
    return base;
}
