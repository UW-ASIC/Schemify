//! ConnectivityResolver — union-find wire clustering, net naming, and propag=0
//! cascade logic.
//!
//! Public entry point: `resolveConnectivity` consumes a partially-built
//! `Netlister` (wires + devices already copied in) and populates:
//!   - `out.net_names`
//!   - `out.device_nets`
//!   - `out.global_nets`
//!
//! All helpers in this file are pure functions that operate on the types
//! defined in `FeatureModel.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const sch = @import("../Schemify.zig");
const fm = @import("FeatureModel.zig");

// ── Coordinate helpers ────────────────────────────────────────────────────── //

pub fn symPtKey(x: i32, y: i32) u64 {
    return sch.NetMap.pointKey(x, y);
}

/// Round f64 → i32.
pub fn f2i(v: f64) i32 {
    return @intFromFloat(@round(v));
}

pub fn applyRotFlip(px: i32, py: i32, rot: u2, flip: bool, ox: i32, oy: i32) struct { x: i32, y: i32 } {
    const fx: i32 = if (flip) -px else px;
    const fy: i32 = py;
    const rx: i32 = switch (rot) {
        0 => fx,
        1 => -fy,
        2 => -fx,
        3 => fy,
    };
    const ry: i32 = switch (rot) {
        0 => fy,
        1 => fx,
        2 => -fy,
        3 => -fx,
    };
    return .{ .x = ox + rx, .y = oy + ry };
}

// ── Net-name helpers ──────────────────────────────────────────────────────── //

/// Returns the auto-net numeric suffix if `name` is an auto-generated net
/// ("netN" or "_nN"), or null if it is a user-defined name.
pub fn autoNetIndex(name: []const u8) ?u32 {
    if (name.len > 3 and std.mem.eql(u8, name[0..3], "net")) {
        return std.fmt.parseInt(u32, name[3..], 10) catch null;
    }
    if (name.len > 2 and name[0] == '_' and name[1] == 'n') {
        return std.fmt.parseInt(u32, name[2..], 10) catch null;
    }
    return null;
}

// ── Sorted root-name list helpers ─────────────────────────────────────────── //

pub const RootName = struct { root: u64, name: []const u8 };

pub fn rnFind(items: []const RootName, root: u64) ?usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].root < root) lo = mid + 1 else hi = mid;
    }
    return if (lo < items.len and items[lo].root == root) lo else null;
}

pub fn rnInsert(items: *List(RootName), alloc_: Allocator, root: u64, name: []const u8) void {
    var lo: usize = 0;
    var hi: usize = items.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items.items[mid].root < root) lo = mid + 1 else hi = mid;
    }
    items.insert(alloc_, lo, .{ .root = root, .name = name }) catch {};
}
