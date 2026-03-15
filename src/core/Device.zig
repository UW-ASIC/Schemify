//! Device Definitions + PDK Cell Registry (leaf — zero project imports).
//!
//! Data-oriented design:
//!   - Builtin devices: comptime LUTs on DeviceKind (O(1), zero runtime heap)
//!   - PDK cells:       flat SoA via MultiArrayList (runtime, sorted name index)
//!
//! Model vs Subcircuit distinction:
//!   - kind.needsModel()   → true for D, Q, M, J, Z, S, W, O (need .model card)
//!   - kind.isSubcircuit() → true for subckt (need .subckt block)
//!   - else                → value-only (R, C, L, V, I, B, E, F, G, H, K, T)
//!
//! Resolve chain:
//!   1. pdk.find(cell_name) → ?CellRef  (PDK prim or comp)
//!   2. DeviceKind comptime methods      (builtin fallback)
//!   3. unresolved → comment placeholder

const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;

// ── SPICE dialect ──────────────────────────────────────────────────────────── //

pub const SpiceDialect = enum { ngspice, xyce };

// ── Public aux types ───────────────────────────────────────────────────────── //

pub const ParamDefault = struct { key: []const u8, val: []const u8 };

pub const LibInclude = struct {
    path: []const u8,
    /// true → `.lib "path" <corner>`, false → `.include "path"`
    has_sections: bool,
};

// ── DeviceKind ─────────────────────────────────────────────────────────────── //

