//! Schematic model types shared across core, state, and commands.
//!
//! `CT` is the single pub struct — a comptime namespace containing all
//! schematic and companion types. Re-exported through `core.zig`.

const std = @import("std");
const geo = @import("Geometry.zig");

/// Circuit/schematic type namespace. Every schematic data structure lives here.
pub const CT = struct {

    /// 2D integer point — `@Vector(2, i32)`. Access as `p[0]` (x) and `p[1]` (y).
    pub const Point = geo.Point;

    /// Compact instance transform: 2-bit rotation (0–3 = 0°/90°/180°/270°)
    /// plus a flip flag. Fits in 1 byte as a packed struct.
    pub const Transform = geo.Transform;

    pub const ShapeTag = enum(u8) { line, rect, other };

    /// Tagged shape — use `std.meta.activeTag(s)` to branch on kind.
    pub const Shape = union(ShapeTag) {
        line: struct { start: Point, end: Point },
        rect: struct { min: Point, max: Point },
        other: void,
    };

    pub const SymbolPin = struct { pos: Point };

    pub const Symbol = struct {
        shapes: std.ArrayListUnmanaged(Shape) = .{},
        pins: std.ArrayListUnmanaged(SymbolPin) = .{},
    };

    pub const InstanceProp = struct {
        key: []const u8,
        val: []const u8,
    };

    pub const Instance = struct {
        name: []const u8,
        symbol: []const u8,
        pos: Point,
        xform: Transform = .{},
        props: std.ArrayListUnmanaged(InstanceProp) = .{},
    };

    pub const Wire = struct {
        start: Point,
        end: Point,
        net_name: ?[]const u8 = null,
    };

    pub const Schematic = struct {
        arena: std.heap.ArenaAllocator,
        name: []const u8,
        instances: std.ArrayListUnmanaged(Instance) = .{},
        wires: std.ArrayListUnmanaged(Wire) = .{},

        /// Initialise with an arena so all child allocations share one lifetime.
        pub fn init(backing: std.mem.Allocator, name: []const u8) Schematic {
            var arena = std.heap.ArenaAllocator.init(backing);
            const name_copy = arena.allocator().dupe(u8, name) catch "untitled";
            return .{ .arena = arena, .name = name_copy };
        }

        /// Free all arena memory in a single call — no per-field cleanup needed.
        pub fn deinit(self: *Schematic) void {
            self.arena.deinit();
        }

        /// Expose the arena allocator for child allocations tied to this schematic.
        pub fn alloc(self: *Schematic) std.mem.Allocator {
            return self.arena.allocator();
        }
    };

    pub const Sim = enum { ngspice, xyce };

    pub const FileType = enum {
        xschem_sch,
        chn,
        chn_tb,
        unknown,

        const ext_map = .{
            .{ ".sch",    FileType.xschem_sch },
            .{ ".chn_tb", FileType.chn_tb },
            .{ ".chn",    FileType.chn },
        };

        /// Derive file type from extension so callers avoid string comparisons.
        pub fn fromPath(path: []const u8) FileType {
            inline for (ext_map) |entry| {
                if (std.mem.endsWith(u8, path, entry[0])) return entry[1];
            }
            return .unknown;
        }
    };

    pub const Tool = enum {
        select,
        wire,
        move,
        pan,
        line,
        rect,
        polygon,
        arc,
        circle,
        text,

        /// Upper-case label suitable for status-bar display.
        pub fn label(self: Tool) []const u8 {
            return switch (self) {
                .select  => "SELECT",
                .wire    => "WIRE",
                .move    => "MOVE",
                .pan     => "PAN",
                .line    => "LINE",
                .rect    => "RECT",
                .polygon => "POLYGON",
                .arc     => "ARC",
                .circle  => "CIRCLE",
                .text    => "TEXT",
            };
        }
    };

    /// Packed render/behaviour flags — all boolean fields occupy 1 bit each,
    /// keeping the struct to 4 bytes so it fits in a register.
    pub const CommandFlags = packed struct {
        fullscreen:         bool = false,
        dark_mode:          bool = false,
        fill_rects:         bool = false,
        text_in_symbols:    bool = false,
        symbol_details:     bool = false,
        show_all_layers:    bool = true,
        show_netlist:       bool = false,
        crosshair:          bool = false,
        wire_routing:       bool = false,
        orthogonal_routing: bool = false,
        flat_netlist:       bool = false,
        _pad:               u5  = 0,
        line_width:         i16 = 1,
    };

    pub const ToolState = struct {
        active:       Tool    = .select,
        snap_to_grid: bool    = true,
        snap_size:    f32     = 10.0,
        wire_start:   ?Point  = null,
    };
};

test "Expose struct size for types" {
    const print = std.debug.print;
    print("CT.Transform:    {d}B\n", .{@sizeOf(CT.Transform)});
    print("CT.Shape:        {d}B\n", .{@sizeOf(CT.Shape)});
    print("CT.SymbolPin:    {d}B\n", .{@sizeOf(CT.SymbolPin)});
    print("CT.Symbol:       {d}B\n", .{@sizeOf(CT.Symbol)});
    print("CT.InstanceProp: {d}B\n", .{@sizeOf(CT.InstanceProp)});
    print("CT.Instance:     {d}B\n", .{@sizeOf(CT.Instance)});
    print("CT.Wire:         {d}B\n", .{@sizeOf(CT.Wire)});
    print("CT.Schematic:    {d}B\n", .{@sizeOf(CT.Schematic)});
    print("CT.CommandFlags: {d}B\n", .{@sizeOf(CT.CommandFlags)});
    print("CT.ToolState:    {d}B\n", .{@sizeOf(CT.ToolState)});
}
