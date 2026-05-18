//! Bus name parsing utilities.
//!
//! Parses bracket notation: `data[7:0]` → base="data", hi=7, lo=0

const std = @import("std");

pub const BusRange = struct {
    base: []const u8,
    hi: u16,
    lo: u16,

    pub fn width(self: BusRange) u16 {
        return if (self.hi >= self.lo) self.hi - self.lo + 1 else self.lo - self.hi + 1;
    }
};

/// Parse a bus name with bracket notation: `name[hi:lo]` or `name[idx]`.
/// Returns null if the name is not a valid bus reference.
pub fn parseBusName(name: []const u8) ?BusRange {
    const bracket_start = std.mem.indexOfScalar(u8, name, '[') orelse return null;
    const bracket_end = std.mem.lastIndexOfScalar(u8, name, ']') orelse return null;
    if (bracket_end <= bracket_start + 1) return null;

    const base = name[0..bracket_start];
    if (base.len == 0) return null;

    const inner = name[bracket_start + 1 .. bracket_end];
    if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
        const hi = std.fmt.parseUnsigned(u16, inner[0..colon], 10) catch return null;
        const lo = std.fmt.parseUnsigned(u16, inner[colon + 1 ..], 10) catch return null;
        return .{ .base = base, .hi = hi, .lo = lo };
    } else {
        const idx = std.fmt.parseUnsigned(u16, inner, 10) catch return null;
        return .{ .base = base, .hi = idx, .lo = idx };
    }
}

test "parseBusName basic" {
    const r = parseBusName("data[7:0]") orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("data", r.base);
    try std.testing.expectEqual(@as(u16, 7), r.hi);
    try std.testing.expectEqual(@as(u16, 0), r.lo);
    try std.testing.expectEqual(@as(u16, 8), r.width());
}

test "parseBusName single bit" {
    const r = parseBusName("addr[3]") orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("addr", r.base);
    try std.testing.expectEqual(@as(u16, 3), r.hi);
    try std.testing.expectEqual(@as(u16, 3), r.lo);
    try std.testing.expectEqual(@as(u16, 1), r.width());
}

test "parseBusName not a bus" {
    try std.testing.expect(parseBusName("clk") == null);
    try std.testing.expect(parseBusName("") == null);
    try std.testing.expect(parseBusName("a[]") == null);
    try std.testing.expect(parseBusName("[3:0]") == null);
}
