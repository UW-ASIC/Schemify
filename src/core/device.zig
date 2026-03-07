//! Device Definitions + PDK Cell Registry (leaf — zero project imports).
//!
//! Builtin passives (comptime, O(1) LUT) + three-tier PDK cells (runtime,
//! SoA via MultiArrayList). Single name_map enforces 1-to-1: no cell name
//! can appear in more than one tier.
//!
//! Netlister resolve chain:
//!   1. registry.find(cell_name) → ?CellRef  (PDK prim or comp)
//!   2. getBuiltinDevice(kind)               (comptime passive fallback)
//!   3. unresolved → comment placeholder
//!
//! Loader contract (volare, nix, flat dir, whatever):
//!   var reg = PdkDeviceRegistry.init();
//!   try reg.addPrimitive(a, .{ .cell_name = "nfet_01v8", ... });
//!   try reg.addComponent(a, .{ .cell_name = "inv_1", ... });
//!   // hand reg to netlister + GUI

const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;

// ── SPICE dialect + format ──────────────────────────────────────────────── //

pub const SpiceDialect = enum { ngspice, xyce };

pub const SpiceFormat = enum(u8) {
    passive, //  R1 n1 n2 value
    semiconductor, //  M1 d g s b model W=… L=…
    source, //  V1 n+ n- DC value
    subcircuit, //  X1 pins… subckt params…
};

// ── DeviceKind ──────────────────────────────────────────────────────────── //

pub const DeviceKind = enum(u8) {
    unknown,
    resistor,
    capacitor,
    inductor,
    diode,
    mosfet,
    bjt,
    jfet,
    vsource,
    ammeter,
    isource,
    vcvs,
    vccs,
    cccs,
    ccvs,
    gnd,
    vdd,
    lab_pin,
    code,
    graph,
    subckt,

    pub fn toStr(self: DeviceKind) []const u8 {
        return @tagName(self);
    }

    /// O(1) perfect hash lookup via StaticStringMap.
    pub fn fromStr(s: []const u8) DeviceKind {
        return kind_map.get(s) orelse .unknown;
    }

    pub fn isNonElectrical(self: DeviceKind) bool {
        return switch (self) {
            .gnd, .vdd, .lab_pin, .graph => true,
            else => false,
        };
    }

    pub fn injectedNetName(self: DeviceKind) ?[]const u8 {
        return switch (self) {
            .gnd => "0",
            .vdd => "VDD",
            else => null,
        };
    }

    const kind_map = blk: {
        const fields = @typeInfo(DeviceKind).@"enum".fields;
        var kvs: [fields.len]struct { []const u8, DeviceKind } = undefined;
        for (fields, 0..) |f, i| kvs[i] = .{ f.name, @as(DeviceKind, @enumFromInt(f.value)) };
        break :blk std.StaticStringMap(DeviceKind).initComptime(kvs);
    };
};

// ── SpiceDevice template ────────────────────────────────────────────────── //

pub const ParamDefault = struct { key: []const u8, val: []const u8 };

pub const LibInclude = struct {
    path: []const u8,
    /// true → `.lib "path" <corner>`, false → `.include "path"`
    has_sections: bool,
};

/// Returned by resolve — a complete recipe for emitting one SPICE instance line.
/// NOT stored in the SoA; reconstructed on-demand from PrimEntry fields.
pub const SpiceDevice = struct {
    kind: DeviceKind,
    prefix: u8,
    pin_order: []const []const u8,
    model_name: ?[]const u8,
    format: SpiceFormat,
    default_params: []const ParamDefault,
};

// ── Builtin devices (comptime O(1) LUT) ────────────────────────────────── //

