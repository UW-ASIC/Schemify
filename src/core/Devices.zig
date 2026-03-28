const std = @import("std");

const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;

// Import the public SPICE types from SpiceIF so this file doesn't duplicate them.
const spice = @import("SpiceIF.zig");
pub const Backend = spice.Backend;
pub const Value = spice.Value;
pub const SpiceComponent = spice.SpiceComponent;
pub const emitComponent = spice.emitComponent;

/// Comptime-parsed standard .chn_prim primitives.
pub const primitives = @import("devices/primitives.zig");

const ParamDefault = struct { key: []const u8, val: []const u8 };

/// Global PDK singleton.  Populated by the loader at startup, consulted by the
/// netlister and GUI at runtime.
pub var global_pdk: Pdk = .{};

// ========================================================
// Device Cell Library
// ========================================================

pub const Device = struct {
    kind: DeviceKind,
    prefix: u8,
    pin_order: []const []const u8,
    model_name: ?[]const u8,
    default_params: []const ParamDefault,

    /// Build a Device purely from comptime DeviceKind data (no PDK).
    /// Returns null for non-electrical kinds (prefix == 0).
    pub fn fromBuiltin(kind: DeviceKind) ?Device {
        const p = kind.prefix();
        if (p == 0) return null;
        return .{
            .kind = kind,
            .prefix = p,
            .pin_order = kind.pins(),
            .model_name = null,
            .default_params = &.{},
        };
    }

    /// Convenience wrapper: resolve via PDK, falling back to builtin.
    pub fn fromPdk(pdk: *const Pdk, cell_name: []const u8, fallback_kind: DeviceKind) ?Device {
        return pdk.resolve(cell_name, fallback_kind);
    }

    // ── SPICE emission ────────────────────────────────────────────────────── //

    /// Emit a single SPICE instance line for this device.
    ///
    /// `inst_name`  — the instance designator (e.g. "R1", "M3").  Typically the
    ///                 Schemify instance's `name` field with the prefix prepended.
    /// `nets`       — node names in pin_order sequence (caller resolves via
    ///                Schemify.nets / NetConn).
    /// `params`     — per-instance param overrides (W=, L=, value=, …).
    /// `backend`    — target simulator dialect.
    ///
    /// The function builds a `SpiceComponent` from the device kind and delegates
    /// to `emitComponent`, so all dialect-specific formatting lives in SpiceIF.
    pub fn emitSpice(
        self: *const Device,
        writer: anytype,
        inst_name: []const u8,
        nets: []const []const u8,
        params: []const spice.ParamOverride,
        backend: Backend,
    ) !void {
        const comp = try self.toSpiceComponent(inst_name, nets, params);
        try emitComponent(writer, comp, backend);
    }

    /// Convert device metadata + runtime connectivity into a `SpiceComponent`.
    /// Errors if the net count doesn't match pin_order.  Exposed so callers
    /// can inspect or store the component before writing it.
    pub fn toSpiceComponent(
        self: *const Device,
        inst_name: []const u8,
        nets: []const []const u8,
        params: []const spice.ParamOverride,
    ) !SpiceComponent {
        if (nets.len < self.pin_order.len) return error.NotEnoughNets;

        switch (self.kind) {
            // ── Passives ──────────────────────────────────────────────────── //
            .resistor, .resistor3, .var_resistor => {
                const val = findParam(params, "value") orelse Value{ .literal = 0 };
                const m = findParamStr(params, "m");
                return .{ .resistor = .{ .name = inst_name, .p = nets[0], .n = nets[1], .value = val, .m = m } };
            },
            .capacitor => {
                const val = findParam(params, "value") orelse Value{ .literal = 0 };
                const ic = findParamF64(params, "ic");
                return .{ .capacitor = .{ .name = inst_name, .p = nets[0], .n = nets[1], .value = val, .ic = ic } };
            },
            .inductor => {
                const val = findParam(params, "value") orelse Value{ .literal = 0 };
                const ic = findParamF64(params, "ic");
                return .{ .inductor = .{ .name = inst_name, .p = nets[0], .n = nets[1], .value = val, .ic = ic } };
            },

            // ── Diodes ────────────────────────────────────────────────────── //
            .diode, .zener => {
                const model = self.model_name orelse findParamStr(params, "model") orelse "D";
                return .{ .diode = .{ .name = inst_name, .anode = nets[0], .cathode = nets[1], .model = model } };
            },

            // ── MOSFETs ───────────────────────────────────────────────────── //
            .nmos3, .pmos3, .nmos_sub, .pmos_sub => {
                // 3-terminal: D G S; bulk = source (tied internally or by model)
                const model = self.model_name orelse findParamStr(params, "model") orelse "NMOS";
                return .{
                    .mosfet = .{
                        .name = inst_name,
                        .drain = nets[0],
                        .gate = nets[1],
                        .source = nets[2],
                        .bulk = nets[2], // bulk tied to source
                        .model = model,
                        .w = findParam(params, "W"),
                        .l = findParam(params, "L"),
                        .m = findParamF64(params, "M"),
                    },
                };
            },
            .nmos4, .pmos4, .nmos4_depl, .nmoshv4, .pmoshv4, .rnmos4 => {
                const model = self.model_name orelse findParamStr(params, "model") orelse "NMOS";
                return .{ .mosfet = .{
                    .name = inst_name,
                    .drain = nets[0],
                    .gate = nets[1],
                    .source = nets[2],
                    .bulk = nets[3],
                    .model = model,
                    .w = findParam(params, "W"),
                    .l = findParam(params, "L"),
                    .m = findParamF64(params, "M"),
                } };
            },

            // ── BJTs ──────────────────────────────────────────────────────── //
            .npn, .pnp => {
                const model = self.model_name orelse findParamStr(params, "model") orelse "NPN";
                const sub = if (nets.len >= 4) nets[3] else null;
                return .{ .bjt = .{
                    .name = inst_name,
                    .collector = nets[0],
                    .base = nets[1],
                    .emitter = nets[2],
                    .substrate = sub,
                    .model = model,
                } };
            },

            // ── JFETs ─────────────────────────────────────────────────────── //
            .njfet, .pjfet => {
                const model = self.model_name orelse findParamStr(params, "model") orelse "NJF";
                return .{ .jfet = .{
                    .name = inst_name,
                    .drain = nets[0],
                    .gate = nets[1],
                    .source = nets[2],
                    .model = model,
                } };
            },

            // ── Sources ───────────────────────────────────────────────────── //
            .vsource, .ammeter, .sqwsource => {
                // Independent voltage source; waveform encoded in params as raw SPICE string
                const dc = findParamF64(params, "dc");
                const raw = findParamStr(params, "spice_waveform");
                if (raw) |wf| {
                    // Caller has already formatted the waveform; emit raw line.
                    const line = std.fmt.allocPrint(
                        std.heap.page_allocator, // NOTE: caller should pass allocator; this is a best-effort path
                        "{s} {s} {s} {s}\n",
                        .{ inst_name, nets[0], nets[1], wf },
                    ) catch inst_name;
                    return .{ .raw = line };
                }
                return .{ .independent_source = .{
                    .name = inst_name,
                    .kind = .voltage,
                    .p = nets[0],
                    .n = nets[1],
                    .dc = dc,
                } };
            },
            .isource => {
                const dc = findParamF64(params, "dc");
                return .{ .independent_source = .{
                    .name = inst_name,
                    .kind = .current,
                    .p = nets[0],
                    .n = nets[1],
                    .dc = dc,
                } };
            },
            .behavioral => {
                // TABLE-based behavioral voltage source (E-prefix):
                // E<name> <out+> <out-> TABLE {V(<ctrl+>,<ctrl->)} = (pairs...)
                const table = findParamStr(params, "TABLE");
                if (table) |tbl| {
                    var buf2: [1024]u8 = undefined;
                    const out_p = if (nets.len > 0) nets[0] else "0";
                    const out_n = if (nets.len > 1) nets[1] else "0";
                    const ctrl_p = if (nets.len > 2) nets[2] else out_p;
                    // If cn is the unresolved default "0", use out_n as reference.
                    const raw_cn = if (nets.len > 3) nets[3] else "0";
                    const ctrl_n = if (std.mem.eql(u8, raw_cn, "0")) out_n else raw_cn;
                    const line = std.fmt.bufPrint(&buf2, "{s} {s} {s} TABLE {{V({s},{s})}} = ({s})\n", .{
                        inst_name, out_p, out_n, ctrl_p, ctrl_n, tbl,
                    }) catch inst_name;
                    return .{ .raw = line };
                }
                // Standard B-source: B<name> <p> <n> V={expr}
                const expr = findParamStr(params, "expr") orelse findParamStr(params, "value") orelse "0";
                const kind_str = findParamStr(params, "bkind") orelse "V";
                const bkind: @TypeOf(@as(SpiceComponent, undefined).behavioral.kind) =
                    if (kind_str[0] == 'I') .current else .voltage;
                return .{ .behavioral = .{
                    .name = inst_name,
                    .kind = bkind,
                    .p = if (nets.len > 0) nets[0] else "0",
                    .n = if (nets.len > 1) nets[1] else "0",
                    .expr = expr,
                } };
            },

            // ── Controlled sources ────────────────────────────────────────── //
            .vcvs => {
                const gain = findParam(params, "gain") orelse findParam(params, "value") orelse Value{ .literal = 1.0 };
                return .{ .vcvs = .{ .name = inst_name, .p = nets[0], .n = nets[1], .cp = nets[2], .cn = nets[3], .gain = gain } };
            },
            .vccs => {
                const gain = findParam(params, "gain") orelse findParam(params, "value") orelse Value{ .literal = 1.0 };
                return .{ .vccs = .{ .name = inst_name, .p = nets[0], .n = nets[1], .cp = nets[2], .cn = nets[3], .gain = gain } };
            },
            .ccvs => {
                const gain = findParam(params, "gain") orelse findParam(params, "value") orelse Value{ .literal = 1.0 };
                const vsrc = findParamStr(params, "vsrc") orelse "V0";
                return .{ .ccvs = .{ .name = inst_name, .p = nets[0], .n = nets[1], .vsrc = vsrc, .gain = gain } };
            },
            .cccs => {
                const gain = findParam(params, "gain") orelse findParam(params, "value") orelse Value{ .literal = 1.0 };
                const vsrc = findParamStr(params, "vsrc") orelse "V0";
                return .{ .cccs = .{ .name = inst_name, .p = nets[0], .n = nets[1], .vsrc = vsrc, .gain = gain } };
            },

            // ── Subcircuits ───────────────────────────────────────────────── //
            .subckt, .digital_instance, .mesfet => {
                const cell = self.model_name orelse inst_name;
                return .{ .subcircuit = .{
                    .name = cell,
                    .inst_name = inst_name,
                    .nodes = nets,
                    .params = params,
                } };
            },

            // ── Switches ─────────────────────────────────────────────────────── //
            .vswitch => {
                const model = self.model_name orelse findParamStr(params, "model") orelse "SW";
                // S<name> p n cp cn <model>
                var buf2: [512]u8 = undefined;
                const table = findParamStr(params, "TABLE");
                const line = if (table) |t|
                    std.fmt.bufPrint(&buf2, "{s} {s} {s} {s} {s} {s} {s}\n", .{ inst_name, nets[0], nets[1], nets[2], nets[3], model, t }) catch inst_name
                else
                    std.fmt.bufPrint(&buf2, "{s} {s} {s} {s} {s} {s}\n", .{ inst_name, nets[0], nets[1], nets[2], nets[3], model }) catch inst_name;
                return .{ .raw = line };
            },
            .iswitch => {
                const model = self.model_name orelse findParamStr(params, "model") orelse "CSW";
                const vsrc = findParamStr(params, "vsrc") orelse "V0";
                var buf2: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&buf2, "{s} {s} {s} {s} {s}\n", .{ inst_name, nets[0], nets[1], vsrc, model }) catch inst_name;
                return .{ .raw = line };
            },

            // ── Transmission lines ──────────────────────────────────────────── //
            .tline, .tline_lossy => {
                const model = self.model_name orelse findParamStr(params, "model");
                var buf2: [512]u8 = undefined;
                const line = if (model) |m|
                    std.fmt.bufPrint(&buf2, "{s} {s} {s} {s} {s} {s}\n", .{ inst_name, nets[0], nets[1], nets[2], nets[3], m }) catch inst_name
                else
                    std.fmt.bufPrint(&buf2, "{s} {s} {s} {s} {s}\n", .{ inst_name, nets[0], nets[1], nets[2], nets[3] }) catch inst_name;
                return .{ .raw = line };
            },

            // ── Coupling (K-element) ────────────────────────────────────────── //
            .coupling => {
                // K<name> L1 L2 <coupling_coeff>
                // Coupling elements reference inductors by name (params), not nets.
                const l1 = findParamStr(params, "L1") orelse "L1";
                const l2 = findParamStr(params, "L2") orelse "L2";
                const k_val = findParamStr(params, "K") orelse findParamStr(params, "value") orelse "1";
                var buf2: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&buf2, "{s} {s} {s} {s}\n", .{ inst_name, l1, l2, k_val }) catch inst_name;
                return .{ .raw = line };
            },

            // ── Non-electrical / UI — should never reach emitSpice ─────────── //
            .gnd,
            .vdd,
            .lab_pin,
            .input_pin,
            .output_pin,
            .inout_pin,
            .annotation,
            .noconn,
            .title,
            .launcher,
            .rgb_led,
            .generic,
            .param,
            .probe,
            .probe_diff,
            .code,
            .graph,
            .hdl,
            .unknown,
            => return error.NonElectricalDevice,
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────── //

    fn findParam(params: []const spice.ParamOverride, key: []const u8) ?Value {
        for (params) |p| {
            if (std.mem.eql(u8, p.name, key)) return p.value;
        }
        return null;
    }

    fn findParamStr(params: []const spice.ParamOverride, key: []const u8) ?[]const u8 {
        for (params) |p| {
            if (std.mem.eql(u8, p.name, key)) {
                return switch (p.value) {
                    .param => |s| s,
                    .expr => |s| s,
                    .literal => null,
                };
            }
        }
        return null;
    }

    fn findParamF64(params: []const spice.ParamOverride, key: []const u8) ?f64 {
        for (params) |p| {
            if (std.mem.eql(u8, p.name, key)) {
                return switch (p.value) {
                    .literal => |v| v,
                    else => null,
                };
            }
        }
        return null;
    }
};