pub const DeviceKind = enum(u8) {
    unknown,
    // ── Value-only (no .model, no .include needed) ──
    resistor,
    capacitor,
    inductor,
    vsource,
    isource,
    ammeter,
    behavioral, // B-source
    vcvs, // E
    vccs, // G
    cccs, // F
    ccvs, // H
    coupling, // K (mutual inductor)
    tline, // T (lossless transmission line)
    // ── Model-reference (needs .model card, no .include) ──
    diode, // D
    mosfet, // M
    bjt, // Q
    jfet, // J
    mesfet, // Z
    vswitch, // S (voltage-controlled switch)
    iswitch, // W (current-controlled switch)
    tline_lossy, // O (LTRA model)
    // ── Non-electrical / UI ──
    gnd,
    vdd,
    lab_pin,
    code,
    graph,
    // ── Hierarchical ──
    subckt,

    // ── Comptime accessors (O(1) via rodata LUTs) ─────────────────────── //

    /// SPICE instance prefix letter. 0 = non-electrical / no prefix.
    pub fn prefix(self: DeviceKind) u8 {
        return prefix_lut[@intFromEnum(self)];
    }

    /// Default pin names for builtin devices. Empty for non-electrical/subckt.
    pub fn pins(self: DeviceKind) []const []const u8 {
        return pins_lut[@intFromEnum(self)];
    }

    /// Does this kind require a `.model` card?
    pub fn needsModel(self: DeviceKind) bool {
        return model_keyword_lut[@intFromEnum(self)] != null;
    }

    /// Default `.model` type keyword ("NMOS", "D", "NPN", "SW", …).
    /// null = no model needed (value-only or subcircuit).
    pub fn modelKeyword(self: DeviceKind) ?[]const u8 {
        return model_keyword_lut[@intFromEnum(self)];
    }

    /// Is this a subcircuit reference? (X prefix, .subckt body)
    pub fn isSubcircuit(self: DeviceKind) bool {
        return self == .subckt;
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

    /// O(1) perfect hash lookup via StaticStringMap.
    pub fn fromStr(s: []const u8) DeviceKind {
        return kind_map.get(s) orelse .unknown;
    }

    // ── Comptime LUTs ─────────────────────────────────────────────────── //

    const N = @typeInfo(DeviceKind).@"enum".fields.len;

    const kind_map = blk: {
        const fields = @typeInfo(DeviceKind).@"enum".fields;
        var kvs: [fields.len]struct { []const u8, DeviceKind } = undefined;
        for (fields, 0..) |f, i| kvs[i] = .{ f.name, @as(DeviceKind, @enumFromInt(f.value)) };
        break :blk std.StaticStringMap(DeviceKind).initComptime(kvs);
    };

    const prefix_lut: [N]u8 = blk: {
        var lut = [1]u8{0} ** N;
        const map = .{
            .{ DeviceKind.resistor, 'R' },   .{ DeviceKind.capacitor, 'C' }, .{ DeviceKind.inductor, 'L' },
            .{ DeviceKind.vsource, 'V' },    .{ DeviceKind.isource, 'I' },   .{ DeviceKind.ammeter, 'V' },
            .{ DeviceKind.behavioral, 'B' }, .{ DeviceKind.vcvs, 'E' },      .{ DeviceKind.vccs, 'G' },
            .{ DeviceKind.cccs, 'F' },       .{ DeviceKind.ccvs, 'H' },      .{ DeviceKind.coupling, 'K' },
            .{ DeviceKind.tline, 'T' },      .{ DeviceKind.diode, 'D' },     .{ DeviceKind.mosfet, 'M' },
            .{ DeviceKind.bjt, 'Q' },        .{ DeviceKind.jfet, 'J' },      .{ DeviceKind.mesfet, 'Z' },
            .{ DeviceKind.vswitch, 'S' },    .{ DeviceKind.iswitch, 'W' },   .{ DeviceKind.tline_lossy, 'O' },
            .{ DeviceKind.subckt, 'X' },
        };
        for (map) |entry| lut[@intFromEnum(entry[0])] = entry[1];
        break :blk lut;
    };

    const pins_lut: [N][]const []const u8 = blk: {
        const empty: []const []const u8 = &.{};
        var lut = [1][]const []const u8{empty} ** N;
        const map = .{
            .{ DeviceKind.resistor, &[_][]const u8{ "p", "n" } },
            .{ DeviceKind.capacitor, &[_][]const u8{ "p", "n" } },
            .{ DeviceKind.inductor, &[_][]const u8{ "p", "n" } },
            .{ DeviceKind.diode, &[_][]const u8{ "p", "n" } },
            .{ DeviceKind.vsource, &[_][]const u8{ "p", "m" } },
            .{ DeviceKind.isource, &[_][]const u8{ "p", "n" } },
            .{ DeviceKind.ammeter, &[_][]const u8{ "p", "m" } },
            .{ DeviceKind.behavioral, &[_][]const u8{ "p", "n" } },
            .{ DeviceKind.vcvs, &[_][]const u8{ "p", "n", "cp", "cn" } },
            .{ DeviceKind.vccs, &[_][]const u8{ "p", "n", "cp", "cn" } },
            .{ DeviceKind.ccvs, &[_][]const u8{ "p", "n" } },
            .{ DeviceKind.cccs, &[_][]const u8{ "p", "n" } },
            .{ DeviceKind.vswitch, &[_][]const u8{ "p", "n", "cp", "cn" } },
            .{ DeviceKind.iswitch, &[_][]const u8{ "p", "n" } },
            .{ DeviceKind.mosfet, &[_][]const u8{ "d", "g", "s", "b" } },
            .{ DeviceKind.bjt, &[_][]const u8{ "c", "b", "e" } },
            .{ DeviceKind.jfet, &[_][]const u8{ "d", "g", "s" } },
            .{ DeviceKind.mesfet, &[_][]const u8{ "d", "g", "s" } },
            .{ DeviceKind.tline, &[_][]const u8{ "p1p", "p1n", "p2p", "p2n" } },
            .{ DeviceKind.tline_lossy, &[_][]const u8{ "p1p", "p1n", "p2p", "p2n" } },
        };
        for (map) |entry| lut[@intFromEnum(entry[0])] = entry[1];
        break :blk lut;
    };

    const model_keyword_lut: [N]?[]const u8 = blk: {
        var lut = [1]?[]const u8{null} ** N;
        const map = .{
            .{ DeviceKind.diode, "D" },
            .{ DeviceKind.mosfet, "NMOS" },
            .{ DeviceKind.bjt, "NPN" },
            .{ DeviceKind.jfet, "NJF" },
            .{ DeviceKind.mesfet, "NMF" },
            .{ DeviceKind.vswitch, "SW" },
            .{ DeviceKind.iswitch, "CSW" },
            .{ DeviceKind.tline_lossy, "LTRA" },
        };
        for (map) |entry| lut[@intFromEnum(entry[0])] = entry[1];
        break :blk lut;
    };
};

// ── Flat SoA entry structs ─────────────────────────────────────────────────── //

/// PDK leaf device. MultiArrayList splits into parallel arrays per field.
/// No unions, no enums beyond DeviceKind.
pub const Prim = struct {
    cell_name: []const u8,
    file: []const u8,
    library: []const u8,
    kind: DeviceKind,
    prefix: u8,
    pin_order: []const []const u8,
    model_name: ?[]const u8,
    default_params: []const ParamDefault,
    lib_includes: []const LibInclude,
};

/// Hierarchical subcircuit.
pub const Comp = struct {
    cell_name: []const u8,
    file: []const u8,
    library: []const u8,
    pin_order: []const []const u8,
};

/// Top-level simulation harness.
pub const Tb = struct {
    cell_name: []const u8,
    file: []const u8,
    library: []const u8,
};

// ── CellRef — packed tier+index in one u32 ─────────────────────────────────── //

pub const CellTier = enum(u2) { prim = 0, comp = 1, tb = 2, unregistered = 3 };

/// Packs tier + index into 32 bits. Enforces 1-to-1: one name → one tier.
pub const CellRef = packed struct(u32) {
    idx: u30,
    tier: CellTier,
};

// ── PrimKindIter ───────────────────────────────────────────────────────────── //

/// Yields indices into prims MAL where kind matches. SoA-idiomatic:
/// touches only the kind array during scan.
pub const PrimKindIter = struct {
    kinds: []const DeviceKind,
    target: DeviceKind,
    pos: usize = 0,

    /// Returns prim index, not a full struct. Caller reads specific SoA fields.
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

// ── ResolvedDevice — on-demand view, never stored ──────────────────────────── //

/// Reconstructed on-demand from Pdk.resolve() or DeviceKind comptime methods.
/// NOT stored in any container — this is the "recipe" the netlister uses
/// to emit one SPICE instance line.
pub const ResolvedDevice = struct {
    kind: DeviceKind,
    prefix: u8,
    pin_order: []const []const u8,
    model_name: ?[]const u8,
    default_params: []const ParamDefault,
};

/// Build a ResolvedDevice purely from comptime DeviceKind data (no PDK).
pub fn resolveBuiltin(kind: DeviceKind) ?ResolvedDevice {
    const p = kind.prefix();
    if (p == 0) return null; // non-electrical
    return .{
        .kind = kind,
        .prefix = p,
        .pin_order = kind.pins(),
        .model_name = null,
        .default_params = &.{},
    };
}

// ── Pdk ────────────────────────────────────────────────────────────────────── //

/// Sorted index entry — sorted by cell_name for binary search.
const NameEntry = struct { name: []const u8, ref: CellRef };

/// PDK cell library. Flat SoA storage via MultiArrayList, sorted name index
/// for O(log N) lookup. Enforces 1-to-1: no cell name in more than one tier.
///
/// Loader contract:
///   var pdk = Pdk{};
///   try pdk.addPrimitive(a, .{ .cell_name = "nfet_01v8", ... });
///   try pdk.addComponent(a, .{ .cell_name = "inv_1", ... });
pub const Pdk = struct {
    name: []const u8 = "",
    default_corner: []const u8 = "tt",
    dialect: SpiceDialect = .ngspice,

    prims: MAL(Prim) = .{},
    comps: MAL(Comp) = .{},
    tbs: MAL(Tb) = .{},

    /// Sorted (cell_name, CellRef) pairs — binary search, O(log N).
    name_idx: List(NameEntry) = .{},

    pub fn deinit(self: *Pdk, a: Allocator) void {
        self.prims.deinit(a);
        self.comps.deinit(a);
        self.tbs.deinit(a);
        self.name_idx.deinit(a);
    }

    // ── Binary search ──────────────────────────────────────────────── //

    fn lowerBound(self: *const Pdk, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.name_idx.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.name_idx.items[mid].name, key) == .lt)
                lo = mid + 1
            else
                hi = mid;
        }
        return lo;
    }

    fn nameInsert(self: *Pdk, a: Allocator, key: []const u8, ref: CellRef) !void {
        const pos = self.lowerBound(key);
        if (pos < self.name_idx.items.len and
            std.mem.eql(u8, self.name_idx.items[pos].name, key))
            return error.DuplicateCellName;
        try self.name_idx.insert(a, pos, .{ .name = key, .ref = ref });
    }

    // ── Registration (loader calls these) ──────────────────────────── //

    fn addEntry(
        self: *Pdk,
        a: Allocator,
        comptime tier: CellTier,
        cell_name: []const u8,
        entry: anytype,
    ) !void {
        const mal = switch (tier) {
            .prim => &self.prims,
            .comp => &self.comps,
            .tb => &self.tbs,
            .unregistered => unreachable,
        };
        const idx: u30 = @intCast(mal.len);
        try self.nameInsert(a, cell_name, .{ .idx = idx, .tier = tier });
        mal.append(a, entry) catch |err| {
            _ = self.name_idx.orderedRemove(self.lowerBound(cell_name));
            return err;
        };
    }

    pub fn addPrimitive(self: *Pdk, a: Allocator, e: Prim) !void {
        return self.addEntry(a, .prim, e.cell_name, e);
    }

    pub fn addComponent(self: *Pdk, a: Allocator, e: Comp) !void {
        return self.addEntry(a, .comp, e.cell_name, e);
    }

    pub fn addTestbench(self: *Pdk, a: Allocator, e: Tb) !void {
        return self.addEntry(a, .tb, e.cell_name, e);
    }

    // ── O(log N) lookup ────────────────────────────────────────────── //

    /// Binary search → tier + index. Null if unregistered.
    pub fn find(self: *const Pdk, cell_name: []const u8) ?CellRef {
        const pos = self.lowerBound(cell_name);
        if (pos < self.name_idx.items.len and
            std.mem.eql(u8, self.name_idx.items[pos].name, cell_name))
            return self.name_idx.items[pos].ref;
        return null;
    }

    pub fn classify(self: *const Pdk, cell_name: []const u8) CellTier {
        return if (self.find(cell_name)) |ref| ref.tier else .unregistered;
    }

    // ── ResolvedDevice reconstruction from SoA ─────────────────────── //

    pub fn resolvedAt(self: *const Pdk, idx: u30) ResolvedDevice {
        const s = self.prims.slice();
        return .{
            .kind = s.items(.kind)[idx],
            .prefix = s.items(.prefix)[idx],
            .pin_order = s.items(.pin_order)[idx],
            .model_name = s.items(.model_name)[idx],
            .default_params = s.items(.default_params)[idx],
        };
    }

    /// Full resolve chain: PDK primitive → builtin fallback → null.
    /// Components return null — caller uses find() + getComponent().
    pub fn resolve(self: *const Pdk, cell_name: []const u8, fallback_kind: DeviceKind) ?ResolvedDevice {
        if (self.find(cell_name)) |ref| {
            if (ref.tier == .prim) return self.resolvedAt(ref.idx);
            return null; // comp/tb — caller handles
        }
        return resolveBuiltin(fallback_kind);
    }

    // ── SoA slice access (for GUI / iteration) ─────────────────────── //

    pub fn primitives(self: *const Pdk) MAL(Prim).Slice {
        return self.prims.slice();
    }

    pub fn components(self: *const Pdk) MAL(Comp).Slice {
        return self.comps.slice();
    }

    pub fn testbenches(self: *const Pdk) MAL(Tb).Slice {
        return self.tbs.slice();
    }

    pub fn primCount(self: *const Pdk) usize {
        return self.prims.len;
    }

    pub fn compCount(self: *const Pdk) usize {
        return self.comps.len;
    }

    pub fn tbCount(self: *const Pdk) usize {
        return self.tbs.len;
    }

    pub fn totalCells(self: *const Pdk) usize {
        return self.prims.len + self.comps.len + self.tbs.len;
    }

    pub fn isEmpty(self: *const Pdk) bool {
        return self.totalCells() == 0;
    }

    /// Iterator yielding prim indices filtered by kind. SoA-idiomatic.
    pub fn iterPrimsByKind(self: *const Pdk, kind: DeviceKind) PrimKindIter {
        return .{ .kinds = self.prims.slice().items(.kind), .target = kind };
    }

    pub fn getComponent(self: *const Pdk, idx: u30) Comp {
        const s = self.comps.slice();
        return .{
            .cell_name = s.items(.cell_name)[idx],
            .file = s.items(.file)[idx],
            .library = s.items(.library)[idx],
            .pin_order = s.items(.pin_order)[idx],
        };
    }

    // ── Lazy .lib collection ───────────────────────────────────────── //

    pub fn collectLibIncludes(
        self: *const Pdk,
        a: Allocator,
        cell_names: []const []const u8,
    ) ![]const LibInclude {
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

    // ── Preamble emission ──────────────────────────────────────────── //

    pub fn emitPreamble(
        self: *const Pdk,
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

/// Global PDK singleton. Populated by the loader at startup;
/// consulted by the netlister and GUI at runtime.
pub var global_pdk: Pdk = .{};

// ── Tests ──────────────────────────────────────────────────────────────────── //

test "DeviceKind round-trip via StaticStringMap" {
    try std.testing.expectEqual(DeviceKind.mosfet, DeviceKind.fromStr("mosfet"));
    try std.testing.expectEqual(DeviceKind.unknown, DeviceKind.fromStr("bogus"));
    try std.testing.expectEqualStrings("resistor", @tagName(DeviceKind.resistor));
}

test "comptime prefix LUT" {
    try std.testing.expectEqual(@as(u8, 'R'), DeviceKind.resistor.prefix());
    try std.testing.expectEqual(@as(u8, 'C'), DeviceKind.capacitor.prefix());
    try std.testing.expectEqual(@as(u8, 'L'), DeviceKind.inductor.prefix());
    try std.testing.expectEqual(@as(u8, 'V'), DeviceKind.vsource.prefix());
    try std.testing.expectEqual(@as(u8, 'I'), DeviceKind.isource.prefix());
    try std.testing.expectEqual(@as(u8, 'V'), DeviceKind.ammeter.prefix());
    try std.testing.expectEqual(@as(u8, 'B'), DeviceKind.behavioral.prefix());
    try std.testing.expectEqual(@as(u8, 'E'), DeviceKind.vcvs.prefix());
    try std.testing.expectEqual(@as(u8, 'G'), DeviceKind.vccs.prefix());
    try std.testing.expectEqual(@as(u8, 'F'), DeviceKind.cccs.prefix());
    try std.testing.expectEqual(@as(u8, 'H'), DeviceKind.ccvs.prefix());
    try std.testing.expectEqual(@as(u8, 'K'), DeviceKind.coupling.prefix());
    try std.testing.expectEqual(@as(u8, 'T'), DeviceKind.tline.prefix());
    try std.testing.expectEqual(@as(u8, 'D'), DeviceKind.diode.prefix());
    try std.testing.expectEqual(@as(u8, 'M'), DeviceKind.mosfet.prefix());
    try std.testing.expectEqual(@as(u8, 'Q'), DeviceKind.bjt.prefix());
    try std.testing.expectEqual(@as(u8, 'J'), DeviceKind.jfet.prefix());
    try std.testing.expectEqual(@as(u8, 'Z'), DeviceKind.mesfet.prefix());
    try std.testing.expectEqual(@as(u8, 'S'), DeviceKind.vswitch.prefix());
    try std.testing.expectEqual(@as(u8, 'W'), DeviceKind.iswitch.prefix());
    try std.testing.expectEqual(@as(u8, 'O'), DeviceKind.tline_lossy.prefix());
    try std.testing.expectEqual(@as(u8, 'X'), DeviceKind.subckt.prefix());
    try std.testing.expectEqual(@as(u8, 0), DeviceKind.gnd.prefix());
}

test "comptime pins LUT" {
    const r_pins = DeviceKind.resistor.pins();
    try std.testing.expectEqual(@as(usize, 2), r_pins.len);
    try std.testing.expectEqualStrings("p", r_pins[0]);
    try std.testing.expectEqualStrings("n", r_pins[1]);

    const m_pins = DeviceKind.mosfet.pins();
    try std.testing.expectEqual(@as(usize, 4), m_pins.len);
    try std.testing.expectEqualStrings("d", m_pins[0]);
    try std.testing.expectEqualStrings("b", m_pins[3]);

    const q_pins = DeviceKind.bjt.pins();
    try std.testing.expectEqual(@as(usize, 3), q_pins.len);

    try std.testing.expectEqual(@as(usize, 0), DeviceKind.gnd.pins().len);
    try std.testing.expectEqual(@as(usize, 0), DeviceKind.subckt.pins().len);
}

test "comptime model keyword LUT" {
    try std.testing.expectEqualStrings("NMOS", DeviceKind.mosfet.modelKeyword().?);
    try std.testing.expectEqualStrings("D", DeviceKind.diode.modelKeyword().?);
    try std.testing.expectEqualStrings("NPN", DeviceKind.bjt.modelKeyword().?);
    try std.testing.expectEqualStrings("NJF", DeviceKind.jfet.modelKeyword().?);
    try std.testing.expectEqualStrings("NMF", DeviceKind.mesfet.modelKeyword().?);
    try std.testing.expectEqualStrings("SW", DeviceKind.vswitch.modelKeyword().?);
    try std.testing.expectEqualStrings("CSW", DeviceKind.iswitch.modelKeyword().?);
    try std.testing.expectEqualStrings("LTRA", DeviceKind.tline_lossy.modelKeyword().?);

    // Value-only kinds have no model keyword
    try std.testing.expectEqual(@as(?[]const u8, null), DeviceKind.resistor.modelKeyword());
    try std.testing.expectEqual(@as(?[]const u8, null), DeviceKind.capacitor.modelKeyword());
    try std.testing.expectEqual(@as(?[]const u8, null), DeviceKind.vsource.modelKeyword());
    try std.testing.expectEqual(@as(?[]const u8, null), DeviceKind.behavioral.modelKeyword());
}

test "needsModel and isSubcircuit" {
    // Model devices
    try std.testing.expect(DeviceKind.diode.needsModel());
    try std.testing.expect(DeviceKind.mosfet.needsModel());
    try std.testing.expect(DeviceKind.bjt.needsModel());
    try std.testing.expect(DeviceKind.jfet.needsModel());
    try std.testing.expect(DeviceKind.mesfet.needsModel());
    try std.testing.expect(DeviceKind.vswitch.needsModel());
    try std.testing.expect(DeviceKind.iswitch.needsModel());
    try std.testing.expect(DeviceKind.tline_lossy.needsModel());

    // Value-only devices
    try std.testing.expect(!DeviceKind.resistor.needsModel());
    try std.testing.expect(!DeviceKind.capacitor.needsModel());
    try std.testing.expect(!DeviceKind.vsource.needsModel());
    try std.testing.expect(!DeviceKind.behavioral.needsModel());
    try std.testing.expect(!DeviceKind.vcvs.needsModel());
    try std.testing.expect(!DeviceKind.tline.needsModel());
    try std.testing.expect(!DeviceKind.coupling.needsModel());

    // Subcircuit
    try std.testing.expect(DeviceKind.subckt.isSubcircuit());
    try std.testing.expect(!DeviceKind.mosfet.isSubcircuit());
    try std.testing.expect(!DeviceKind.resistor.isSubcircuit());
}

test "resolveBuiltin" {
    const r = resolveBuiltin(.resistor).?;
    try std.testing.expectEqual(@as(u8, 'R'), r.prefix);
    try std.testing.expectEqual(@as(?[]const u8, null), r.model_name);
    try std.testing.expectEqual(@as(usize, 2), r.pin_order.len);

    const m = resolveBuiltin(.mosfet).?;
    try std.testing.expectEqual(@as(u8, 'M'), m.prefix);
    try std.testing.expectEqual(@as(usize, 4), m.pin_order.len);

    // Non-electrical returns null
    try std.testing.expectEqual(@as(?ResolvedDevice, null), resolveBuiltin(.gnd));
    try std.testing.expectEqual(@as(?ResolvedDevice, null), resolveBuiltin(.unknown));
}

test "non-electrical and injected net" {
    try std.testing.expect(DeviceKind.gnd.isNonElectrical());
    try std.testing.expect(!DeviceKind.resistor.isNonElectrical());
    try std.testing.expectEqualStrings("0", DeviceKind.gnd.injectedNetName().?);
    try std.testing.expectEqual(@as(?[]const u8, null), DeviceKind.resistor.injectedNetName());
}

test "register primitive + 1-to-1 enforcement" {
    const a = std.testing.allocator;
    var pdk = Pdk{};
    defer pdk.deinit(a);

    try pdk.addPrimitive(a, .{
        .cell_name = "nfet_01v8",
        .file = "/sym/nfet_01v8.chn_sym",
        .library = "sky130_fd_pr",
        .kind = .mosfet,
        .prefix = 'M',
        .pin_order = &.{ "d", "g", "s", "b" },
        .model_name = "nfet_01v8",
        .default_params = &.{ .{ .key = "w", .val = "0.42" }, .{ .key = "l", .val = "0.15" } },
        .lib_includes = &.{.{ .path = "/pdk/sky130.lib.spice", .has_sections = true }},
    });

    const ref = pdk.find("nfet_01v8").?;
    try std.testing.expectEqual(CellTier.prim, ref.tier);
    const dev = pdk.resolvedAt(ref.idx);
    try std.testing.expectEqual(@as(u8, 'M'), dev.prefix);
    try std.testing.expectEqual(DeviceKind.mosfet, dev.kind);

    const dev2 = pdk.resolve("nfet_01v8", .unknown).?;
    try std.testing.expectEqual(@as(u8, 'M'), dev2.prefix);

    const dup = pdk.addPrimitive(a, .{
        .cell_name = "nfet_01v8",
        .file = "/dup",
        .library = "x",
        .kind = .mosfet,
        .prefix = 'M',
        .pin_order = &.{ "d", "g", "s", "b" },
        .model_name = "nfet_01v8",
        .default_params = &.{},
        .lib_includes = &.{},
    });
    try std.testing.expectEqual(@as(anyerror, error.DuplicateCellName), dup);
}

test "register component + classify" {
    const a = std.testing.allocator;
    var pdk = Pdk{};
    defer pdk.deinit(a);

    try pdk.addComponent(a, .{
        .cell_name = "inv_1",
        .file = "/cells/inv_1.sch",
        .library = "sky130_fd_sc_hd",
        .pin_order = &.{ "A", "Y", "VPWR", "VGND" },
    });

    try std.testing.expectEqual(CellTier.comp, pdk.classify("inv_1"));
    try std.testing.expectEqual(CellTier.unregistered, pdk.classify("bogus"));
    try std.testing.expectEqual(@as(?ResolvedDevice, null), pdk.resolve("inv_1", .unknown));

    const dup = pdk.addPrimitive(a, .{
        .cell_name = "inv_1",
        .file = "/x",
        .library = "x",
        .kind = .subckt,
        .prefix = 'X',
        .pin_order = &.{},
        .model_name = null,
        .default_params = &.{},
        .lib_includes = &.{},
    });
    try std.testing.expectEqual(@as(anyerror, error.DuplicateCellName), dup);
}

test "resolve falls through to builtin" {
    const a = std.testing.allocator;
    var pdk = Pdk{};
    defer pdk.deinit(a);

    // Resistor falls through to builtin
    const r = pdk.resolve("some_res", .resistor).?;
    try std.testing.expectEqual(@as(u8, 'R'), r.prefix);

    // MOSFET also falls through now (builtin has prefix 'M', no model name)
    const m = pdk.resolve("some_mos", .mosfet).?;
    try std.testing.expectEqual(@as(u8, 'M'), m.prefix);
    try std.testing.expectEqual(@as(?[]const u8, null), m.model_name);

    // Unknown returns null
    try std.testing.expectEqual(@as(?ResolvedDevice, null), pdk.resolve("bogus", .unknown));
}

test "collect lib includes deduplicates" {
    const a = std.testing.allocator;
    var pdk = Pdk{};
    defer pdk.deinit(a);

    const shared = LibInclude{ .path = "/pdk/sky130.lib.spice", .has_sections = true };
    const extra = LibInclude{ .path = "/pdk/extra.spice", .has_sections = false };
    const mos = &[_][]const u8{ "d", "g", "s", "b" };

    try pdk.addPrimitive(a, .{ .cell_name = "nfet", .file = "/a", .library = "pr", .kind = .mosfet, .prefix = 'M', .pin_order = mos, .model_name = "nfet", .default_params = &.{}, .lib_includes = &.{ shared, extra } });
    try pdk.addPrimitive(a, .{ .cell_name = "pfet", .file = "/b", .library = "pr", .kind = .mosfet, .prefix = 'M', .pin_order = mos, .model_name = "pfet", .default_params = &.{}, .lib_includes = &.{shared} });

    const names = &[_][]const u8{ "nfet", "pfet" };
    const libs = try pdk.collectLibIncludes(a, names);
    defer a.free(libs);
    // shared deduped → 2 unique (shared + extra), not 3
    try std.testing.expectEqual(@as(usize, 2), libs.len);
}

test "emitPreamble ngspice" {
    const a = std.testing.allocator;
    var pdk = Pdk{};
    defer pdk.deinit(a);

    const mos = &[_][]const u8{ "d", "g", "s", "b" };
    try pdk.addPrimitive(a, .{ .cell_name = "nfet", .file = "/a", .library = "pr", .kind = .mosfet, .prefix = 'M', .pin_order = mos, .model_name = "nfet", .default_params = &.{}, .lib_includes = &.{
        .{ .path = "/pdk/sky130.lib.spice", .has_sections = true },
        .{ .path = "/pdk/corners.spice", .has_sections = false },
    } });

    const names = &[_][]const u8{"nfet"};
    const preamble = try pdk.emitPreamble(a, names, null);
    defer a.free(preamble);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".lib \"/pdk/sky130.lib.spice\" tt") != null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".include \"/pdk/corners.spice\"") != null);
}