pub const builtin_devices = [_]SpiceDevice{
    .{ .kind = .resistor, .prefix = 'R', .pin_order = &.{ "p", "n" }, .model_name = null, .format = .passive, .default_params = &.{} },
    .{ .kind = .capacitor, .prefix = 'C', .pin_order = &.{ "p", "n" }, .model_name = null, .format = .passive, .default_params = &.{} },
    .{ .kind = .inductor, .prefix = 'L', .pin_order = &.{ "p", "n" }, .model_name = null, .format = .passive, .default_params = &.{} },
    .{ .kind = .diode, .prefix = 'D', .pin_order = &.{ "p", "n" }, .model_name = null, .format = .semiconductor, .default_params = &.{} },
    .{ .kind = .bjt, .prefix = 'Q', .pin_order = &.{ "c", "b", "e" }, .model_name = null, .format = .semiconductor, .default_params = &.{} },
    .{ .kind = .jfet, .prefix = 'J', .pin_order = &.{ "d", "g", "s" }, .model_name = null, .format = .semiconductor, .default_params = &.{} },
    .{ .kind = .vsource, .prefix = 'V', .pin_order = &.{ "p", "m" }, .model_name = null, .format = .source, .default_params = &.{} },
    .{ .kind = .isource, .prefix = 'I', .pin_order = &.{ "p", "n" }, .model_name = null, .format = .source, .default_params = &.{} },
    .{ .kind = .vcvs, .prefix = 'E', .pin_order = &.{ "p", "n", "cp", "cn" }, .model_name = null, .format = .passive, .default_params = &.{} },
    .{ .kind = .vccs, .prefix = 'G', .pin_order = &.{ "p", "n", "cp", "cn" }, .model_name = null, .format = .passive, .default_params = &.{} },
    .{ .kind = .ccvs, .prefix = 'H', .pin_order = &.{ "p", "n" }, .model_name = null, .format = .passive, .default_params = &.{} },
    .{ .kind = .cccs, .prefix = 'F', .pin_order = &.{ "p", "n" }, .model_name = null, .format = .passive, .default_params = &.{} },
    .{ .kind = .ammeter, .prefix = 'V', .pin_order = &.{ "p", "m" }, .model_name = null, .format = .source, .default_params = &.{} },
};

/// O(1) comptime LUT indexed by @intFromEnum(kind).
pub fn getBuiltinDevice(kind: DeviceKind) ?SpiceDevice {
    return builtin_lut[@intFromEnum(kind)];
}

const builtin_lut = blk: {
    const N = @typeInfo(DeviceKind).@"enum".fields.len;
    var lut = [1]?SpiceDevice{null} ** N;
    for (builtin_devices) |d| lut[@intFromEnum(d.kind)] = d;
    break :blk lut;
};

// ── SoA entry structs (MultiArrayList storage) ─────────────────────────── //

/// Leaf PDK device — SpiceDevice fields inlined for flat SoA.
/// Scanning by .kind touches only the u8 array, not the whole struct.
pub const PrimEntry = struct {
    cell_name: []const u8,
    sym_path: []const u8,
    library: []const u8,
    kind: DeviceKind,
    prefix: u8,
    format: SpiceFormat,
    pin_order: []const []const u8,
    model_name: ?[]const u8,
    default_params: []const ParamDefault,
    lib_includes: []const LibInclude,
};

/// Hierarchical subcircuit — symbol + schematic body. No .lib paths
/// (propagate from primitive leaves). No GDS/LEF (resolved at export).
pub const CompEntry = struct {
    cell_name: []const u8,
    sym_path: []const u8,
    sch_path: []const u8,
    library: []const u8,
    pin_order: []const []const u8,
};

/// Top-level simulation harness. Slot exists; usually empty.
/// Not importable by other cells.
pub const TbEntry = struct {
    cell_name: []const u8,
    sch_path: []const u8,
    library: []const u8,
};

// ── CellRef — packed tier+index in one u32 ──────────────────────────────── //

pub const CellTier = enum(u2) { prim = 0, comp = 1, tb = 2, unregistered = 3 };

/// Single hashmap value — packs tier + index into 32 bits.
/// Enforces 1-to-1: one name → one tier, one index.
pub const CellRef = packed struct(u32) {
    idx: u30,
    tier: CellTier,
};

// ── PdkDeviceRegistry ───────────────────────────────────────────────────── //

