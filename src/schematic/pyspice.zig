const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const types = @import("types.zig");
const helpers = @import("helpers.zig");
const sp = @import("string_pool.zig");
const StringRef = sp.StringRef;
const StringPool = sp.StringPool;
const Instance = types.Instance;
const Property = types.Property;
const Conn = types.Conn;
const DeviceKind = types.DeviceKind;

// ── Unit family for value formatting ─────────────────────────────────────────

const UnitFamily = enum { resistor, capacitor, inductor, vsource, isource };

fn unitDefault(family: UnitFamily) []const u8 {
    return switch (family) {
        .resistor => "0@u_Ohm",
        .capacitor => "0@u_F",
        .inductor => "0@u_H",
        .vsource => "0@u_V",
        .isource => "0@u_A",
    };
}

/// Convert SPICE value with SI suffix to Python-compatible numeric string.
/// Returns a static buffer — caller must use immediately or copy.
var py_val_buf: [64]u8 = undefined;

fn pyUnitValue(val: []const u8, family: UnitFamily) []const u8 {
    if (val.len == 0) return unitDefault(family);
    // Try to parse as number with SPICE suffix
    const suffix_info = parseSpiceSuffix(val);
    if (suffix_info.mantissa.len > 0) {
        const result = std.fmt.bufPrint(&py_val_buf, "{s}{s}", .{ suffix_info.mantissa, suffix_info.exponent }) catch return val;
        return result;
    }
    return val;
}

const SuffixResult = struct { mantissa: []const u8, exponent: []const u8 };

fn parseSpiceSuffix(val: []const u8) SuffixResult {
    if (val.len == 0) return .{ .mantissa = "", .exponent = "" };
    // Find where the suffix starts (first non-digit, non-dot, non-sign, non-e)
    var i: usize = 0;
    if (i < val.len and (val[i] == '+' or val[i] == '-')) i += 1;
    while (i < val.len and (std.ascii.isDigit(val[i]) or val[i] == '.')) : (i += 1) {}
    // Already has 'e' exponent — it's already Python-compatible
    if (i < val.len and (val[i] == 'e' or val[i] == 'E')) return .{ .mantissa = "", .exponent = "" };
    if (i == val.len) return .{ .mantissa = "", .exponent = "" }; // pure number, fine as-is
    if (i == 0) return .{ .mantissa = "", .exponent = "" }; // no numeric prefix

    const mantissa = val[0..i];
    const suffix = val[i..];
    const exp = spiceSuffixExponent(suffix) orelse return .{ .mantissa = "", .exponent = "" };
    return .{ .mantissa = mantissa, .exponent = exp };
}

fn spiceSuffixExponent(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    const c = std.ascii.toLower(s[0]);
    return switch (c) {
        't' => "e12",
        'g' => "e9",
        'x' => "e6", // meg
        'k' => "e3",
        'm' => if (s.len >= 3 and std.ascii.toLower(s[1]) == 'e' and std.ascii.toLower(s[2]) == 'g') "e6" else "e-3",
        'u' => "e-6",
        'n' => "e-9",
        'p' => "e-12",
        'f' => "e-15",
        else => null,
    };
}

// ── Net helpers ──────────────────────────────────────────────────────────────

fn isGndNet(net: []const u8) bool {
    return std.mem.eql(u8, net, "0") or std.ascii.eqlIgnoreCase(net, "gnd");
}

fn writePyNetArg(w: anytype, net: []const u8) !void {
    if (isGndNet(net)) {
        try w.writeAll("circuit.gnd");
    } else {
        try w.writeByte('\'');
        try w.writeAll(net);
        try w.writeByte('\'');
    }
}

