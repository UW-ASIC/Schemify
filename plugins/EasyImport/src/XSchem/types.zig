// types.zig - XSchem DOD element types. No methods, no OOP. Pure data.
//
// All 7 geometric element types (Line, Rect, Arc, Circle, Wire, Text, Pin)
// plus Instance and Prop as flat structs. Coordinates are f64 matching
// XSchem's native format; conversion to i32 happens downstream.

const std = @import("std");

/// Pin direction for XSchem pins.
/// Identical variant order to Schemify's PinDir for direct ordinal cast.
pub const PinDirection = enum(u8) {
    input,
    output,
    inout,
    power,
    ground,
};

/// Map an XSchem direction string to a PinDirection.
/// "i" -> input, "o" -> output, "io"/"inout" -> inout, "p" -> power, "g" -> ground.
/// Returns .inout for unrecognized strings.
pub fn pinDirectionFromStr(s: []const u8) PinDirection {
    if (s.len == 0) return .inout;
    return switch (s[0]) {
        'i' => if (std.mem.eql(u8, s, "io") or std.mem.eql(u8, s, "inout")) .inout else .input,
        'o' => .output,
        'p' => .power,
        'g' => .ground,
        else => .inout,
    };
}

/// Map a PinDirection back to the short XSchem string.
pub fn pinDirectionToStr(dir: PinDirection) []const u8 {
    return switch (dir) {
        .input => "i",
        .output => "o",
        .inout => "io",
        .power => "p",
        .ground => "g",
    };
}

// ── Geometric element types ──────────────────────────────────────────────

pub const Line = struct {
    layer: i32,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
};

pub const Rect = struct {
    layer: i32,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    image_data: ?[]const u8 = null,
};

pub const Arc = struct {
    layer: i32,
    cx: f64,
    cy: f64,
    radius: f64,
    start_angle: f64,
    sweep_angle: f64,
};

pub const Circle = struct {
    layer: i32,
    cx: f64,
    cy: f64,
    radius: f64,
};

pub const Wire = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    net_name: ?[]const u8 = null,
    bus: bool = false,
};

pub const Text = struct {
    content: []const u8,
    x: f64,
    y: f64,
    layer: i32 = 4,
    size: f64 = 0.4,
    rotation: i32 = 0,
};

pub const Pin = struct {
    name: []const u8,
    x: f64,
    y: f64,
    direction: PinDirection = .inout,
    number: ?u32 = null,
};

// ── Instance and property types ──────────────────────────────────────────

pub const Instance = struct {
    name: []const u8,
    symbol: []const u8,
    x: f64,
    y: f64,
    rot: i32 = 0,
    flip: bool = false,
    /// Index into the parent Schematic's props array where this instance's
    /// properties begin.
    prop_start: u32 = 0,
    /// Number of properties belonging to this instance.
    prop_count: u16 = 0,
};

pub const Prop = struct {
    key: []const u8,
    value: []const u8,
};

// ── File type and error definitions ──────────────────────────────────────

pub const FileType = enum(u1) {
    schematic,
    symbol,
};

pub const ParseError = error{
    MalformedLine,
    MalformedRect,
    MalformedWire,
    MalformedComponent,
    MalformedText,
    MalformedArc,
    MalformedPolygon,
    UnbalancedBraces,
    MissingRequiredField,
    UnknownElementTag,
    InvalidNumber,
    UnexpectedEof,
};