pub const PdkDeviceRegistry = struct {
    name: []const u8 = "",
    default_corner: []const u8 = "tt",
    dialect: SpiceDialect = .ngspice,

    prims: MAL(PrimEntry) = .{},
    comps: MAL(CompEntry) = .{},
    tbs: MAL(TbEntry) = .{},

    /// Single map across all tiers — enforces 1-to-1 naming.
    name_map: std.StringHashMapUnmanaged(CellRef) = .{},

    pub fn deinit(self: *PdkDeviceRegistry, a: Allocator) void {
        self.prims.deinit(a);
        self.comps.deinit(a);
        self.tbs.deinit(a);
        self.name_map.deinit(a);
    }

    // ── Registration (loader calls these) ───────────────────────────── //

    pub fn addPrimitive(self: *PdkDeviceRegistry, a: Allocator, e: PrimEntry) !void {
        const gop = try self.name_map.getOrPut(a, e.cell_name);
        if (gop.found_existing) return error.DuplicateCellName;
        const idx: u30 = @intCast(self.prims.len);
        try self.prims.append(a, e);
        gop.value_ptr.* = .{ .idx = idx, .tier = .prim };
    }

    pub fn addComponent(self: *PdkDeviceRegistry, a: Allocator, e: CompEntry) !void {
        const gop = try self.name_map.getOrPut(a, e.cell_name);
        if (gop.found_existing) return error.DuplicateCellName;
        const idx: u30 = @intCast(self.comps.len);
        try self.comps.append(a, e);
        gop.value_ptr.* = .{ .idx = idx, .tier = .comp };
    }

    pub fn addTestbench(self: *PdkDeviceRegistry, a: Allocator, e: TbEntry) !void {
        const gop = try self.name_map.getOrPut(a, e.cell_name);
        if (gop.found_existing) return error.DuplicateCellName;
        const idx: u30 = @intCast(self.tbs.len);
        try self.tbs.append(a, e);
        gop.value_ptr.* = .{ .idx = idx, .tier = .tb };
    }

    // ── Single O(1) lookup ──────────────────────────────────────────── //

    /// One hashmap hit → tier + index. Null if unregistered.
    pub fn find(self: *const PdkDeviceRegistry, cell_name: []const u8) ?CellRef {
        return self.name_map.get(cell_name);
    }

    pub fn classify(self: *const PdkDeviceRegistry, cell_name: []const u8) CellTier {
        return if (self.name_map.get(cell_name)) |ref| ref.tier else .unregistered;
    }

    // ── SpiceDevice reconstruction from SoA ─────────────────────────── //

    pub fn spiceDeviceAt(self: *const PdkDeviceRegistry, idx: u30) SpiceDevice {
        const s = self.prims.slice();
        const i = idx;
        return .{
            .kind = s.items(.kind)[i],
            .prefix = s.items(.prefix)[i],
            .format = s.items(.format)[i],
            .pin_order = s.items(.pin_order)[i],
            .model_name = s.items(.model_name)[i],
            .default_params = s.items(.default_params)[i],
        };
    }

    /// Full resolve chain: PDK primitive → builtin fallback → null.
    /// Components return null here — caller uses find() + getComponent().
    pub fn resolveDevice(self: *const PdkDeviceRegistry, cell_name: []const u8, fallback_kind: DeviceKind) ?SpiceDevice {
        if (self.name_map.get(cell_name)) |ref| {
            if (ref.tier == .prim) return self.spiceDeviceAt(ref.idx);
            return null; // comp/tb — caller handles
        }
        return getBuiltinDevice(fallback_kind);
    }

    // ── GUI access (direct SoA slices) ──────────────────────────────── //

    pub fn primitives(self: *const PdkDeviceRegistry) MAL(PrimEntry).Slice {
        return self.prims.slice();
    }

    pub fn components(self: *const PdkDeviceRegistry) MAL(CompEntry).Slice {
        return self.comps.slice();
    }

    pub fn testbenches(self: *const PdkDeviceRegistry) MAL(TbEntry).Slice {
        return self.tbs.slice();
    }

    pub fn primCount(self: *const PdkDeviceRegistry) usize {
        return self.prims.len;
    }
    pub fn compCount(self: *const PdkDeviceRegistry) usize {
        return self.comps.len;
    }
    pub fn tbCount(self: *const PdkDeviceRegistry) usize {
        return self.tbs.len;
    }
    pub fn totalCells(self: *const PdkDeviceRegistry) usize {
        return self.prims.len + self.comps.len + self.tbs.len;
    }
    pub fn isEmpty(self: *const PdkDeviceRegistry) bool {
        return self.totalCells() == 0;
    }

    // ── Kind iteration (for device chooser UI) ──────────────────────── //

    /// Returns indices into prims MAL filtered by kind.
    pub fn iterPrimsByKind(self: *const PdkDeviceRegistry, kind: DeviceKind) PrimKindIter {
        return .{ .kinds = self.prims.slice().items(.kind), .target = kind };
    }

    pub fn getComponent(self: *const PdkDeviceRegistry, idx: u30) CompEntry {
        const s = self.comps.slice();
        const i = idx;
        return .{
            .cell_name = s.items(.cell_name)[i],
            .sym_path = s.items(.sym_path)[i],
            .sch_path = s.items(.sch_path)[i],
            .library = s.items(.library)[i],
            .pin_order = s.items(.pin_order)[i],
        };
    }

    // ── Lazy .lib collection ────────────────────────────────────────── //

    pub fn collectLibIncludes(
        self: *const PdkDeviceRegistry,
        a: Allocator,
        cell_names: []const []const u8,
    ) ![]const LibInclude {
        var seen = std.StringHashMapUnmanaged(void){};
        defer seen.deinit(a);
        var out: List(LibInclude) = .{};
        errdefer out.deinit(a);
        const libs = self.prims.slice().items(.lib_includes);
        for (cell_names) |name| {
            const ref = self.name_map.get(name) orelse continue;
            if (ref.tier != .prim) continue;
            for (libs[ref.idx]) |inc| {
                const gop = try seen.getOrPut(a, inc.path);
                if (!gop.found_existing) try out.append(a, inc);
            }
        }
        return out.toOwnedSlice(a);
    }

    pub fn libsForCell(self: *const PdkDeviceRegistry, cell_name: []const u8) []const LibInclude {
        const ref = self.name_map.get(cell_name) orelse return &.{};
        if (ref.tier != .prim) return &.{};
        return self.prims.slice().items(.lib_includes)[ref.idx];
    }

    // ── Preamble emission ───────────────────────────────────────────── //

    pub fn emitPreamble(
        self: *const PdkDeviceRegistry,
        a: Allocator,
        cell_names: []const []const u8,
        corner_override: ?[]const u8,
    ) ![]u8 {
        const corner = corner_override orelse self.default_corner;
        const includes = try self.collectLibIncludes(a, cell_names);
        defer a.free(includes);
        var buf: List(u8) = .{};
        errdefer buf.deinit(a);
        const w = buf.writer(a);
        for (includes) |inc| {
            if (inc.has_sections) {
                switch (self.dialect) {
                    .ngspice => try w.print(".lib \"{s}\" {s}\n", .{ inc.path, corner }),
                    .xyce => try w.print(".LIB \"{s}\" {s}\n", .{ inc.path, corner }),
                }
            } else switch (self.dialect) {
                .ngspice => try w.print(".include \"{s}\"\n", .{inc.path}),
                .xyce => try w.print(".INCLUDE \"{s}\"\n", .{inc.path}),
            }
        }
        return buf.toOwnedSlice(a);
    }
};

