//! Devices.zig — Device catalog and PDK cell library
//!
//! Provides:
//!   - DeviceEntry: comptime device table built from .chn_prim files + builtins
//!   - Device: runtime-resolved device with SPICE emission
//!   - Pdk: PDK cell library with binary-search lookup
//!   - DeviceKind enum methods via comptime LUTs

const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;

const types = @import("../types.zig");
const DeviceKind = types.DeviceKind;

pub const primitives = @import("primitives.zig");

// ═════════════════════════════════════════════════════════════════════════════
// Device — runtime-resolved device entry
// ═════════════════════════════════════════════════════════════════════════════

pub const Device = struct {
    kind: DeviceKind,
    prefix: u8,
    pin_order: []const []const u8,
    model_name: ?[]const u8,
    default_params: []const ParamDefault,

    pub fn fromBuiltin(kind: DeviceKind) ?Device {
        const p = prefix_lut[@intFromEnum(kind)];
        if (p == 0) return null;
        return .{ .kind = kind, .prefix = p, .pin_order = pins_lut[@intFromEnum(kind)], .model_name = null, .default_params = &.{} };
    }

    pub fn fromPdk(pdk: *const Pdk, cell_name: []const u8, fallback: DeviceKind) ?Device {
        return pdk.resolve(cell_name, fallback);
    }
};

// ═════════════════════════════════════════════════════════════════════════════
// PDK Cell Library
// ═════════════════════════════════════════════════════════════════════════════

pub const LibInclude = struct {
    path: []const u8,
    has_sections: bool,
};

pub const Pdk = struct {
    name: []const u8 = "",
    default_corner: []const u8 = "tt",
    prims: MAL(Prim) = .{},
    comps: MAL(Comp) = .{},
    tbs: MAL(Tb) = .{},
    name_idx: List(NameEntry) = .{},

    pub fn deinit(self: *Pdk, a: Allocator) void {
        if (self.name.len > 0) a.free(self.name);
        // Free owned strings in prims
        const ps = self.prims.slice();
        for (0..self.prims.len) |i| {
            const cell = ps.items(.cell_name)[i];
            const file = ps.items(.file)[i];
            const model = ps.items(.model_name)[i];
            const pins = ps.items(.pin_order)[i];
            for (pins) |p| if (p.len > 0) a.free(p);
            if (pins.len > 0) a.free(pins);
            if (file.len > 0) a.free(file);
            // model_name may alias cell_name
            if (model) |m| if (m.ptr != cell.ptr and m.len > 0) a.free(m);
            if (cell.len > 0) a.free(cell);
        }
        self.prims.deinit(a);
        self.comps.deinit(a);
        self.tbs.deinit(a);
        self.name_idx.deinit(a);
    }

    pub fn find(self: *const Pdk, cell_name: []const u8) ?CellRef {
        const pos = self.lowerBound(cell_name);
        if (pos < self.name_idx.items.len and std.mem.eql(u8, self.name_idx.items[pos].name, cell_name))
            return self.name_idx.items[pos].ref;
        return null;
    }

    pub fn classify(self: *const Pdk, cell_name: []const u8) CellTier {
        return if (self.find(cell_name)) |ref| ref.tier else .unregistered;
    }

    pub fn resolvedAt(self: *const Pdk, idx: u30) Device {
        const s = self.prims.slice();
        return .{
            .kind = s.items(.kind)[idx], .prefix = s.items(.prefix)[idx],
            .pin_order = s.items(.pin_order)[idx], .model_name = s.items(.model_name)[idx],
            .default_params = s.items(.default_params)[idx],
        };
    }

    pub fn resolve(self: *const Pdk, cell_name: []const u8, fallback: DeviceKind) ?Device {
        if (self.find(cell_name)) |ref| {
            if (ref.tier == .prim) return self.resolvedAt(ref.idx);
            return null;
        }
        return Device.fromBuiltin(fallback);
    }

    pub fn addPrimitive(self: *Pdk, a: Allocator, e: Prim) !void { try self.addEntry(a, .prim, e.cell_name, e); }
    pub fn addComponent(self: *Pdk, a: Allocator, e: Comp) !void { try self.addEntry(a, .comp, e.cell_name, e); }
    pub fn addTestbench(self: *Pdk, a: Allocator, e: Tb) !void { try self.addEntry(a, .tb, e.cell_name, e); }
    pub fn isEmpty(self: *const Pdk) bool { return self.prims.len + self.comps.len + self.tbs.len == 0; }
    pub fn primCount(self: *const Pdk) usize { return self.prims.len; }

    pub fn emitPreamble(self: *const Pdk, a: Allocator, cell_names: []const []const u8, corner_override: ?[]const u8) ![]u8 {
        const corner = corner_override orelse self.default_corner;
        const includes = try self.collectLibIncludes(a, cell_names);
        defer a.free(includes);
        var buf: List(u8) = .{};
        errdefer buf.deinit(a);
        const w = buf.writer(a);
        for (includes) |inc| {
            if (inc.has_sections)
                try w.print(".lib \"{s}\" {s}\n", .{ inc.path, corner })
            else
                try w.print(".include \"{s}\"\n", .{inc.path});
        }
        return buf.toOwnedSlice(a);
    }

    pub fn collectLibIncludes(self: *const Pdk, a: Allocator, cell_names: []const []const u8) ![]const LibInclude {
        var seen = std.StringHashMapUnmanaged(void){};
        defer seen.deinit(a);
        var out: List(LibInclude) = .{};
        errdefer out.deinit(a);
        const libs = self.prims.slice().items(.lib_includes);
        for (cell_names) |name| {
            const ref = self.find(name) orelse continue;
            if (ref.tier != .prim) continue;
            for (libs[ref.idx]) |inc| {
                const gop = try seen.getOrPut(a, inc.path);
                if (!gop.found_existing) try out.append(a, inc);
            }
        }
        return out.toOwnedSlice(a);
    }

    pub fn libsForCell(self: *const Pdk, cell_name: []const u8) []const LibInclude {
        const ref = self.find(cell_name) orelse return &.{};
        if (ref.tier != .prim) return &.{};
        return self.prims.slice().items(.lib_includes)[ref.idx];
    }

    pub fn getComponent(self: *const Pdk, idx: u30) Comp {
        const s = self.comps.slice();
        return .{
            .cell_name = s.items(.cell_name)[idx], .file = s.items(.file)[idx],
            .library = s.items(.library)[idx], .pin_order = s.items(.pin_order)[idx],
        };
    }

    // ── Private ──

    fn lowerBound(self: *const Pdk, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.name_idx.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.name_idx.items[mid].name, key) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn nameInsert(self: *Pdk, a: Allocator, key: []const u8, ref: CellRef) !void {
        const pos = self.lowerBound(key);
        if (pos < self.name_idx.items.len and std.mem.eql(u8, self.name_idx.items[pos].name, key))
            return error.DuplicateCellName;
        try self.name_idx.insert(a, pos, .{ .name = key, .ref = ref });
    }

    fn addEntry(self: *Pdk, a: Allocator, comptime tier: CellTier, cell_name: []const u8, entry: anytype) !void {
        const mal = switch (tier) { .prim => &self.prims, .comp => &self.comps, .tb => &self.tbs, .unregistered => unreachable };
        const idx: u30 = @intCast(mal.len);
        try self.nameInsert(a, cell_name, .{ .idx = idx, .tier = tier });
        mal.append(a, entry) catch |err| {
            _ = self.name_idx.orderedRemove(self.lowerBound(cell_name));
            return err;
        };
    }
};

