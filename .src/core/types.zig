const std = @import("std");

// ── Enums ────────────────────────────────────────────────────────────────────

pub const SchematicType = enum(u2) { schematic, symbol, testbench, primitive };

pub const PinDir = enum(u8) {
    input,
    output,
    inout,
    power,
    ground,

    const map = std.StaticStringMap(PinDir).initComptime(.{
        .{ "i", .input }, .{ "o", .output }, .{ "io", .inout },
        .{ "p", .power }, .{ "g", .ground },
        .{ "input", .input }, .{ "output", .output }, .{ "inout", .inout },
        .{ "power", .power }, .{ "ground", .ground },
    });

    pub fn fromStr(s: []const u8) PinDir {
        return map.get(s) orelse .inout;
    }

    pub fn toStr(self: PinDir) []const u8 {
        return switch (self) {
            .input => "i", .output => "o", .inout => "io",
            .power => "p", .ground => "g",
        };
    }
};

pub const GeomKind = enum(u8) { line, rect, circle, arc, text, polygon };

pub const DeviceKind = enum(u8) {
    unknown,
    // Passives
    resistor, resistor3, var_resistor, capacitor, inductor,
    // Diodes
    diode, zener,
    // MOSFETs
    nmos3, pmos3, nmos4, pmos4, nmos4_depl, nmos_sub, pmos_sub, nmoshv4, pmoshv4, rnmos4,
    // BJTs
    npn, pnp,
    // JFETs / MESFET
    njfet, pjfet, mesfet,
    // Sources
    vsource, isource, sqwsource, ammeter, behavioral,
    // Controlled sources
    vcvs, vccs, ccvs, cccs,
    // Transmission / coupling
    coupling, tline, tline_lossy,
    // Switches
    vswitch, iswitch,
    // Simulation / probes
    param, probe, probe_diff, code, graph,
    // HDL
    hdl,
    // Connectors / labels
    gnd, vdd, lab_pin, input_pin, output_pin, inout_pin,
    // Non-electrical
    annotation, noconn, title, launcher, rgb_led, generic,
    // Hierarchical
    digital_instance, subckt,

    pub fn isNonElectrical(self: DeviceKind) bool {
        return switch (self) {
            .annotation, .title, .param, .code, .graph,
            .launcher, .rgb_led, .noconn, .generic,
            => true,
            else => false,
        };
    }

    pub fn isLabel(self: DeviceKind) bool {
        return switch (self) {
            .lab_pin, .input_pin, .output_pin, .inout_pin => true,
            else => false,
        };
    }

    pub fn isPower(self: DeviceKind) bool {
        return self == .gnd or self == .vdd;
    }

    pub fn fromStr(s: []const u8) DeviceKind {
        return std.meta.stringToEnum(DeviceKind, s) orelse .unknown;
    }
};

pub const ConnKind = enum(u8) {
    instance_pin,
    wire_endpoint,
    label,

    const tags = std.StaticStringMap(ConnKind).initComptime(.{
        .{ "ip", .instance_pin }, .{ "we", .wire_endpoint }, .{ "lb", .label },
    });

    pub fn toTag(self: ConnKind) []const u8 {
        return switch (self) {
            .instance_pin => "ip", .wire_endpoint => "we", .label => "lb",
        };
    }

    pub fn fromTag(s: []const u8) ConnKind {
        return tags.get(s) orelse .label;
    }
};

// ── Flags ────────────────────────────────────────────────────────────────────

pub const InstanceFlags = packed struct(u8) {
    rot: u2 = 0,
    flip: bool = false,
    bus: bool = false,
    _pad: u4 = 0,
};

// ── Core data structs (fields ordered by alignment: 8, 4, 2, 1) ─────────────

pub const Instance = struct {
    name: []const u8,
    symbol: []const u8,
    spice_line: ?[]const u8 = null,
    prop_start: u32 = 0,
    conn_start: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    prop_count: u16 = 0,
    conn_count: u16 = 0,
    kind: DeviceKind = .unknown,
    flags: InstanceFlags = .{},
};