// ── PrimKindIter ────────────────────────────────────────────────────────── //

/// Yields indices into prims MAL where kind matches. SoA-idiomatic:
/// touches only the kind array during scan.
pub const PrimKindIter = struct {
    kinds: []const DeviceKind,
    target: DeviceKind,
    pos: usize = 0,

    /// Returns prim index, not a full struct. Caller reads specific
    /// SoA fields at that index.
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

/// Global PDK registry singleton. Populated by the loader at startup;
/// consulted by the netlister and GUI at runtime.
pub var global_registry: PdkDeviceRegistry = .{};

// ── Tests ───────────────────────────────────────────────────────────────── //

test "DeviceKind round-trip via StaticStringMap" {
    try std.testing.expectEqual(DeviceKind.mosfet, DeviceKind.fromStr("mosfet"));
    try std.testing.expectEqual(DeviceKind.unknown, DeviceKind.fromStr("bogus"));
    try std.testing.expectEqualStrings("resistor", DeviceKind.resistor.toStr());
}

test "builtin LUT O(1)" {
    const r = getBuiltinDevice(.resistor).?;
    try std.testing.expectEqual(@as(u8, 'R'), r.prefix);
    try std.testing.expectEqual(@as(?SpiceDevice, null), getBuiltinDevice(.mosfet));
}

test "non-electrical and injected net" {
    try std.testing.expect(DeviceKind.gnd.isNonElectrical());
    try std.testing.expect(!DeviceKind.resistor.isNonElectrical());
    try std.testing.expectEqualStrings("0", DeviceKind.gnd.injectedNetName().?);
    try std.testing.expectEqual(@as(?[]const u8, null), DeviceKind.resistor.injectedNetName());
}

test "register primitive + 1-to-1 enforcement" {
    const a = std.testing.allocator;
    var reg = PdkDeviceRegistry{};
    defer reg.deinit(a);

    try reg.addPrimitive(a, .{
        .cell_name = "nfet_01v8",
        .sym_path = "/sym/nfet_01v8.chn_sym",
        .library = "sky130_fd_pr",
        .kind = .mosfet,
        .prefix = 'M',
        .format = .semiconductor,
        .pin_order = &.{ "d", "g", "s", "b" },
        .model_name = "nfet_01v8",
        .default_params = &.{ .{ .key = "w", .val = "0.42" }, .{ .key = "l", .val = "0.15" } },
        .lib_includes = &.{.{ .path = "/pdk/sky130.lib.spice", .has_sections = true }},
    });

    // Lookup by name
    const ref = reg.find("nfet_01v8").?;
    try std.testing.expectEqual(CellTier.prim, ref.tier);
    const dev = reg.spiceDeviceAt(ref.idx);
    try std.testing.expectEqual(@as(u8, 'M'), dev.prefix);
    try std.testing.expectEqual(DeviceKind.mosfet, dev.kind);

    // resolveDevice full chain
    const dev2 = reg.resolveDevice("nfet_01v8", .unknown).?;
    try std.testing.expectEqual(@as(u8, 'M'), dev2.prefix);

    // 1-to-1: duplicate name errors
    const dup = reg.addPrimitive(a, .{
        .cell_name = "nfet_01v8",
        .sym_path = "/dup",
        .library = "x",
        .kind = .mosfet,
        .prefix = 'M',
        .format = .semiconductor,
        .pin_order = &.{ "d", "g", "s", "b" },
        .model_name = "nfet_01v8",
        .default_params = &.{},
        .lib_includes = &.{},
    });
    try std.testing.expectEqual(@as(anyerror, error.DuplicateCellName), dup);
}

test "register component + classify" {
    const a = std.testing.allocator;
    var reg = PdkDeviceRegistry{};
    defer reg.deinit(a);

    try reg.addComponent(a, .{
        .cell_name = "inv_1",
        .sym_path = "/cells/inv_1.chn",
        .sch_path = "/cells/inv_1.sch",
        .library = "sky130_fd_sc_hd",
        .pin_order = &.{ "A", "Y", "VPWR", "VGND" },
    });

    try std.testing.expectEqual(CellTier.comp, reg.classify("inv_1"));
    try std.testing.expectEqual(CellTier.unregistered, reg.classify("bogus"));

    // resolveDevice returns null for components — caller handles X-line
    try std.testing.expectEqual(@as(?SpiceDevice, null), reg.resolveDevice("inv_1", .unknown));

    // 1-to-1: can't add a prim with same name as a comp
    const dup = reg.addPrimitive(a, .{
        .cell_name = "inv_1",
        .sym_path = "/x",
        .library = "x",
        .kind = .subckt,
        .prefix = 'X',
        .format = .subcircuit,
        .pin_order = &.{},
        .model_name = null,
        .default_params = &.{},
        .lib_includes = &.{},
    });
    try std.testing.expectEqual(@as(anyerror, error.DuplicateCellName), dup);
}

test "resolveDevice falls through to builtin" {
    const a = std.testing.allocator;
    var reg = PdkDeviceRegistry{};
    defer reg.deinit(a);

    // No PDK entries — falls through to builtin resistor
    const r = reg.resolveDevice("some_res", .resistor).?;
    try std.testing.expectEqual(@as(u8, 'R'), r.prefix);

    // mosfet has no builtin — null
    try std.testing.expectEqual(@as(?SpiceDevice, null), reg.resolveDevice("some_mos", .mosfet));
}

test "collect lib includes deduplicates" {
    const a = std.testing.allocator;
    var reg = PdkDeviceRegistry{};
    defer reg.deinit(a);

    const shared = LibInclude{ .path = "/pdk/sky130.lib.spice", .has_sections = true };
    const extra = LibInclude{ .path = "/pdk/extra.spice", .has_sections = false };
    const mos = &[_][]const u8{ "d", "g", "s", "b" };

    try reg.addPrimitive(a, .{ .cell_name = "nfet", .sym_path = "/a", .library = "pr", .kind = .mosfet, .prefix = 'M', .format = .semiconductor, .pin_order = mos, .model_name = "nfet", .default_params = &.{}, .lib_includes = &.{ shared, extra } });
    try reg.addPrimitive(a, .{ .cell_name = "pfet", .sym_path = "/b", .library = "pr", .kind = .mosfet, .prefix = 'M', .format = .semiconductor, .pin_order = mos, .model_name = "pfet", .default_params = &.{}, .lib_includes = &.{shared} });

    const names = &[_][]const u8{ "nfet", "pfet" };
    const libs = try reg.collectLibIncludes(a, names);
    defer a.free(libs);
    // shared deduped → 2 unique (shared + extra), not 3
    try std.testing.expectEqual(@as(usize, 2), libs.len);
}

test "emitPreamble ngspice" {
    const a = std.testing.allocator;
    var reg = PdkDeviceRegistry{};
    defer reg.deinit(a);

    const mos = &[_][]const u8{ "d", "g", "s", "b" };
    try reg.addPrimitive(a, .{ .cell_name = "nfet", .sym_path = "/a", .library = "pr", .kind = .mosfet, .prefix = 'M', .format = .semiconductor, .pin_order = mos, .model_name = "nfet", .default_params = &.{}, .lib_includes = &.{
        .{ .path = "/pdk/sky130.lib.spice", .has_sections = true },
        .{ .path = "/pdk/corners.spice", .has_sections = false },
    } });

    const names = &[_][]const u8{"nfet"};
    const preamble = try reg.emitPreamble(a, names, null);
    defer a.free(preamble);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".lib \"/pdk/sky130.lib.spice\" tt") != null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".include \"/pdk/corners.spice\"") != null);
}