// ═════════════════════════════════════════════════════════════════════════════
// PDK private types
// ═════════════════════════════════════════════════════════════════════════════

const ParamDefault = struct { key: []const u8, val: []const u8 };
const NameEntry = struct { name: []const u8, ref: CellRef };
const CellTier = enum(u2) { prim = 0, comp = 1, tb = 2, unregistered = 3 };
const CellRef = packed struct(u32) { idx: u30, tier: CellTier };

pub const Prim = struct {
    cell_name: []const u8, file: []const u8, library: []const u8,
    kind: DeviceKind, prefix: u8, pin_order: []const []const u8,
    model_name: ?[]const u8, default_params: []const ParamDefault,
    lib_includes: []const LibInclude,
};
pub const Comp = struct {
    cell_name: []const u8, file: []const u8, library: []const u8,
    pin_order: []const []const u8,
};
pub const Tb = struct { cell_name: []const u8, file: []const u8, library: []const u8 };

// ═════════════════════════════════════════════════════════════════════════════
// Comptime device table
// ═════════════════════════════════════════════════════════════════════════════

const DeviceEntry = struct {
    kind: DeviceKind,
    prefix: u8 = 0,
    pins: []const []const u8 = &.{},
    model_keyword: ?[]const u8 = null,
    injected_net: ?[]const u8 = null,
    non_electrical: bool = false,
    block_type: []const u8 = "",
};

const PrimEntryRef = primitives.PrimEntry;

fn primToDeviceEntry(comptime p: PrimEntryRef) DeviceEntry {
    return .{
        .kind = std.meta.stringToEnum(DeviceKind, p.kind_name) orelse .unknown,
        .prefix = p.prefix,
        .pins = p.pin_storage[0..p.pin_count],
        .model_keyword = p.model_keyword,
        .injected_net = p.injected_net,
        .non_electrical = p.non_electrical,
        .block_type = p.block_type,
    };
}