/// Detect complex source specifications (DC+AC, SIN, PULSE, etc.)
fn isComplexSourceValue(val: []const u8) bool {
    if (std.mem.indexOfScalar(u8, val, ' ') != null) return true;
    if (std.mem.indexOfScalar(u8, val, '(') != null) return true;
    // Check for SPICE keywords
    var buf: [8]u8 = undefined;
    const lo = if (val.len <= 8) blk: {
        for (val[0..@min(val.len, 8)], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        break :blk buf[0..@min(val.len, 8)];
    } else val[0..0];
    if (std.mem.startsWith(u8, lo, "dc") or std.mem.startsWith(u8, lo, "ac") or
        std.mem.startsWith(u8, lo, "sin") or std.mem.startsWith(u8, lo, "pulse") or
        std.mem.startsWith(u8, lo, "pwl")) return true;
    return false;
}

/// Write a Python-safe variable name: replace chars invalid in identifiers with '_'.
fn writePyVarName(w: anytype, name: []const u8) !void {
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try w.writeByte(c);
        } else {
            try w.writeByte('_');
        }
    }
}

fn resolveConnNet(pool: *const StringPool, pin_name: []const u8, conns_slice: []const Conn) ?[]const u8 {
    for (conns_slice) |c| {
        if (std.mem.eql(u8, pool.get(c.pin), pin_name)) return pool.get(c.net);
    }
    return null;
}

fn connNetAt(pool: *const StringPool, conns_slice: []const Conn, idx: usize) []const u8 {
    if (idx < conns_slice.len) return pool.get(conns_slice[idx].net);
    return "0";
}

fn allConnsZero(pool: *const StringPool, conns_slice: []const Conn) bool {
    for (conns_slice) |c| {
        const net = pool.get(c.net);
        if (!std.mem.eql(u8, net, "0") and net.len > 0) return false;
    }
    return true;
}

fn normalizedSymbolName(sym: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, sym, '/')) |pos| sym[pos + 1 ..] else sym;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

fn makeDesignator(raw_name: []const u8) []const u8 {
    if (raw_name.len > 1 and std.ascii.isAlphabetic(raw_name[0])) return raw_name[1..];
    return raw_name;
}

fn findProp(pool: *const StringPool, prop_slice: []const Property, key: []const u8) ?[]const u8 {
    for (prop_slice) |p| if (std.mem.eql(u8, pool.get(p.key), key)) return pool.get(p.val);
    return null;
}

// ═════════════════════════════════════════════════════════════════════════════
// Public API
// ═════════════════════════════════════════════════════════════════════════════

pub const Mode = enum {
    /// Emit subcircuit instances as circuit.X() calls (default).
    hierarchical,
    /// Skip subcircuit/digital instances — only emit primitive devices.
    top_only,
    /// Emit subcircuit instances + request PySpice-rs to flatten internally.
    flat,
};

/// Pure function: schematic data + connectivity -> PySpice-rs Python circuit definition.
/// Returns the circuit-building code only (no imports, no analysis section).
/// Caller owns the returned slice.
///
/// `conn_starts` and `conn_counts` are parallel arrays indexed by instance
/// position, mapping each instance to its range within `conns`.
pub fn emitCircuitDef(
    a: Allocator,
    pool: *const StringPool,
    name: []const u8,
    instances: []const Instance,
    props: []const Property,
    conns: []const Conn,
    conn_starts: []const u32,
    conn_counts: []const u16,
    model_defs: []const types.ModelDef,
) ![]u8 {
    return emitCircuitDefMode(a, pool, name, instances, props, conns, conn_starts, conn_counts, model_defs, .hierarchical);
}