pub const Wire = struct {
    net_name: ?[]const u8 = null,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    bus: bool = false,
};

pub const Pin = struct {
    name: []const u8,
    x: i32,
    y: i32,
    num: ?u16 = null,
    width: u16 = 1,
    dir: PinDir = .inout,
};

pub const Property = struct {
    key: []const u8,
    val: []const u8,
};

pub const Conn = struct {
    pin: []const u8,
    net: []const u8,
};

pub const Net = struct {
    name: []const u8,
};

pub const NetConn = struct {
    net_id: u32,
    ref_a: i32,
    ref_b: i32,
    pin_or_label: ?[]const u8 = null,
    kind: ConnKind,
};

// ── Geometry ─────────────────────────────────────────────────────────────────

pub const Line = struct {
    x0: i32, y0: i32, x1: i32, y1: i32,
    layer: u8 = 4,
};

pub const Rect = struct {
    x0: i32, y0: i32, x1: i32, y1: i32,
    layer: u8 = 4,
};

pub const Circle = struct {
    cx: i32, cy: i32, radius: i32,
    layer: u8 = 4,
};

pub const Arc = struct {
    cx: i32, cy: i32, radius: i32,
    start_angle: i16, sweep_angle: i16,
    layer: u8 = 4,
};

pub const Text = struct {
    content: []const u8,
    x: i32, y: i32,
    layer: u8 = 4,
    size: u8 = 10,
    rotation: u2 = 0,
};

// ── Symbol / resolved data ───────────────────────────────────────────────────

pub const PinRef = struct {
    name: []const u8,
    x: i32 = 0,
    y: i32 = 0,
    dir: PinDir = .inout,
    propag: bool = true,
};

pub const SymData = struct {
    pins: []const PinRef = &.{},
    props: []const Property = &.{},
    format: ?[]const u8 = null,
    lvs_format: ?[]const u8 = null,
    template: ?[]const u8 = null,
};

pub const PrimCacheEntry = struct {
    pin_positions: []const PinRef = &.{},
    injected_net: ?[]const u8 = null,
};

// ── Net map (union-find point lookup) ────────────────────────────────────────

pub const NetMap = struct {
    root_to_name: std.AutoHashMapUnmanaged(u64, []const u8) = .{},
    point_to_root: std.AutoHashMapUnmanaged(u64, u64) = .{},

    pub fn deinit(self: *NetMap, a: std.mem.Allocator) void {
        self.root_to_name.deinit(a);
        self.point_to_root.deinit(a);
    }

    pub fn pointKey(x: i32, y: i32) u64 {
        return (@as(u64, @as(u32, @bitCast(x))) << 32) | @as(u64, @as(u32, @bitCast(y)));
    }

    pub fn getNetName(self: *const NetMap, x: i32, y: i32) ?[]const u8 {
        const root = self.point_to_root.get(pointKey(x, y)) orelse return null;
        return self.root_to_name.get(root);
    }
};

// ── Plugin block (round-trip preserved) ──────────────────────────────────────

pub const PluginBlock = struct {
    name: []const u8,
    entries: std.ArrayListUnmanaged(Property) = .{},
};

// ── File type detection ──────────────────────────────────────────────────────

pub const FileType = enum {
    chn, chn_prim, chn_tb, xschem_sch, unknown,

    pub fn fromPath(path: []const u8) FileType {
        if (std.mem.endsWith(u8, path, ".chn_prim")) return .chn_prim;
        if (std.mem.endsWith(u8, path, ".chn_tb")) return .chn_tb;
        if (std.mem.endsWith(u8, path, ".chn")) return .chn;
        if (std.mem.endsWith(u8, path, ".sch")) return .xschem_sch;
        return .unknown;
    }
};
