//! types.zig — All shared/simple data types for the core module.
//!
//! Public within the module; external consumers access them through lib.zig
//! re-exports only where needed in function signatures.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

// ── PinDir ────────────────────────────────────────────────────────────────────

pub const PinDir = enum(u8) {
    input,
    output,
    inout,
    power,
    ground,

    pub fn fromStr(s: []const u8) PinDir {
        if (s.len == 0) return .inout;
        return switch (s[0]) {
            'i' => if (s.len >= 5 and s[1] == 'n' and s[2] == 'o') .inout
                else if (s.len == 2 and s[1] == 'o') .inout
                else .input,
            'o' => .output,
            'p' => .power,
            'g' => .ground,
            else => .inout,
        };
    }

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

// ── DOD element structs (ordered by alignment: largest first) ─────────────────

pub const Line = struct {
    // i32 fields first (4-byte alignment), then u8
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    layer: u8,
};

pub const Rect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    layer: u8,
};

pub const Circle = struct {
    cx: i32,
    cy: i32,
    radius: i32,
    layer: u8,
};

pub const Arc = struct {
    cx: i32,
    cy: i32,
    radius: i32,
    start_angle: i16,
    sweep_angle: i16,
    layer: u8,
};

pub const Wire = struct {
    // slice (8-byte) first, then i32, then bool
    net_name: ?[]const u8 = null,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    bus: bool = false,
};

pub const Text = struct {
    // slice (8-byte) first, then i32, then u8/u2
    content: []const u8,
    x: i32,
    y: i32,
    layer: u8 = 4,
    size: u8 = 10,
    rotation: u2 = 0,
};

pub const Pin = struct {
    // slice (8-byte) first, then i32, then u16, then enum(u8)
    name: []const u8,
    x: i32,
    y: i32,
    num: ?u16 = null,
    width: u16 = 1,
    dir: PinDir = .inout,
};

pub const Instance = struct {
    // slices (8-byte) first, then u32, then i32, then u16, then u2/bool/enum
    name: []const u8,
    symbol: []const u8,
    spice_line: ?[]const u8 = null,
    prop_start: u32 = 0,
    conn_start: u32 = 0,
    x: i32,
    y: i32,
    prop_count: u16 = 0,
    conn_count: u16 = 0,
    kind: DeviceKind = .unknown,
    rot: u2 = 0,
    flip: bool = false,
};

pub const Prop = struct {
    // both slices (8-byte)
    key: []const u8,
    val: []const u8,
};

pub const Conn = struct {
    // both slices (8-byte)
    pin: []const u8,
    net: []const u8,
};

pub const Net = struct {
    name: []const u8,
};

pub const ConnKind = enum(u8) {
    instance_pin,
    wire_endpoint,
    label,

    const tag_table = std.StaticStringMap(ConnKind).initComptime(.{
        .{ "ip", .instance_pin },
        .{ "we", .wire_endpoint },
        .{ "lb", .label },
    });

    pub fn toTag(self: ConnKind) []const u8 {
        return switch (self) {
            .instance_pin  => "ip",
            .wire_endpoint => "we",
            .label         => "lb",
        };
    }

    pub fn fromTag(s: []const u8) ConnKind {
        return tag_table.get(s) orelse .label;
    }
};

pub const NetConn = struct {
    // u32 first, then i32, then optional slice, then enum(u8)
    net_id: u32,
    ref_a: i32,
    ref_b: i32,
    pin_or_label: ?[]const u8 = null,
    kind: ConnKind,
};

pub const NetMap = struct {
    // hash maps (contain pointers, 8-byte alignment)
    root_to_name: std.AutoHashMapUnmanaged(u64, []const u8),
    point_to_root: std.AutoHashMapUnmanaged(u64, u64),

    pub fn init() NetMap {
        return .{ .root_to_name = .{}, .point_to_root = .{} };
    }

    pub fn deinit(self: *NetMap, a: Allocator) void {
        self.root_to_name.deinit(a);
        self.point_to_root.deinit(a);
    }

    pub fn pointKey(x: i32, y: i32) u64 {
        const ux: u64 = @as(u32, @bitCast(x));
        const uy: u64 = @as(u32, @bitCast(y));
        return (ux << 32) | uy;
    }

    pub fn getNetName(self: *const NetMap, x: i32, y: i32) ?[]const u8 {
        const root = self.point_to_root.get(pointKey(x, y)) orelse return null;
        return self.root_to_name.get(root);
    }
};

pub const SifyType = enum(u2) { primitive, component, testbench };

pub const SymDataPin = struct {
    // slice first, then i32, then slice of Prop
    name: []const u8,
    x: i32,
    y: i32,
    props: []const Prop = &.{},
};

pub const PinRef = struct {
    // slice first, then i32, then enum, then bool
    name: []const u8,
    x: i32 = 0,
    y: i32 = 0,
    dir: PinDir = .inout,
    propag: bool = true,
};