test "emitPreamble xyce with corner override" {
    const a = std.testing.allocator;
    var reg = PdkDeviceRegistry{ .dialect = .xyce };
    defer reg.deinit(a);

    const mos = &[_][]const u8{ "d", "g", "s", "b" };
    try reg.addPrimitive(a, .{ .cell_name = "nfet", .sym_path = "/a", .library = "pr", .kind = .mosfet, .prefix = 'M', .format = .semiconductor, .pin_order = mos, .model_name = "nfet", .default_params = &.{}, .lib_includes = &.{
        .{ .path = "/pdk/models.lib.spice", .has_sections = true },
    } });

    const names = &[_][]const u8{"nfet"};
    const preamble = try reg.emitPreamble(a, names, "ff");
    defer a.free(preamble);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".LIB \"/pdk/models.lib.spice\" ff") != null);
}

test "kind iterator yields indices" {
    const a = std.testing.allocator;
    var reg = PdkDeviceRegistry{};
    defer reg.deinit(a);

    const mos = &[_][]const u8{ "d", "g", "s", "b" };
    const dio = &[_][]const u8{ "p", "n" };
    try reg.addPrimitive(a, .{ .cell_name = "nfet_01v8", .sym_path = "/a", .library = "pr", .kind = .mosfet, .prefix = 'M', .format = .semiconductor, .pin_order = mos, .model_name = "nfet_01v8", .default_params = &.{}, .lib_includes = &.{} });
    try reg.addPrimitive(a, .{ .cell_name = "pfet_01v8", .sym_path = "/b", .library = "pr", .kind = .mosfet, .prefix = 'M', .format = .semiconductor, .pin_order = mos, .model_name = "pfet_01v8", .default_params = &.{}, .lib_includes = &.{} });
    try reg.addPrimitive(a, .{ .cell_name = "diode_pw", .sym_path = "/c", .library = "pr", .kind = .diode, .prefix = 'D', .format = .semiconductor, .pin_order = dio, .model_name = "diode_pw", .default_params = &.{}, .lib_includes = &.{} });

    var it = reg.iterPrimsByKind(.mosfet);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 2), n);

    var dit = reg.iterPrimsByKind(.diode);
    n = 0;
    while (dit.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "empty registry" {
    const reg = PdkDeviceRegistry{};
    try std.testing.expect(reg.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), reg.totalCells());
    try std.testing.expectEqual(CellTier.unregistered, reg.classify("anything"));
}

test "CellRef packs into u32" {
    const ref = CellRef{ .idx = 42, .tier = .comp };
    const as_u32: u32 = @bitCast(ref);
    const back: CellRef = @bitCast(as_u32);
    try std.testing.expectEqual(@as(u30, 42), back.idx);
    try std.testing.expectEqual(CellTier.comp, back.tier);
}