// ========================================================
// PDK Cell Library
// ========================================================
pub const Pdk = struct {
    name: []const u8 = "",
    default_corner: []const u8 = "tt",
    dialect: Backend = .ngspice, // was SpiceDialect, now Backend

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

    // ── Registration ───────────────────────────────────────────────── //

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

    // ── Lookup ─────────────────────────────────────────────────────── //

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

    pub fn resolvedAt(self: *const Pdk, idx: u30) Device {
        const s = self.prims.slice();
        return .{
            .kind = s.items(.kind)[idx],
            .prefix = s.items(.prefix)[idx],
            .pin_order = s.items(.pin_order)[idx],
            .model_name = s.items(.model_name)[idx],
            .default_params = s.items(.default_params)[idx],
        };
    }

    pub fn resolve(self: *const Pdk, cell_name: []const u8, fallback_kind: DeviceKind) ?Device {
        if (self.find(cell_name)) |ref| {
            if (ref.tier == .prim) return self.resolvedAt(ref.idx);
            return null;
        }
        return Device.fromBuiltin(fallback_kind);
    }

    // ── SoA slice access ───────────────────────────────────────────── //

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
                    // .hspice => try w.print(".lib \"{s}\" {s}\n", .{ inc.path, corner }),
                }
            } else switch (self.dialect) {
                .ngspice => try w.print(".include \"{s}\"\n", .{inc.path}),
                .xyce => try w.print(".INCLUDE \"{s}\"\n", .{inc.path}),
                // .hspice => try w.print(".include \"{s}\"\n", .{inc.path}),
            }
        }
        return buf.toOwnedSlice(a);
    }
};