pub const SymData = struct {
    // slices (8-byte) first, then optional slices
    pins: []const PinRef = &.{},
    props: []const Prop = &.{},
    format: ?[]const u8 = null,
    lvs_format: ?[]const u8 = null,
    template: ?[]const u8 = null,
};

pub const SourceMode = enum { @"inline", file };

pub const HdlLanguage = enum {
    verilog,
    vhdl,
    xspice,
    xyce_digital,

    pub fn fromStr(s: []const u8) ?HdlLanguage {
        if (std.mem.eql(u8, s, "verilog")) return .verilog;
        if (std.mem.eql(u8, s, "vhdl")) return .vhdl;
        if (std.mem.eql(u8, s, "xspice")) return .xspice;
        if (std.mem.eql(u8, s, "xyce_digital")) return .xyce_digital;
        return null;
    }

    pub fn toStr(self: HdlLanguage) []const u8 {
        return switch (self) {
            .verilog => "verilog",
            .vhdl => "vhdl",
            .xspice => "xspice",
            .xyce_digital => "xyce_digital",
        };
    }
};

pub const BehavioralModel = struct {
    // optional slices first, then enum
    source: ?[]const u8 = null,
    top_module: ?[]const u8 = null,
    mode: SourceMode = .file,
};

pub const SynthesizedModel = struct {
    // optional slices first, then List, then enum
    source: ?[]const u8 = null,
    liberty: ?[]const u8 = null,
    mapping: ?[]const u8 = null,
    supply_map: List(Prop) = .{},
    mode: SourceMode = .file,
};

pub const DigitalConfig = struct {
    behavioral: BehavioralModel = .{},
    synthesized: SynthesizedModel = .{},
    language: HdlLanguage = .verilog,
};

// ── DeviceKind (re-exported from Devices.zig) ────────────────────────────────

pub const DeviceKind = @import("devices/Devices.zig").DeviceKind;

// ── Helper types used by Devices.zig (private to module) ─────────────────────

pub const ParamDefault = struct {
    key: []const u8,
    val: []const u8,
};


pub const NameEntry = struct {
    name: []const u8,
    ref: CellRef,
};

pub const CellTier = enum(u2) { prim = 0, comp = 1, tb = 2, unregistered = 3 };

pub const CellRef = packed struct(u32) {
    idx: u30,
    tier: CellTier,
};

pub const PrimKindIter = struct {
    kinds: []const DeviceKind,
    target: DeviceKind,
    pos: usize = 0,

    pub fn next(self: *PrimKindIter) ?u30 {
        while (self.pos < self.kinds.len) {
            const i = self.pos;
            self.pos += 1;
            if (self.kinds[i] == self.target) return @intCast(i);
        }
        return null;
    }

    pub fn reset(self: *PrimKindIter) void {
        self.pos = 0;
    }
};

pub const LibInclude = struct {
    path: []const u8,
    /// true -> `.lib "path" <corner>`, false -> `.include "path"`
    has_sections: bool,
};

pub const Prim = struct {
    // slices (8-byte) first, then enum/u8
    cell_name: []const u8,
    file: []const u8,
    library: []const u8,
    pin_order: []const []const u8,
    model_name: ?[]const u8,
    default_params: []const ParamDefault,
    lib_includes: []const LibInclude,
    kind: DeviceKind,
    prefix: u8,
};

pub const Comp = struct {
    cell_name: []const u8,
    file: []const u8,
    library: []const u8,
    pin_order: []const []const u8,
};

pub const Tb = struct {
    cell_name: []const u8,
    file: []const u8,
    library: []const u8,
};

// ── Diagnostic types ─────────────────────────────────────────────────────────

pub const DiagLevel = enum { @"error", warning, info };

pub const Diagnostic = struct {
    // slices first, then enum
    code: []const u8,
    message: []const u8,
    level: DiagLevel,
};

pub const LogLevel = enum { info, warn, err };

// ── ComponentDesc (used by Schemify.addComponent) ────────────────────────────

pub const ComponentDesc = struct {
    // slices (8-byte) first, then i32, then small types
    name: []const u8,
    symbol: []const u8,
    props: []const Prop = &.{},
    conns: []const Conn = &.{},
    spice_line: ?[]const u8 = null,
    sym_data: ?SymData = null,
    x: i32,
    y: i32,
    kind: DeviceKind = .unknown,
    rot: u2 = 0,
    flip: bool = false,
};

// ── HDL Sync types ───────────────────────────────────────────────────────────

pub const PinChange = struct {
    name: []const u8,
    change: []const u8,
};

pub const SyncReport = struct {
    pins_added: []const @import("digital/HdlParser.zig").HdlPin,
    pins_removed: []const []const u8,
    pins_modified: []const PinChange,
    symbol_updated: bool,
};

pub const HdlMismatch = struct {
    pin_name: []const u8,
    issue: []const u8,
};

pub const SyncError = error{
    NoDigitalConfig,
    NoBehavioralSource,
    UnsupportedLanguage,
    HdlParseError,
    FileReadError,
    OutOfMemory,
};