const builtin_entries = [_]DeviceEntry{
    .{ .kind = .var_resistor, .prefix = 'R', .pins = &.{ "p", "n" } },
    .{ .kind = .nmos4_depl, .prefix = 'M', .pins = &.{ "d", "g", "s", "b" }, .model_keyword = "NMOS" },
    .{ .kind = .nmos_sub, .prefix = 'M', .pins = &.{ "d", "g", "s" }, .model_keyword = "NMOS" },
    .{ .kind = .pmos_sub, .prefix = 'M', .pins = &.{ "d", "g", "s" }, .model_keyword = "PMOS" },
    .{ .kind = .nmoshv4, .prefix = 'M', .pins = &.{ "d", "g", "s", "b" }, .model_keyword = "NMOS" },
    .{ .kind = .pmoshv4, .prefix = 'M', .pins = &.{ "d", "g", "s", "b" }, .model_keyword = "PMOS" },
    .{ .kind = .rnmos4, .prefix = 'M', .pins = &.{ "d", "g", "s", "b" }, .model_keyword = "NMOS" },
    .{ .kind = .mesfet, .prefix = 'Z', .pins = &.{ "d", "g", "s" }, .model_keyword = "NMF" },
    .{ .kind = .sqwsource, .prefix = 'V', .pins = &.{ "p", "m" } },
    .{ .kind = .tline_lossy, .prefix = 'O', .pins = &.{ "p1p", "p1n", "p2p", "p2n" }, .model_keyword = "LTRA" },
    .{ .kind = .param, .non_electrical = true },
    .{ .kind = .probe_diff, .non_electrical = true },
    .{ .kind = .code, .non_electrical = true },
    .{ .kind = .graph, .non_electrical = true },
    .{ .kind = .hdl, .non_electrical = true },
    .{ .kind = .annotation, .non_electrical = true },
    .{ .kind = .noconn, .non_electrical = true },
    .{ .kind = .title, .non_electrical = true },
    .{ .kind = .launcher, .non_electrical = true },
    .{ .kind = .rgb_led, .non_electrical = true },
    .{ .kind = .generic, .non_electrical = true },
    .{ .kind = .digital_instance, .prefix = 'X' },
    .{ .kind = .subckt, .prefix = 'X' },
};

const device_table: []const DeviceEntry = blk: {
    @setEvalBranchQuota(100_000);
    const pc = primitives.prim_count;
    const total = pc + builtin_entries.len;
    var table: [total]DeviceEntry = undefined;
    for (primitives.parsed_prims, 0..) |p, i| table[i] = primToDeviceEntry(p);
    for (builtin_entries, 0..) |le, i| table[pc + i] = le;
    const final = table;
    break :blk &final;
};

// ═════════════════════════════════════════════════════════════════════════════
// DeviceKind LUT extensions
// ═════════════════════════════════════════════════════════════════════════════

// These extend the DeviceKind enum defined in types.zig with data from
// the device_table.  We cannot add methods to an imported enum, so we
// provide free functions and a pub namespace.

const N = @typeInfo(DeviceKind).@"enum".fields.len;

pub const prefix_lut: [N]u8 = blk: {
    var lut = [1]u8{0} ** N;
    for (device_table) |e| lut[@intFromEnum(e.kind)] = e.prefix;
    break :blk lut;
};
pub const pins_lut: [N][]const []const u8 = blk: {
    const empty: []const []const u8 = &.{};
    var lut = [1][]const []const u8{empty} ** N;
    for (device_table) |e| lut[@intFromEnum(e.kind)] = e.pins;
    break :blk lut;
};
pub const model_keyword_lut: [N]?[]const u8 = blk: {
    var lut = [1]?[]const u8{null} ** N;
    for (device_table) |e| lut[@intFromEnum(e.kind)] = e.model_keyword;
    break :blk lut;
};
pub const non_electrical_lut: [N]bool = blk: {
    var lut = [1]bool{false} ** N;
    for (device_table) |e| lut[@intFromEnum(e.kind)] = e.non_electrical;
    break :blk lut;
};
pub const injected_net_lut: [N]?[]const u8 = blk: {
    var lut = [1]?[]const u8{null} ** N;
    for (device_table) |e| lut[@intFromEnum(e.kind)] = e.injected_net;
    break :blk lut;
};

