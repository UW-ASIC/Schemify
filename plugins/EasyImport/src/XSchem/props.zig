// props.zig - PropertyTokenizer for XSchem key=value property parsing.
// STUB: TDD RED phase -- tests should fail against this.

const std = @import("std");
const types = @import("types.zig");
const Prop = types.Prop;

pub const PropertyTokenizer = struct {
    source: []const u8,
    pos: usize,

    pub fn init(source: []const u8) PropertyTokenizer {
        return .{ .source = source, .pos = 0 };
    }

    pub fn next(self: *PropertyTokenizer) ?struct { key: []const u8, value: []const u8, single_quoted: bool } {
        _ = self;
        // STUB: always returns null (no tokens)
        return null;
    }
};

/// Parse a property string into Prop array. All strings are arena-duped.
pub fn parseProps(arena: std.mem.Allocator, source: []const u8) !struct { props: []const Prop, count: u16 } {
    _ = arena;
    _ = source;
    // STUB: returns empty
    return .{ .props = &.{}, .count = 0 };
}
