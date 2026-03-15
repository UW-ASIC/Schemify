//! Geometry primitives for the CHN DOD schematic format.
//!
//! All coordinate values are in schematic grid units (integers).
//! XSchem f64 coordinates are rounded to i32 during convertToSchemify.

const std = @import("std");

/// 2D integer coordinate in schematic grid units.
/// `@Vector(2, i32)` — supports +, -, * directly; compiler auto-vectorises loops.
/// Access components as `p[0]` (x) and `p[1]` (y).
pub const Point = @Vector(2, i32);

/// Compact 8-bit transform encoding (rotation + flip) for Instance placement.
/// rot: 0–3 quarter-turn CW steps; flip: horizontal mirror before rotation.
pub const Transform = packed struct {
    rot: u2 = 0,
    flip: bool = false,
    _pad: u5 = 0,

    pub const identity = Transform{};

    /// Chain two transforms so parent→child placement composes correctly.
    pub fn compose(self: Transform, other: Transform) Transform {
        var result = self;
        if (other.flip) result.flip = !result.flip;
        result.rot = if (result.flip)
            self.rot -% other.rot
        else
            self.rot +% other.rot;
        return result;
    }
};

pub const TransformOp = enum {
    move,
    rotate_cw,
    rotate_ccw,
    flip_x,
    flip_y,
};

pub const PinDir = enum(u8) {
    input,
    output,
    inout,
    power,
    ground,

    /// Map a raw CHN direction string to a typed enum at parse time.
    pub fn fromStr(s: []const u8) PinDir {
        if (s.len == 0) return .inout;
        return switch (s[0]) {
            'i' => if (s.len > 1 and s[1] == 'o') .inout else .input,
            'o' => .output,
            'p' => .power,
            'g' => .ground,
            else => .inout,
        };
    }

    /// Single-character abbreviation used in CHN wire format.
    pub fn toStr(self: PinDir) []const u8 {
        return switch (self) {
            .input  => "i",
            .output => "o",
            .inout  => "io",
            .power  => "p",
            .ground => "g",
        };
    }
};

test "Expose struct size for geometry" {
    const print = std.debug.print;
    print("Point: {d}B\n",     .{@sizeOf(Point)});
    print("Transform: {d}B\n", .{@sizeOf(Transform)});
}
