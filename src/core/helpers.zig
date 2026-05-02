const std = @import("std");
const types = @import("types.zig");
const Property = types.Property;

// ── Point math ───────────────────────────────────────────────────────────────

pub fn applyRotFlip(px: i32, py: i32, rot: u2, flip: bool, ox: i32, oy: i32) struct { x: i32, y: i32 } {
    const fx: i32 = if (flip) -px else px;
    return .{
        .x = ox + switch (rot) { 0 => fx, 1 => -py, 2 => -fx, 3 => py },
        .y = oy + switch (rot) { 0 => py, 1 => fx, 2 => -py, 3 => -fx },
    };
}

// ── Property lookup ──────────────────────────────────────────────────────────

pub fn findProp(props: []const Property, key: []const u8) ?[]const u8 {
    for (props) |p| if (std.mem.eql(u8, p.key, key)) return p.val;
    return null;
}

/// Returns true for instance prop keys that are structural (already encoded as
/// named fields) or EDA-tool metadata, and should not appear in user output.
pub fn isStructuralProp(key: []const u8) bool {
    const set = std.StaticStringMap(void).initComptime(.{
        .{ "name", {} }, .{ "sym", {} }, .{ "x", {} }, .{ "y", {} },
        .{ "rot", {} },  .{ "flip", {} }, .{ "format", {} }, .{ "template", {} },
        .{ "type", {} }, .{ "schematic", {} }, .{ "lab", {} }, .{ "net", {} },
        .{ "device_model", {} },
    });
    return set.has(key);
}

/// Returns true for sym-level metadata keys emitted as dedicated sections.
pub fn isSymPropMetadata(key: []const u8) bool {
    const set = std.StaticStringMap(void).initComptime(.{
        .{ "description", {} }, .{ "spice_prefix", {} },
        .{ "spice_format", {} }, .{ "spice_lib", {} },
    });
    if (set.has(key)) return true;
    return std.mem.startsWith(u8, key, "include") or
        std.mem.startsWith(u8, key, "ann.") or
        std.mem.startsWith(u8, key, "analysis.") or
        std.mem.startsWith(u8, key, "measure.");
}

// ── Bounding box ─────────────────────────────────────────────────────────────

pub const Bounds = struct {
    min_x: f32 = 0, max_x: f32 = 0,
    min_y: f32 = 0, max_y: f32 = 0,
    has_data: bool = false,

    pub fn bump(b: *Bounds, x: f32, y: f32) void {
        if (!b.has_data) {
            b.* = .{ .min_x = x, .max_x = x, .min_y = y, .max_y = y, .has_data = true };
            return;
        }
        if (x < b.min_x) b.min_x = x;
        if (x > b.max_x) b.max_x = x;
        if (y < b.min_y) b.min_y = y;
        if (y > b.max_y) b.max_y = y;
    }
};
