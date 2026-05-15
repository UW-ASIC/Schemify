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

// ── XSchemFiles container ────────────────────────────────────────────────

fn MAL(comptime T: type) type {
    return std.MultiArrayList(T);
}

/// Main XSchem DOD container. Owns all element memory through `arena`.
/// Used as the parse target for .sch/.sym files; downstream translation
/// reads from these arrays. No parsing logic lives here -- see reader.zig.
pub const XSchemFiles = struct {
    // Geometric element arrays (struct-of-arrays via MultiArrayList)
    lines: MAL(Line) = .{},
    rects: MAL(Rect) = .{},
    arcs: MAL(Arc) = .{},
    circles: MAL(Circle) = .{},
    wires: MAL(Wire) = .{},
    texts: MAL(Text) = .{},
    pins: MAL(Pin) = .{},
    instances: MAL(Instance) = .{},

    // Flat property storage -- instances index into this via prop_start/prop_count
    props: std.ArrayListUnmanaged(Prop) = .{},

    // File metadata
    name: []const u8 = "",
    file_type: FileType = .schematic,

    // K-block symbol properties (extracted during parse)
    k_type: ?[]const u8 = null,
    k_format: ?[]const u8 = null,
    k_template: ?[]const u8 = null,
    k_extra: ?[]const u8 = null,
    k_global: bool = false,
    k_spice_sym_def: ?[]const u8 = null,

    // S-block (raw SPICE body from schematic header)
    s_block: ?[]const u8 = null,

    // Arena-per-stage allocation -- single deinit tears down everything
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) XSchemFiles {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *XSchemFiles) void {
        self.arena.deinit();
    }
};