pub const symbol_lut: [N][]const u8 = blk: {
    var lut = [1][]const u8{"vsource"} ** N;
    lut[@intFromEnum(DeviceKind.resistor)] = "res";
    lut[@intFromEnum(DeviceKind.resistor3)] = "res";
    lut[@intFromEnum(DeviceKind.var_resistor)] = "res";
    lut[@intFromEnum(DeviceKind.capacitor)] = "capa";
    lut[@intFromEnum(DeviceKind.inductor)] = "ind";
    lut[@intFromEnum(DeviceKind.diode)] = "diode";
    lut[@intFromEnum(DeviceKind.zener)] = "zener";
    lut[@intFromEnum(DeviceKind.nmos3)] = "nmos4";
    lut[@intFromEnum(DeviceKind.pmos3)] = "pmos4";
    lut[@intFromEnum(DeviceKind.nmos4)] = "nmos4";
    lut[@intFromEnum(DeviceKind.pmos4)] = "pmos4";
    lut[@intFromEnum(DeviceKind.nmos4_depl)] = "nmos4";
    lut[@intFromEnum(DeviceKind.nmos_sub)] = "nmos4";
    lut[@intFromEnum(DeviceKind.pmos_sub)] = "pmos4";
    lut[@intFromEnum(DeviceKind.nmoshv4)] = "nmos4";
    lut[@intFromEnum(DeviceKind.pmoshv4)] = "pmos4";
    lut[@intFromEnum(DeviceKind.rnmos4)] = "nmos4";
    lut[@intFromEnum(DeviceKind.npn)] = "npn";
    lut[@intFromEnum(DeviceKind.pnp)] = "pnp";
    lut[@intFromEnum(DeviceKind.njfet)] = "njfet";
    lut[@intFromEnum(DeviceKind.pjfet)] = "pjfet";
    lut[@intFromEnum(DeviceKind.mesfet)] = "mesfet";
    lut[@intFromEnum(DeviceKind.vsource)] = "vsource";
    lut[@intFromEnum(DeviceKind.isource)] = "isource";
    lut[@intFromEnum(DeviceKind.ammeter)] = "ammeter";
    lut[@intFromEnum(DeviceKind.behavioral)] = "vsource";
    lut[@intFromEnum(DeviceKind.vcvs)] = "vcvs";
    lut[@intFromEnum(DeviceKind.vccs)] = "vccs";
    lut[@intFromEnum(DeviceKind.ccvs)] = "ccvs";
    lut[@intFromEnum(DeviceKind.cccs)] = "cccs";
    lut[@intFromEnum(DeviceKind.coupling)] = "coupling";
    lut[@intFromEnum(DeviceKind.tline)] = "tline";
    lut[@intFromEnum(DeviceKind.vswitch)] = "vswitch";
    lut[@intFromEnum(DeviceKind.iswitch)] = "iswitch";
    lut[@intFromEnum(DeviceKind.probe)] = "probe";
    lut[@intFromEnum(DeviceKind.gnd)] = "gnd";
    lut[@intFromEnum(DeviceKind.vdd)] = "vdd";
    lut[@intFromEnum(DeviceKind.input_pin)] = "ipin";
    lut[@intFromEnum(DeviceKind.output_pin)] = "opin";
    lut[@intFromEnum(DeviceKind.inout_pin)] = "iopin";
    lut[@intFromEnum(DeviceKind.noconn)] = "noconn";
    lut[@intFromEnum(DeviceKind.generic)] = "generic";
    lut[@intFromEnum(DeviceKind.subckt)] = "subckt";
    break :blk lut;
};

pub fn symbolForKind(kind: DeviceKind) []const u8 {
    return symbol_lut[@intFromEnum(kind)];
}

// NOTE: The PDK is owned by AppState.pdk, not as a global singleton.
// All call sites must receive it explicitly via function parameters.

// ═════════════════════════════════════════════════════════════════════════════
// Tests
// ═════════════════════════════════════════════════════════════════════════════

test "nmos4 prefix from LUT" {
    try std.testing.expectEqual(@as(u8, 'M'), prefix_lut[@intFromEnum(DeviceKind.nmos4)]);
}

test "resistor pins from LUT" {
    const r_pins = pins_lut[@intFromEnum(DeviceKind.resistor)];
    try std.testing.expectEqual(@as(usize, 2), r_pins.len);
    try std.testing.expectEqualStrings("p", r_pins[0]);
}

test "Device.fromBuiltin null for non-electrical" {
    try std.testing.expect(Device.fromBuiltin(.gnd) == null);
    try std.testing.expect(Device.fromBuiltin(.nmos4) != null);
}

test "symbolForKind" {
    try std.testing.expectEqualStrings("res", symbolForKind(.resistor));
    try std.testing.expectEqualStrings("nmos4", symbolForKind(.nmos4));
    try std.testing.expectEqualStrings("pmos4", symbolForKind(.pmos4));
    try std.testing.expectEqualStrings("pnp", symbolForKind(.pnp));
    try std.testing.expectEqualStrings("ammeter", symbolForKind(.ammeter));
    try std.testing.expectEqualStrings("gnd", symbolForKind(.gnd));
    try std.testing.expectEqualStrings("subckt", symbolForKind(.subckt));
}
