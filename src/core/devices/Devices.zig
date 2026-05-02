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
const spice = @import("../simulation/SpiceIF.zig");
pub const Backend = spice.Backend;
pub const Value = spice.Value;
pub const SpiceComponent = spice.SpiceComponent;
pub const ParamOverride = spice.ParamOverride;
pub const emitComponent = spice.emitComponent;
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

    pub fn emitSpice(self: *const Device, writer: anytype, inst_name: []const u8, nets: []const []const u8, params: []const ParamOverride, backend: Backend) !void {
        const comp = try self.toSpiceComponent(inst_name, nets, params);
        try emitComponent(writer, comp, backend);
    }

    pub fn toSpiceComponent(self: *const Device, inst_name: []const u8, nets: []const []const u8, params: []const ParamOverride) !SpiceComponent {
        if (nets.len < self.pin_order.len) return error.NotEnoughNets;

        return switch (self.kind) {
            .resistor, .resistor3, .var_resistor => .{ .resistor = .{
                .name = inst_name, .p = nets[0], .n = nets[1],
                .value = findParam(params, "value") orelse Value{ .literal = 0 },
                .m = findParamStr(params, "m"),
            } },
            .capacitor => .{ .capacitor = .{
                .name = inst_name, .p = nets[0], .n = nets[1],
                .value = findParam(params, "value") orelse Value{ .literal = 0 },
                .ic = findParamF64(params, "ic"),
            } },
            .inductor => .{ .inductor = .{
                .name = inst_name, .p = nets[0], .n = nets[1],
                .value = findParam(params, "value") orelse Value{ .literal = 0 },
                .ic = findParamF64(params, "ic"),
            } },
            .diode, .zener => .{ .diode = .{
                .name = inst_name, .anode = nets[0], .cathode = nets[1],
                .model = self.model_name orelse findParamStr(params, "model") orelse "D",
            } },
            .nmos3, .pmos3, .nmos_sub, .pmos_sub => .{ .mosfet = .{
                .name = inst_name, .drain = nets[0], .gate = nets[1], .source = nets[2], .bulk = nets[2],
                .model = self.model_name orelse findParamStr(params, "model") orelse "NMOS",
                .w = findParam(params, "W"), .l = findParam(params, "L"), .m = findParamF64(params, "M"),
            } },
            .nmos4, .pmos4, .nmos4_depl, .nmoshv4, .pmoshv4, .rnmos4 => .{ .mosfet = .{
                .name = inst_name, .drain = nets[0], .gate = nets[1], .source = nets[2], .bulk = nets[3],
                .model = self.model_name orelse findParamStr(params, "model") orelse "NMOS",
                .w = findParam(params, "W"), .l = findParam(params, "L"), .m = findParamF64(params, "M"),
            } },
            .npn, .pnp => .{ .bjt = .{
                .name = inst_name, .collector = nets[0], .base = nets[1], .emitter = nets[2],
                .substrate = if (nets.len >= 4) nets[3] else null,
                .model = self.model_name orelse findParamStr(params, "model") orelse "NPN",
            } },
            .njfet, .pjfet => .{ .jfet = .{
                .name = inst_name, .drain = nets[0], .gate = nets[1], .source = nets[2],
                .model = self.model_name orelse findParamStr(params, "model") orelse "NJF",
            } },
            .vsource, .ammeter, .sqwsource => blk: {
                if (findParamStr(params, "spice_waveform")) |wf| {
                    const line = std.fmt.allocPrint(std.heap.page_allocator, "{s} {s} {s} {s}\n", .{ inst_name, nets[0], nets[1], wf }) catch inst_name;
                    break :blk .{ .raw = line };
                }
                break :blk .{ .independent_source = .{
                    .name = inst_name, .kind = .voltage, .p = nets[0], .n = nets[1],
                    .dc = findParamF64(params, "dc"),
                } };
            },
            .isource => .{ .independent_source = .{
                .name = inst_name, .kind = .current, .p = nets[0], .n = nets[1],
                .dc = findParamF64(params, "dc"),
            } },
            .behavioral => blk: {
                const expr = findParamStr(params, "expr") orelse findParamStr(params, "value") orelse "0";
                const kind_str = findParamStr(params, "bkind") orelse "V";
                break :blk .{ .behavioral = .{
                    .name = inst_name,
                    .kind = if (kind_str[0] == 'I') .current else .voltage,
                    .p = if (nets.len > 0) nets[0] else "0",
                    .n = if (nets.len > 1) nets[1] else "0",
                    .expr = expr,
                } };
            },
            .vcvs => .{ .vcvs = .{
                .name = inst_name, .p = nets[0], .n = nets[1], .cp = nets[2], .cn = nets[3],
                .gain = findParam(params, "gain") orelse findParam(params, "value") orelse Value{ .literal = 1.0 },
            } },
            .vccs => .{ .vccs = .{
                .name = inst_name, .p = nets[0], .n = nets[1], .cp = nets[2], .cn = nets[3],
                .gain = findParam(params, "gain") orelse findParam(params, "value") orelse Value{ .literal = 1.0 },
            } },
            .ccvs => .{ .ccvs = .{
                .name = inst_name, .p = nets[0], .n = nets[1],
                .vsrc = findParamStr(params, "vsrc") orelse "V0",
                .gain = findParam(params, "gain") orelse findParam(params, "value") orelse Value{ .literal = 1.0 },
            } },
            .cccs => .{ .cccs = .{
                .name = inst_name, .p = nets[0], .n = nets[1],
                .vsrc = findParamStr(params, "vsrc") orelse "V0",
                .gain = findParam(params, "gain") orelse findParam(params, "value") orelse Value{ .literal = 1.0 },
            } },
            .subckt, .digital_instance, .mesfet => .{ .subcircuit = .{
                .name = self.model_name orelse inst_name,
                .inst_name = inst_name,
                .nodes = nets,
                .params = params,
            } },
            else => return error.NonElectricalDevice,
        };
    }

    fn findParam(params: []const ParamOverride, key: []const u8) ?Value {
        for (params) |p| if (std.mem.eql(u8, p.name, key)) return p.value;
        return null;
    }
    fn findParamStr(params: []const ParamOverride, key: []const u8) ?[]const u8 {
        for (params) |p| if (std.mem.eql(u8, p.name, key)) return switch (p.value) {
            .param => |s| s, .expr => |s| s, .literal => null,
        };
        return null;
    }
    fn findParamF64(params: []const ParamOverride, key: []const u8) ?f64 {
        for (params) |p| if (std.mem.eql(u8, p.name, key)) return switch (p.value) {
            .literal => |v| v, else => null,
        };
        return null;
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
    dialect: Backend = .ngspice,
    prims: MAL(Prim) = .{},
    comps: MAL(Comp) = .{},
    tbs: MAL(Tb) = .{},
    name_idx: List(NameEntry) = .{},

    pub fn deinit(self: *Pdk, a: Allocator) void {
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

// ═════════════════════════════════════════════════════════════════════════════
// Global PDK singleton
// ═════════════════════════════════════════════════════════════════════════════

pub var global_pdk: Pdk = .{};

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
