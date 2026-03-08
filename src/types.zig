//! Core data types for the Schemify schematic model.

const std = @import("std");

pub const Sim = enum { ngspice, xyce };

pub const CT = struct {
    pub const Point = struct { x: i32, y: i32 };
    pub const Transform = struct { rot: u2 = 0, flip: bool = false };
    pub const Wire = struct {
        start: Point,
        end: Point,
        net_name: ?[]const u8 = null,
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
    pub const Schematic = struct {
        arena: std.heap.ArenaAllocator,
        name: []const u8,
        instances: std.ArrayListUnmanaged(Instance) = .{},
        wires: std.ArrayListUnmanaged(Wire) = .{},

        pub fn init(backing: std.mem.Allocator, name: []const u8) Schematic {
            var arena = std.heap.ArenaAllocator.init(backing);
            const a = arena.allocator();
            // Dupe the name BEFORE the struct literal so that the arena's node
            // list is populated before `arena` is copied into the return value.
            // If we put the dupe inside the struct literal after `.arena = arena`,
            // Zig evaluates `.arena = arena` first (copying the empty arena), then
            // runs a.dupe() against the local arena — the new node is never seen
            // by the returned arena and leaks.
            const name_copy = a.dupe(u8, name) catch "untitled";
            return .{
                .arena = arena,
                .name = name_copy,
            };
        }

        pub fn alloc(self: *Schematic) std.mem.Allocator {
            return self.arena.allocator();
        }

        pub fn deinit(self: *Schematic) void {
            self.instances.deinit(self.alloc());
            self.wires.deinit(self.alloc());
            self.arena.deinit();
        }
    };

    pub const ShapeTag = enum { line, rect, other };
    pub const Shape = struct {
        tag: ShapeTag,
        data: union(ShapeTag) {
            line: struct { start: Point, end: Point },
            rect: struct { min: Point, max: Point },
            other: void,
        },
    };
    pub const SymbolPin = struct { pos: Point };
    pub const Symbol = struct {
        shapes: std.ArrayListUnmanaged(Shape) = .{},
        pins: std.ArrayListUnmanaged(SymbolPin) = .{},
    };
};

pub const FileType = enum {
    chn,      // schematic — renders with Sch + Sym view-mode buttons
    chn_tb,   // testbench — locked to schematic view, button labelled "Testbench"
    chn_sym,  // symbol-only — locked to symbol view, button labelled "Symbol"
    unknown,

    pub fn fromPath(path: []const u8) FileType {
        if (std.mem.endsWith(u8, path, ".chn_tb"))  return .chn_tb;
        if (std.mem.endsWith(u8, path, ".chn_sym")) return .chn_sym;
        if (std.mem.endsWith(u8, path, ".chn"))     return .chn;
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
};

pub const CommandFlags = struct {
    fullscreen: bool = false,
    dark_mode: bool = false,
    fill_rects: bool = false,
    text_in_symbols: bool = false,
    symbol_details: bool = false,
    show_all_layers: bool = true,
    show_netlist: bool = false,
    crosshair: bool = false,
    wire_routing: bool = false,
    orthogonal_routing: bool = false,
    flat_netlist: bool = false,
    line_width: i32 = 1,
};

pub const ToolState = struct {
    active: Tool = .select,
    snap_to_grid: bool = true,
    snap_size: f32 = 10.0,
    wire_start: ?[2]i32 = null,
    draw_points: [16]CT.Point = [_]CT.Point{.{ .x = 0, .y = 0 }} ** 16,
    draw_point_count: u8 = 0,

    pub fn label(self: *const ToolState) []const u8 {
        return switch (self.active) {
            .select => "SELECT",
            .wire => "WIRE",
            .move => "MOVE",
            .pan => "PAN",
            .line => "LINE",
            .rect => "RECT",
            .polygon => "POLYGON",
            .arc => "ARC",
            .circle => "CIRCLE",
            .text => "TEXT",
        };
    }
};