/// Like `emitCircuitDef` but with explicit netlist mode.
pub fn emitCircuitDefMode(
    a: Allocator,
    pool: *const StringPool,
    name: []const u8,
    instances: []const Instance,
    props: []const Property,
    conns: []const Conn,
    conn_starts: []const u32,
    conn_counts: []const u16,
    model_defs: []const types.ModelDef,
    mode: Mode,
) ![]u8 {
    var buf: List(u8) = .{};
    errdefer buf.deinit(a);
    const w = buf.writer(a);

    try w.print("circuit = Circuit('{s}')\n", .{name});

    // Emit model definitions
    for (model_defs) |md| {
        const md_name = pool.get(md.name);
        const md_kind = pool.get(md.kind);
        try w.print("circuit.model('{s}', '{s}'", .{ md_name, md_kind });
        const md_props = props[md.prop_start..][0..md.prop_count];
        for (md_props) |p| {
            const key = pool.get(p.key);
            const val = pool.get(p.val);
            // Python reserved word 'is' needs ** dict expansion
            if (std.mem.eql(u8, key, "is")) {
                try w.print(", **{{'is': {s}}}", .{val});
            } else {
                try w.print(", {s}={s}", .{ key, val });
            }
        }
        try w.writeAll(")\n");
    }

    for (instances, 0..) |inst, idx| {
        const kind = inst.kind;

        if (kind == .code or kind == .param) continue;
        if (kind.isNonElectrical()) continue;
        if (kind.isLabel()) continue;
        if (kind.isPower()) continue;

        const cs = if (idx < conn_starts.len) conn_starts[idx] else 0;
        const cc = if (idx < conn_counts.len) conn_counts[idx] else 0;
        const inst_conns = if (cc > 0) conns[cs..][0..cc] else &[0]Conn{};
        if (inst_conns.len == 0) continue;
        if (allConnsZero(pool, inst_conns)) continue;

        const inst_props = props[inst.prop_start..][0..inst.prop_count];
        const raw_name = pool.get(inst.name);
        const sym_name = pool.get(inst.symbol);
        const desig = makeDesignator(raw_name);

        switch (kind) {
            .resistor, .resistor3, .var_resistor => {
                const val = findProp(pool, inst_props, "value") orelse "1k";
                const net_a = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const net_b = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.R(name='{s}', positive=", .{desig});
                try writePyNetArg(w, net_a);
                try w.writeAll(", negative=");
                try writePyNetArg(w, net_b);
                try w.print(", value={s})\n", .{pyUnitValue(val, .resistor)});
            },
            .capacitor => {
                const val = findProp(pool, inst_props, "value") orelse "1p";
                const net_a = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const net_b = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.C(name='{s}', positive=", .{desig});
                try writePyNetArg(w, net_a);
                try w.writeAll(", negative=");
                try writePyNetArg(w, net_b);
                try w.print(", value={s})\n", .{pyUnitValue(val, .capacitor)});
            },
            .inductor => {
                const val = findProp(pool, inst_props, "value") orelse "1u";
                const net_a = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const net_b = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.L(name='{s}', positive=", .{desig});
                try writePyNetArg(w, net_a);
                try w.writeAll(", negative=");
                try writePyNetArg(w, net_b);
                try w.print(", value={s})\n", .{pyUnitValue(val, .inductor)});
            },

            .nmos3, .pmos3, .nmos4, .pmos4, .nmos4_depl,
            .nmos_sub, .pmos_sub, .nmoshv4, .pmoshv4, .rnmos4,
            => {
                const drain = resolveConnNet(pool, "d", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const gate = resolveConnNet(pool, "g", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const source = resolveConnNet(pool, "s", inst_conns) orelse connNetAt(pool, inst_conns, 2);
                const bulk = if (inst_conns.len >= 4)
                    (resolveConnNet(pool, "b", inst_conns) orelse connNetAt(pool, inst_conns, 3))
                else
                    source;
                const model_name = findProp(pool, inst_props, "model") orelse
                    findProp(pool, inst_props, "device_model") orelse
                    normalizedSymbolName(sym_name);
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.M(name='{s}', drain=", .{desig});
                try writePyNetArg(w, drain);
                try w.writeAll(", gate=");
                try writePyNetArg(w, gate);
                try w.writeAll(", source=");
                try writePyNetArg(w, source);
                try w.writeAll(", bulk=");
                try writePyNetArg(w, bulk);
                try w.print(", model='{s}'", .{model_name});
                if (findProp(pool, inst_props, "W")) |wv| try w.print(", W='{s}'", .{wv});
                if (findProp(pool, inst_props, "w")) |wv| try w.print(", W='{s}'", .{wv});
                if (findProp(pool, inst_props, "L")) |lv| try w.print(", L='{s}'", .{lv});
                if (findProp(pool, inst_props, "l")) |lv| try w.print(", L='{s}'", .{lv});
                if (findProp(pool, inst_props, "M")) |mv| {
                    if (!std.mem.eql(u8, mv, "1")) try w.print(", M={s}", .{mv});
                }
                try w.writeAll(")\n");
            },

            .npn, .pnp => {
                const collector = resolveConnNet(pool, "C", inst_conns) orelse
                    resolveConnNet(pool, "c", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const base = resolveConnNet(pool, "B", inst_conns) orelse
                    resolveConnNet(pool, "b", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const emitter = resolveConnNet(pool, "E", inst_conns) orelse
                    resolveConnNet(pool, "e", inst_conns) orelse connNetAt(pool, inst_conns, 2);
                const model_name = findProp(pool, inst_props, "model") orelse
                    findProp(pool, inst_props, "device_model") orelse
                    normalizedSymbolName(sym_name);
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.Q(name='{s}', collector=", .{desig});
                try writePyNetArg(w, collector);
                try w.writeAll(", base=");
                try writePyNetArg(w, base);
                try w.writeAll(", emitter=");
                try writePyNetArg(w, emitter);
                try w.print(", model='{s}')\n", .{model_name});
            },

            .diode, .zener => {
                const anode = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const cathode = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const model_name = findProp(pool, inst_props, "model") orelse
                    findProp(pool, inst_props, "device_model") orelse
                    normalizedSymbolName(sym_name);
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.D(name='{s}', anode=", .{desig});
                try writePyNetArg(w, anode);
                try w.writeAll(", cathode=");
                try writePyNetArg(w, cathode);
                try w.print(", model='{s}')\n", .{model_name});
            },

            .vsource => {
                const val = findProp(pool, inst_props, "value") orelse findProp(pool, inst_props, "dc") orelse "0";
                const net_p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const net_n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                if (isComplexSourceValue(val)) {
                    try w.print("circuit.raw_spice('{s} {s} {s} {s}')\n", .{ raw_name, net_p, net_n, val });
                } else {
                    try writePyVarName(w, raw_name);
                    try w.print(" = circuit.V(name='{s}', positive=", .{desig});
                    try writePyNetArg(w, net_p);
                    try w.writeAll(", negative=");
                    try writePyNetArg(w, net_n);
                    try w.print(", value={s})\n", .{pyUnitValue(val, .vsource)});
                }
            },
            .isource => {
                const val = findProp(pool, inst_props, "value") orelse findProp(pool, inst_props, "dc") orelse "0";
                const net_p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const net_n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                if (isComplexSourceValue(val)) {
                    try w.print("circuit.raw_spice('{s} {s} {s} {s}')\n", .{ raw_name, net_p, net_n, val });
                } else {
                    try writePyVarName(w, raw_name);
                    try w.print(" = circuit.I(name='{s}', positive=", .{desig});
                    try writePyNetArg(w, net_p);
                    try w.writeAll(", negative=");
                    try writePyNetArg(w, net_n);
                    try w.print(", value={s})\n", .{pyUnitValue(val, .isource)});
                }
            },

            .vcvs => {
                const p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const cp = resolveConnNet(pool, "cp", inst_conns) orelse connNetAt(pool, inst_conns, 2);
                const cn = resolveConnNet(pool, "cn", inst_conns) orelse connNetAt(pool, inst_conns, 3);
                const gain = findProp(pool, inst_props, "gain") orelse findProp(pool, inst_props, "value") orelse "1";
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.E(name='{s}', positive=", .{desig});
                try writePyNetArg(w, p);
                try w.writeAll(", negative=");
                try writePyNetArg(w, n);
                try w.writeAll(", control_positive=");
                try writePyNetArg(w, cp);
                try w.writeAll(", control_negative=");
                try writePyNetArg(w, cn);
                try w.print(", voltage_gain={s})\n", .{gain});
            },
            .vccs => {
                const p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const cp = resolveConnNet(pool, "cp", inst_conns) orelse connNetAt(pool, inst_conns, 2);
                const cn = resolveConnNet(pool, "cn", inst_conns) orelse connNetAt(pool, inst_conns, 3);
                const gain = findProp(pool, inst_props, "gain") orelse findProp(pool, inst_props, "value") orelse "1";
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.G(name='{s}', positive=", .{desig});
                try writePyNetArg(w, p);
                try w.writeAll(", negative=");
                try writePyNetArg(w, n);
                try w.writeAll(", control_positive=");
                try writePyNetArg(w, cp);
                try w.writeAll(", control_negative=");
                try writePyNetArg(w, cn);
                try w.print(", transconductance={s})\n", .{gain});
            },
            .ccvs => {
                const p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const vsrc = findProp(pool, inst_props, "vsrc") orelse findProp(pool, inst_props, "model") orelse "V0";
                const gain = findProp(pool, inst_props, "gain") orelse findProp(pool, inst_props, "value") orelse "1";
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.H(name='{s}', positive=", .{desig});
                try writePyNetArg(w, p);
                try w.writeAll(", negative=");
                try writePyNetArg(w, n);
                try w.print(", vsense='{s}', transresistance={s})\n", .{ vsrc, gain });
            },
            .cccs => {
                const p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const vsrc = findProp(pool, inst_props, "vsrc") orelse findProp(pool, inst_props, "model") orelse "V0";
                const gain = findProp(pool, inst_props, "gain") orelse findProp(pool, inst_props, "value") orelse "1";
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.F(name='{s}', positive=", .{desig});
                try writePyNetArg(w, p);
                try w.writeAll(", negative=");
                try writePyNetArg(w, n);
                try w.print(", vsense='{s}', current_gain={s})\n", .{ vsrc, gain });
            },

            .subckt, .digital_instance => {
                if (mode == .top_only) continue;
                const sub_name = normalizedSymbolName(sym_name);
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.X('{s}', '{s}'", .{ desig, sub_name });
                for (inst_conns) |c| {
                    try w.writeAll(", ");
                    try writePyNetArg(w, pool.get(c.net));
                }
                try w.writeAll(")\n");
            },

            .gnd, .vdd, .lab_pin, .input_pin, .output_pin, .inout_pin => continue,

            else => {
                if (mode == .top_only) continue;
                const sub_name = normalizedSymbolName(sym_name);
                try writePyVarName(w, raw_name);
                try w.print(" = circuit.X('{s}', '{s}'", .{ desig, sub_name });
                for (inst_conns) |c| {
                    try w.writeAll(", ");
                    try writePyNetArg(w, pool.get(c.net));
                }
                try w.writeAll(")\n");
            },
        }
    }

    if (mode == .flat) {
        try w.writeAll("circuit = circuit.build_flat_circuit()\n");
    }

    return buf.toOwnedSlice(a);
}

/// Full template: imports + circuit def + marker + placeholder analysis.
/// Caller owns the returned slice.
pub fn emitTemplate(
    a: Allocator,
    pool: *const StringPool,
    name: []const u8,
    instances: []const Instance,
    props: []const Property,
    conns: []const Conn,
    conn_starts: []const u32,
    conn_counts: []const u16,
    model_defs: []const types.ModelDef,
    backend: []const u8,
) ![]u8 {
    return emitTemplateMode(a, pool, name, instances, props, conns, conn_starts, conn_counts, model_defs, backend, .hierarchical);
}

/// Like `emitTemplate` but with explicit netlist mode.
pub fn emitTemplateMode(
    a: Allocator,
    pool: *const StringPool,
    name: []const u8,
    instances: []const Instance,
    props: []const Property,
    conns: []const Conn,
    conn_starts: []const u32,
    conn_counts: []const u16,
    model_defs: []const types.ModelDef,
    backend: []const u8,
    mode: Mode,
) ![]u8 {
    const circuit_def = try emitCircuitDefMode(a, pool, name, instances, props, conns, conn_starts, conn_counts, model_defs, mode);
    defer a.free(circuit_def);

    var buf: List(u8) = .{};
    errdefer buf.deinit(a);
    const w = buf.writer(a);

    try w.writeAll(
        \\#!/usr/bin/env python3
        \\# Auto-generated by Schemify — circuit definition above marker, analysis below
        \\from pyspice_rs import Circuit
        \\from pyspice_rs.unit import *
        \\
        \\
    );
    try w.writeAll(circuit_def);
    try w.writeAll(
        \\
        \\# ──── SCHEMIFY_MARKER ──── (do not edit above this line)
        \\# Analysis code — edit freely below
        \\
        \\
    );
    try w.print("sim = circuit.simulator(simulator='{s}')\n", .{backend});
    try w.writeAll(
        \\sim.temperature = 27
        \\
        \\# Example: operating point
        \\# result = sim.operating_point()
        \\# for node in result.nodes.values():
        \\#     print(f"{node}: {float(node):.4g} V")
        \\
    );

    return buf.toOwnedSlice(a);
}

// ═════════════════════════════════════════════════════════════════════════════
// Tests
// ═════════════════════════════════════════════════════════════════════════════

const TestHelper = struct {
    pool: StringPool,
    a: Allocator,

    fn init(a: Allocator) TestHelper {
        return .{ .pool = .{}, .a = a };
    }

    fn deinit(self: *TestHelper) void {
        self.pool.deinit(self.a);
    }

    fn str(self: *TestHelper, s: []const u8) StringRef {
        return self.pool.add(self.a, s) catch unreachable;
    }
};

test "empty circuit" {
    const a = std.testing.allocator;
    var pool: StringPool = .{};
    defer pool.deinit(a);

    const result = try emitCircuitDef(a, &pool, "test", &.{}, &.{}, &.{}, &.{}, &.{}, &.{});
    defer a.free(result);
    try std.testing.expectEqualStrings("circuit = Circuit('test')\n", result);
}

test "resistor emission" {
    const a = std.testing.allocator;
    var h = TestHelper.init(a);
    defer h.deinit();

    const test_props = [_]Property{
        .{ .key = h.str("value"), .val = h.str("10k") },
    };
    const test_conns = [_]Conn{
        .{ .pin = h.str("p"), .net = h.str("vcc") },
        .{ .pin = h.str("n"), .net = h.str("out") },
    };
    const instances = [_]Instance{
        .{
            .name = h.str("R1"),
            .symbol = h.str("res"),
            .kind = .resistor,
            .prop_start = 0,
            .prop_count = 1,
        },
    };
    const conn_starts = [_]u32{0};
    const conn_counts = [_]u16{2};
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &test_props, &test_conns, &conn_starts, &conn_counts, &.{});
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.R(name='1', positive='vcc', negative='out', value=10e3)") != null);
}

test "ground net substitution" {
    const a = std.testing.allocator;
    var h = TestHelper.init(a);
    defer h.deinit();

    const test_conns = [_]Conn{
        .{ .pin = h.str("p"), .net = h.str("vcc") },
        .{ .pin = h.str("n"), .net = h.str("0") },
    };
    const test_props = [_]Property{
        .{ .key = h.str("value"), .val = h.str("5") },
    };
    const instances = [_]Instance{
        .{
            .name = h.str("V1"),
            .symbol = h.str("vsource"),
            .kind = .vsource,
            .prop_start = 0,
            .prop_count = 1,
        },
    };
    const conn_starts = [_]u32{0};
    const conn_counts = [_]u16{2};
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &test_props, &test_conns, &conn_starts, &conn_counts, &.{});
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.gnd") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "'0'") == null);
}

test "mosfet emission" {
    const a = std.testing.allocator;
    var h = TestHelper.init(a);
    defer h.deinit();

    const test_conns = [_]Conn{
        .{ .pin = h.str("d"), .net = h.str("drain") },
        .{ .pin = h.str("g"), .net = h.str("gate") },
        .{ .pin = h.str("s"), .net = h.str("0") },
        .{ .pin = h.str("b"), .net = h.str("0") },
    };
    const test_props = [_]Property{
        .{ .key = h.str("model"), .val = h.str("nch") },
        .{ .key = h.str("W"), .val = h.str("1u") },
        .{ .key = h.str("L"), .val = h.str("180n") },
    };
    const instances = [_]Instance{
        .{
            .name = h.str("M1"),
            .symbol = h.str("nmos4"),
            .kind = .nmos4,
            .prop_start = 0,
            .prop_count = 3,
        },
    };
    const conn_starts = [_]u32{0};
    const conn_counts = [_]u16{4};
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &test_props, &test_conns, &conn_starts, &conn_counts, &.{});
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.M(name='1', drain='drain', gate='gate', source=circuit.gnd, bulk=circuit.gnd, model='nch'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "W='1u'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L='180n'") != null);
}

test "template has marker" {
    const a = std.testing.allocator;
    var pool: StringPool = .{};
    defer pool.deinit(a);

    const result = try emitTemplate(a, &pool, "test", &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, "ngspice");
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "SCHEMIFY_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "from pyspice_rs import Circuit") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "simulator='ngspice'") != null);
}

test "subcircuit emission" {
    const a = std.testing.allocator;
    var h = TestHelper.init(a);
    defer h.deinit();

    const test_conns = [_]Conn{
        .{ .pin = h.str("in"), .net = h.str("vin") },
        .{ .pin = h.str("out"), .net = h.str("vout") },
        .{ .pin = h.str("vss"), .net = h.str("gnd") },
    };
    const instances = [_]Instance{
        .{
            .name = h.str("X1"),
            .symbol = h.str("mylib/opamp.sym"),
            .kind = .subckt,
            .prop_start = 0,
            .prop_count = 0,
        },
    };
    const conn_starts = [_]u32{0};
    const conn_counts = [_]u16{3};
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &.{}, &test_conns, &conn_starts, &conn_counts, &.{});
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.X('1', 'opamp'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.gnd") != null);
}

test "bjt emission" {
    const a = std.testing.allocator;
    var h = TestHelper.init(a);
    defer h.deinit();

    const test_conns = [_]Conn{
        .{ .pin = h.str("C"), .net = h.str("vcc") },
        .{ .pin = h.str("B"), .net = h.str("base") },
        .{ .pin = h.str("E"), .net = h.str("0") },
    };
    const test_props = [_]Property{
        .{ .key = h.str("model"), .val = h.str("2N2222") },
    };
    const instances = [_]Instance{
        .{
            .name = h.str("Q1"),
            .symbol = h.str("npn"),
            .kind = .npn,
            .prop_start = 0,
            .prop_count = 1,
        },
    };
    const conn_starts = [_]u32{0};
    const conn_counts = [_]u16{3};
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &test_props, &test_conns, &conn_starts, &conn_counts, &.{});
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.Q(name='1', collector='vcc', base='base', emitter=circuit.gnd, model='2N2222')") != null);
}

test "diode emission" {
    const a = std.testing.allocator;
    var h = TestHelper.init(a);
    defer h.deinit();

    const test_conns = [_]Conn{
        .{ .pin = h.str("p"), .net = h.str("anode_net") },
        .{ .pin = h.str("n"), .net = h.str("cathode_net") },
    };
    const test_props = [_]Property{
        .{ .key = h.str("model"), .val = h.str("1N4148") },
    };
    const instances = [_]Instance{
        .{
            .name = h.str("D1"),
            .symbol = h.str("diode"),
            .kind = .diode,
            .prop_start = 0,
            .prop_count = 1,
        },
    };
    const conn_starts = [_]u32{0};
    const conn_counts = [_]u16{2};
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &test_props, &test_conns, &conn_starts, &conn_counts, &.{});
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.D(name='1', anode='anode_net', cathode='cathode_net', model='1N4148')") != null);
}

test "skips non-electrical instances" {
    const a = std.testing.allocator;
    var h = TestHelper.init(a);
    defer h.deinit();

    const instances = [_]Instance{
        .{ .name = h.str("T1"), .symbol = h.str("title"), .kind = .title },
        .{ .name = h.str("A1"), .symbol = h.str("annotation"), .kind = .annotation },
        .{ .name = h.str("P1"), .symbol = h.str("param"), .kind = .param },
        .{ .name = h.str("GND"), .symbol = h.str("gnd"), .kind = .gnd },
        .{ .name = h.str("VDD"), .symbol = h.str("vdd"), .kind = .vdd },
        .{ .name = h.str("lab"), .symbol = h.str("lab_pin"), .kind = .lab_pin },
    };
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &.{}, &.{}, &.{}, &.{}, &.{});
    defer a.free(result);

    try std.testing.expectEqualStrings("circuit = Circuit('test')\n", result);
}