test "emitPreamble xyce with corner override" {
    const a = std.testing.allocator;
    var pdk = Pdk{ .dialect = .xyce };
    defer pdk.deinit(a);

    const mos = &[_][]const u8{ "d", "g", "s", "b" };
    try pdk.addPrimitive(a, .{ .cell_name = "nfet", .file = "/a", .library = "pr", .kind = .mosfet, .prefix = 'M', .pin_order = mos, .model_name = "nfet", .default_params = &.{}, .lib_includes = &.{
        .{ .path = "/pdk/models.lib.spice", .has_sections = true },
    } });

    const names = &[_][]const u8{"nfet"};
    const preamble = try pdk.emitPreamble(a, names, "ff");
    defer a.free(preamble);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".LIB \"/pdk/models.lib.spice\" ff") != null);
}

test "kind iterator yields indices" {
    const a = std.testing.allocator;
    var pdk = Pdk{};
    defer pdk.deinit(a);

    const mos = &[_][]const u8{ "d", "g", "s", "b" };
    const dio = &[_][]const u8{ "p", "n" };
    try pdk.addPrimitive(a, .{ .cell_name = "nfet_01v8", .file = "/a", .library = "pr", .kind = .mosfet, .prefix = 'M', .pin_order = mos, .model_name = "nfet_01v8", .default_params = &.{}, .lib_includes = &.{} });
    try pdk.addPrimitive(a, .{ .cell_name = "pfet_01v8", .file = "/b", .library = "pr", .kind = .mosfet, .prefix = 'M', .pin_order = mos, .model_name = "pfet_01v8", .default_params = &.{}, .lib_includes = &.{} });
    try pdk.addPrimitive(a, .{ .cell_name = "diode_pw", .file = "/c", .library = "pr", .kind = .diode, .prefix = 'D', .pin_order = dio, .model_name = "diode_pw", .default_params = &.{}, .lib_includes = &.{} });

    var it = pdk.iterPrimsByKind(.mosfet);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 2), n);

    var dit = pdk.iterPrimsByKind(.diode);
    n = 0;
    while (dit.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "empty pdk" {
    const pdk = Pdk{};
    try std.testing.expect(pdk.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), pdk.totalCells());
    try std.testing.expectEqual(CellTier.unregistered, pdk.classify("anything"));
}

test "CellRef packs into u32" {
    const ref = CellRef{ .idx = 42, .tier = .comp };
    const as_u32: u32 = @bitCast(ref);
    const back: CellRef = @bitCast(as_u32);
    try std.testing.expectEqual(@as(u30, 42), back.idx);
    try std.testing.expectEqual(CellTier.comp, back.tier);
}

test "struct sizes" {
    const print = std.debug.print;
    print("CellRef: {d}B\n", .{@sizeOf(CellRef)});
    print("Pdk: {d}B\n", .{@sizeOf(Pdk)});
    print("DeviceKind: {d}B\n", .{@sizeOf(DeviceKind)});
    print("ResolvedDevice: {d}B\n", .{@sizeOf(ResolvedDevice)});
}