// ========================================================
// PDK Private Types
// ========================================================

const NameEntry = struct { name: []const u8, ref: CellRef };

pub const LibInclude = struct {
    path: []const u8,
    /// true → `.lib "path" <corner>`, false → `.include "path"`
    has_sections: bool,
};

const Prim = struct {
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

const Comp = struct {
    cell_name: []const u8,
    file: []const u8,
    library: []const u8,
    pin_order: []const []const u8,
};

const Tb = struct {
    cell_name: []const u8,
    file: []const u8,
    library: []const u8,
};

const CellTier = enum(u2) { prim = 0, comp = 1, tb = 2, unregistered = 3 };

const CellRef = packed struct(u32) {
    idx: u30,
    tier: CellTier,
};

const PrimKindIter = struct {
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

// ========================================================
// Device Private Types
// ========================================================

const DeviceEntry = struct {
    kind: DeviceKind,
    prefix: u8 = 0,
    pins: []const []const u8 = &.{},
    model_keyword: ?[]const u8 = null,
    injected_net: ?[]const u8 = null,
    non_electrical: bool = false,
};

// ── Build device_table at comptime from .chn_prim files + legacy extras ──
//
// The parsed_prims array contains entries sourced from .chn_prim files.
// We convert each to a DeviceEntry, then append legacy entries that have
// no .chn_prim file (variant MOSFET kinds, mesfet, sqwsource, etc.).

fn primToDeviceEntry(comptime p: PrimEntryRef) DeviceEntry {
    const kind = DeviceKind.fromStr(p.kind_name);
    return .{
        .kind = kind,
        .prefix = p.prefix,
        .pins = p.pin_storage[0..p.pin_count],
        .model_keyword = p.model_keyword,
        .injected_net = p.injected_net,
        .non_electrical = p.non_electrical,
    };
}

const PrimEntryRef = primitives.PrimEntry;

/// Legacy entries: device kinds that exist in the enum but have no .chn_prim file.
/// These are SPICE-specific variant kinds or purely internal UI kinds.
const legacy_entries = [_]DeviceEntry{
    // MOSFET variants that alias to the standard nmos/pmos .chn_prim definitions
    .{ .kind = .var_resistor, .prefix = 'R', .pins = &.{ "p", "n" } },
    .{ .kind = .nmos4_depl, .prefix = 'M', .pins = &.{ "d", "g", "s", "b" }, .model_keyword = "NMOS" },
    .{ .kind = .nmos_sub, .prefix = 'M', .pins = &.{ "d", "g", "s" }, .model_keyword = "NMOS" },
    .{ .kind = .pmos_sub, .prefix = 'M', .pins = &.{ "d", "g", "s" }, .model_keyword = "PMOS" },
    .{ .kind = .nmoshv4, .prefix = 'M', .pins = &.{ "d", "g", "s", "b" }, .model_keyword = "NMOS" },
    .{ .kind = .pmoshv4, .prefix = 'M', .pins = &.{ "d", "g", "s", "b" }, .model_keyword = "PMOS" },
    .{ .kind = .rnmos4, .prefix = 'M', .pins = &.{ "d", "g", "s", "b" }, .model_keyword = "NMOS" },

    // MESFET — rare, no standard .chn_prim
    .{ .kind = .mesfet, .prefix = 'Z', .pins = &.{ "d", "g", "s" }, .model_keyword = "NMF" },

    // Square-wave source — alias of vsource
    .{ .kind = .sqwsource, .prefix = 'V', .pins = &.{ "p", "m" } },

    // Lossy transmission line — variant of tline
    .{ .kind = .tline_lossy, .prefix = 'O', .pins = &.{ "p1p", "p1n", "p2p", "p2n" }, .model_keyword = "LTRA" },

    // Non-electrical UI kinds without .chn_prim files
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

    // Subcircuit / digital wrappers
    .{ .kind = .digital_instance, .prefix = 'X' },
    .{ .kind = .subckt, .prefix = 'X' },
};

/// The unified device_table: first the .chn_prim-sourced entries, then legacy extras.
const device_table: []const DeviceEntry = blk: {
    @setEvalBranchQuota(10_000);
    const prim_count = primitives.prim_count;
    const total = prim_count + legacy_entries.len;
    var table: [total]DeviceEntry = undefined;
    // Convert each parsed .chn_prim into a DeviceEntry
    for (primitives.parsed_prims, 0..) |p, i| {
        table[i] = primToDeviceEntry(p);
    }
    // Append legacy entries
    for (legacy_entries, 0..) |le, i| {
        table[prim_count + i] = le;
    }
    const final = table;
    break :blk &final;
};

pub const DeviceKind = enum(u8) {
    unknown,

    resistor,
    resistor3,
    var_resistor,
    capacitor,
    inductor,

    diode,
    zener,

    nmos3,
    pmos3,
    nmos4,
    pmos4,
    nmos4_depl,
    nmos_sub,
    pmos_sub,
    nmoshv4,
    pmoshv4,
    rnmos4,

    npn,
    pnp,

    njfet,
    pjfet,

    mesfet,

    vsource,
    isource,
    sqwsource,
    ammeter,
    behavioral,

    vcvs,
    vccs,
    ccvs,
    cccs,

    coupling,
    tline,
    tline_lossy,

    vswitch,
    iswitch,

    param,
    probe,
    probe_diff,
    code,
    graph,

    hdl,

    gnd,
    vdd,
    lab_pin,
    input_pin,
    output_pin,
    inout_pin,
    annotation,
    noconn,
    title,
    launcher,
    rgb_led,
    generic,

    digital_instance,
    subckt,

    // ── Methods ────────────────────────────────────────────────────── //

    pub fn prefix(self: DeviceKind) u8 {
        return prefix_lut[@intFromEnum(self)];
    }
    pub fn pins(self: DeviceKind) []const []const u8 {
        return pins_lut[@intFromEnum(self)];
    }
    pub fn needsModel(self: DeviceKind) bool {
        return model_keyword_lut[@intFromEnum(self)] != null;
    }
    pub fn modelKeyword(self: DeviceKind) ?[]const u8 {
        return model_keyword_lut[@intFromEnum(self)];
    }
    pub fn isSubcircuit(self: DeviceKind) bool {
        return self == .subckt or self == .digital_instance;
    }
    pub fn isNonElectrical(self: DeviceKind) bool {
        return non_electrical_lut[@intFromEnum(self)];
    }
    pub fn isPort(self: DeviceKind) bool {
        return self == .input_pin or self == .output_pin or self == .inout_pin;
    }
    pub fn isCodeBlock(self: DeviceKind) bool {
        return self == .code or self == .param;
    }
    pub fn isHdlBlock(self: DeviceKind) bool {
        return self == .hdl;
    }
    pub fn isAnnotation(self: DeviceKind) bool {
        return self == .probe or self == .probe_diff or self == .graph or
            self == .annotation or self == .title or self == .launcher or
            self == .noconn or self == .rgb_led or self == .generic;
    }

    pub fn isMosfet(self: DeviceKind) bool {
        return switch (self) {
            .nmos3, .pmos3, .nmos4, .pmos4, .nmos4_depl, .nmos_sub, .pmos_sub, .nmoshv4, .pmoshv4, .rnmos4 => true,
            else => false,
        };
    }
    pub fn isNmos(self: DeviceKind) bool {
        return switch (self) {
            .nmos3, .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4, .rnmos4 => true,
            else => false,
        };
    }
    pub fn isPmos(self: DeviceKind) bool {
        return switch (self) {
            .pmos3, .pmos4, .pmos_sub, .pmoshv4 => true,
            else => false,
        };
    }

    pub fn injectedNetName(self: DeviceKind) ?[]const u8 {
        return injected_net_lut[@intFromEnum(self)];
    }

    pub fn fromStr(s: []const u8) DeviceKind {
        return kind_map.get(s) orelse .unknown;
    }

    // ── Comptime LUTs (populated from device_table, which is itself ── //
    // ── built from .chn_prim files + legacy extras)                  ── //

    const N = @typeInfo(DeviceKind).@"enum".fields.len;

    const kind_map = blk: {
        @setEvalBranchQuota(5_000);
        const fields = @typeInfo(DeviceKind).@"enum".fields;
        var kvs: [fields.len]struct { []const u8, DeviceKind } = undefined;
        for (fields, 0..) |f, i| kvs[i] = .{ f.name, @as(DeviceKind, @enumFromInt(f.value)) };
        break :blk std.StaticStringMap(DeviceKind).initComptime(kvs);
    };

    const prefix_lut: [N]u8 = blk: {
        var lut = [1]u8{0} ** N;
        for (device_table) |e| lut[@intFromEnum(e.kind)] = e.prefix;
        break :blk lut;
    };
    const pins_lut: [N][]const []const u8 = blk: {
        const empty: []const []const u8 = &.{};
        var lut = [1][]const []const u8{empty} ** N;
        for (device_table) |e| lut[@intFromEnum(e.kind)] = e.pins;
        break :blk lut;
    };
    const model_keyword_lut: [N]?[]const u8 = blk: {
        var lut = [1]?[]const u8{null} ** N;
        for (device_table) |e| lut[@intFromEnum(e.kind)] = e.model_keyword;
        break :blk lut;
    };
    const non_electrical_lut: [N]bool = blk: {
        var lut = [1]bool{false} ** N;
        for (device_table) |e| lut[@intFromEnum(e.kind)] = e.non_electrical;
        break :blk lut;
    };
    const injected_net_lut: [N]?[]const u8 = blk: {
        var lut = [1]?[]const u8{null} ** N;
        for (device_table) |e| lut[@intFromEnum(e.kind)] = e.injected_net;
        break :blk lut;
    };
};

// ========================================================
// Tests
// ========================================================

test "struct sizes" {
    const print = std.debug.print;
    print("Pdk:    {d}B\n", .{@sizeOf(Pdk)});
    print("Device: {d}B\n", .{@sizeOf(Device)});
}

test "device_table built from .chn_prim files: nmos4 prefix" {
    try std.testing.expectEqual(@as(u8, 'M'), DeviceKind.nmos4.prefix());
}

test "device_table built from .chn_prim files: nmos4 pins" {
    const nmos_pins = DeviceKind.nmos4.pins();
    try std.testing.expectEqual(@as(usize, 4), nmos_pins.len);
    try std.testing.expectEqualStrings("d", nmos_pins[0]);
    try std.testing.expectEqualStrings("g", nmos_pins[1]);
    try std.testing.expectEqualStrings("s", nmos_pins[2]);
    try std.testing.expectEqualStrings("b", nmos_pins[3]);
}

test "device_table built from .chn_prim files: resistor prefix" {
    try std.testing.expectEqual(@as(u8, 'R'), DeviceKind.resistor.prefix());
}

test "device_table built from .chn_prim files: resistor pins" {
    const r_pins = DeviceKind.resistor.pins();
    try std.testing.expectEqual(@as(usize, 2), r_pins.len);
    try std.testing.expectEqualStrings("p", r_pins[0]);
    try std.testing.expectEqualStrings("n", r_pins[1]);
}

test "device_table built from .chn_prim files: gnd is non-electrical" {
    try std.testing.expect(DeviceKind.gnd.isNonElectrical());
    try std.testing.expectEqual(@as(u8, 0), DeviceKind.gnd.prefix());
    try std.testing.expectEqualStrings("0", DeviceKind.gnd.injectedNetName().?);
}

test "device_table built from .chn_prim files: vdd is non-electrical" {
    try std.testing.expect(DeviceKind.vdd.isNonElectrical());
    try std.testing.expectEqualStrings("VDD", DeviceKind.vdd.injectedNetName().?);
}

test "legacy entries preserved: var_resistor" {
    try std.testing.expectEqual(@as(u8, 'R'), DeviceKind.var_resistor.prefix());
}

test "legacy entries preserved: subckt" {
    try std.testing.expectEqual(@as(u8, 'X'), DeviceKind.subckt.prefix());
}

test "legacy entries preserved: mesfet" {
    try std.testing.expectEqual(@as(u8, 'Z'), DeviceKind.mesfet.prefix());
    try std.testing.expectEqualStrings("NMF", DeviceKind.mesfet.modelKeyword().?);
}

test "fromStr round-trips" {
    try std.testing.expectEqual(DeviceKind.nmos4, DeviceKind.fromStr("nmos4"));
    try std.testing.expectEqual(DeviceKind.resistor, DeviceKind.fromStr("resistor"));
    try std.testing.expectEqual(DeviceKind.unknown, DeviceKind.fromStr("nonexistent"));
}

test "controlled source pins from .chn_prim" {
    const vcvs_pins = DeviceKind.vcvs.pins();
    try std.testing.expectEqual(@as(usize, 4), vcvs_pins.len);
    try std.testing.expectEqualStrings("p", vcvs_pins[0]);
    try std.testing.expectEqualStrings("n", vcvs_pins[1]);
    try std.testing.expectEqualStrings("cp", vcvs_pins[2]);
    try std.testing.expectEqualStrings("cn", vcvs_pins[3]);
}

test "isMosfet classification" {
    try std.testing.expect(DeviceKind.nmos4.isMosfet());
    try std.testing.expect(DeviceKind.pmos4.isMosfet());
    try std.testing.expect(DeviceKind.nmos3.isMosfet());
    try std.testing.expect(!DeviceKind.resistor.isMosfet());
}

test "Device.fromBuiltin returns null for non-electrical" {
    try std.testing.expect(Device.fromBuiltin(.gnd) == null);
    try std.testing.expect(Device.fromBuiltin(.lab_pin) == null);
    try std.testing.expect(Device.fromBuiltin(.nmos4) != null);
}

test "primitives module accessible" {
    // Verify the parsed_prims array is accessible and contains data
    try std.testing.expect(primitives.prim_count > 0);
    // Verify we can look up by name
    const r = primitives.findByName("resistor");
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u8, 'R'), r.?.prefix);
}
