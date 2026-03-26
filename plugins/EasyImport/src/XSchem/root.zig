// root.zig - Public API for XSchem DOD types and Schematic container.
//
// Re-exports all types from types.zig and the PropertyTokenizer from props.zig.
// The Schematic container uses MultiArrayList for geometric elements and
// ArrayListUnmanaged for properties, all backed by a single ArenaAllocator.

const std = @import("std");

// ── Re-exports from types.zig ────────────────────────────────────────────

const types = @import("types.zig");

pub const PinDirection = types.PinDirection;
pub const pinDirectionFromStr = types.pinDirectionFromStr;
pub const pinDirectionToStr = types.pinDirectionToStr;
pub const Line = types.Line;
pub const Rect = types.Rect;
pub const Arc = types.Arc;
pub const Circle = types.Circle;
pub const Wire = types.Wire;
pub const Text = types.Text;
pub const Pin = types.Pin;
pub const Instance = types.Instance;
pub const Prop = types.Prop;
pub const FileType = types.FileType;
pub const ParseError = types.ParseError;

// ── Re-exports from props.zig ────────────────────────────────────────────

const props = @import("props.zig");

pub const PropertyTokenizer = props.PropertyTokenizer;
pub const parseProps = props.parseProps;

// ── Re-exports from reader.zig ─────────────────────────────────────────

const reader = @import("reader.zig");

pub const parse = reader.parse;

// ── MultiArrayList alias ─────────────────────────────────────────────────

fn MAL(comptime T: type) type {
    return std.MultiArrayList(T);
}

// ── Schematic container ──────────────────────────────────────────────────

/// Main XSchem DOD container. Owns all element memory through `arena`.
/// Used as the parse target for .sch/.sym files; downstream translation
/// reads from these arrays. No parsing logic lives here -- see reader.zig.
pub const Schematic = struct {
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

    // Arena-per-stage allocation -- single deinit tears down everything
    arena: std.heap.ArenaAllocator,

    /// Create a new empty Schematic backed by the given allocator.
    pub fn init(backing: std.mem.Allocator) Schematic {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    /// Release all memory owned by this Schematic.
    pub fn deinit(self: *Schematic) void {
        self.arena.deinit();
    }
};
