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

fn pyUnitValue(val: []const u8, family: UnitFamily) []const u8 {
    if (val.len == 0) return unitDefault(family);
    return val;
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
) ![]u8 {
    var buf: List(u8) = .{};
    errdefer buf.deinit(a);
    const w = buf.writer(a);

    try w.print("circuit = Circuit('{s}')\n", .{name});

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
                try w.print("{s} = circuit.R('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, net_a);
                try w.writeAll(", ");
                try writePyNetArg(w, net_b);
                try w.print(", {s})\n", .{pyUnitValue(val, .resistor)});
            },
            .capacitor => {
                const val = findProp(pool, inst_props, "value") orelse "1p";
                const net_a = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const net_b = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                try w.print("{s} = circuit.C('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, net_a);
                try w.writeAll(", ");
                try writePyNetArg(w, net_b);
                try w.print(", {s})\n", .{pyUnitValue(val, .capacitor)});
            },
            .inductor => {
                const val = findProp(pool, inst_props, "value") orelse "1u";
                const net_a = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const net_b = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                try w.print("{s} = circuit.L('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, net_a);
                try w.writeAll(", ");
                try writePyNetArg(w, net_b);
                try w.print(", {s})\n", .{pyUnitValue(val, .inductor)});
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
                try w.print("{s} = circuit.MOSFET('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, drain);
                try w.writeAll(", ");
                try writePyNetArg(w, gate);
                try w.writeAll(", ");
                try writePyNetArg(w, source);
                try w.writeAll(", ");
                try writePyNetArg(w, bulk);
                try w.print(", model='{s}'", .{model_name});
                if (findProp(pool, inst_props, "W")) |wv| try w.print(", W={s}", .{wv});
                if (findProp(pool, inst_props, "w")) |wv| try w.print(", W={s}", .{wv});
                if (findProp(pool, inst_props, "L")) |lv| try w.print(", L={s}", .{lv});
                if (findProp(pool, inst_props, "l")) |lv| try w.print(", L={s}", .{lv});
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
                try w.print("{s} = circuit.BJT('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, collector);
                try w.writeAll(", ");
                try writePyNetArg(w, base);
                try w.writeAll(", ");
                try writePyNetArg(w, emitter);
                try w.print(", model='{s}')\n", .{model_name});
            },

            .diode, .zener => {
                const anode = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const cathode = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const model_name = findProp(pool, inst_props, "model") orelse
                    findProp(pool, inst_props, "device_model") orelse
                    normalizedSymbolName(sym_name);
                try w.print("{s} = circuit.D('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, anode);
                try w.writeAll(", ");
                try writePyNetArg(w, cathode);
                try w.print(", model='{s}')\n", .{model_name});
            },

            .vsource => {
                const val = findProp(pool, inst_props, "value") orelse findProp(pool, inst_props, "dc") orelse "0";
                const net_p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const net_n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                try w.print("{s} = circuit.V('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, net_p);
                try w.writeAll(", ");
                try writePyNetArg(w, net_n);
                try w.print(", {s})\n", .{pyUnitValue(val, .vsource)});
            },
            .isource => {
                const val = findProp(pool, inst_props, "value") orelse findProp(pool, inst_props, "dc") orelse "0";
                const net_p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const net_n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                try w.print("{s} = circuit.I('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, net_p);
                try w.writeAll(", ");
                try writePyNetArg(w, net_n);
                try w.print(", {s})\n", .{pyUnitValue(val, .isource)});
            },

            .vcvs => {
                const p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const cp = resolveConnNet(pool, "cp", inst_conns) orelse connNetAt(pool, inst_conns, 2);
                const cn = resolveConnNet(pool, "cn", inst_conns) orelse connNetAt(pool, inst_conns, 3);
                const gain = findProp(pool, inst_props, "gain") orelse findProp(pool, inst_props, "value") orelse "1";
                try w.print("{s} = circuit.VCVS('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, p);
                try w.writeAll(", ");
                try writePyNetArg(w, n);
                try w.writeAll(", ");
                try writePyNetArg(w, cp);
                try w.writeAll(", ");
                try writePyNetArg(w, cn);
                try w.print(", {s})\n", .{gain});
            },
            .vccs => {
                const p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const cp = resolveConnNet(pool, "cp", inst_conns) orelse connNetAt(pool, inst_conns, 2);
                const cn = resolveConnNet(pool, "cn", inst_conns) orelse connNetAt(pool, inst_conns, 3);
                const gain = findProp(pool, inst_props, "gain") orelse findProp(pool, inst_props, "value") orelse "1";
                try w.print("{s} = circuit.VCCS('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, p);
                try w.writeAll(", ");
                try writePyNetArg(w, n);
                try w.writeAll(", ");
                try writePyNetArg(w, cp);
                try w.writeAll(", ");
                try writePyNetArg(w, cn);
                try w.print(", {s})\n", .{gain});
            },
            .ccvs => {
                const p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const vsrc = findProp(pool, inst_props, "vsrc") orelse "V0";
                const gain = findProp(pool, inst_props, "gain") orelse findProp(pool, inst_props, "value") orelse "1";
                try w.print("{s} = circuit.CCVS('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, p);
                try w.writeAll(", ");
                try writePyNetArg(w, n);
                try w.print(", '{s}', {s})\n", .{ vsrc, gain });
            },
            .cccs => {
                const p = resolveConnNet(pool, "p", inst_conns) orelse connNetAt(pool, inst_conns, 0);
                const n = resolveConnNet(pool, "n", inst_conns) orelse connNetAt(pool, inst_conns, 1);
                const vsrc = findProp(pool, inst_props, "vsrc") orelse "V0";
                const gain = findProp(pool, inst_props, "gain") orelse findProp(pool, inst_props, "value") orelse "1";
                try w.print("{s} = circuit.CCCS('{s}', ", .{ raw_name, desig });
                try writePyNetArg(w, p);
                try w.writeAll(", ");
                try writePyNetArg(w, n);
                try w.print(", '{s}', {s})\n", .{ vsrc, gain });
            },

            .subckt, .digital_instance => {
                const sub_name = normalizedSymbolName(sym_name);
                try w.print("{s} = circuit.X('{s}', '{s}'", .{ raw_name, desig, sub_name });
                for (inst_conns) |c| {
                    try w.writeAll(", ");
                    try writePyNetArg(w, pool.get(c.net));
                }
                try w.writeAll(")\n");
            },

            .gnd, .vdd, .lab_pin, .input_pin, .output_pin, .inout_pin => continue,

            else => {
                const sub_name = normalizedSymbolName(sym_name);
                try w.print("{s} = circuit.X('{s}', '{s}'", .{ raw_name, desig, sub_name });
                for (inst_conns) |c| {
                    try w.writeAll(", ");
                    try writePyNetArg(w, pool.get(c.net));
                }
                try w.writeAll(")\n");
            },
        }
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
    backend: []const u8,
) ![]u8 {
    const circuit_def = try emitCircuitDef(a, pool, name, instances, props, conns, conn_starts, conn_counts);
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
    try w.print("# Backend: {s}\n", .{backend});
    try w.writeAll(
        \\
        \\# ──── SCHEMIFY_MARKER ──── (do not edit above this line)
        \\# Analysis code — edit freely below
        \\
        \\sim = circuit.simulator()
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

    const result = try emitCircuitDef(a, &pool, "test", &.{}, &.{}, &.{}, &.{}, &.{});
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
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &test_props, &test_conns, &conn_starts, &conn_counts);
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.R('1', 'vcc', 'out', 10k)") != null);
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
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &test_props, &test_conns, &conn_starts, &conn_counts);
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
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &test_props, &test_conns, &conn_starts, &conn_counts);
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.MOSFET('1', 'drain', 'gate', circuit.gnd, circuit.gnd, model='nch'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "W=1u") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L=180n") != null);
}

test "template has marker" {
    const a = std.testing.allocator;
    var pool: StringPool = .{};
    defer pool.deinit(a);

    const result = try emitTemplate(a, &pool, "test", &.{}, &.{}, &.{}, &.{}, &.{}, "ngspice");
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "SCHEMIFY_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "from pyspice_rs import Circuit") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Backend: ngspice") != null);
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
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &.{}, &test_conns, &conn_starts, &conn_counts);
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
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &test_props, &test_conns, &conn_starts, &conn_counts);
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.BJT('1', 'vcc', 'base', circuit.gnd, model='2N2222')") != null);
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
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &test_props, &test_conns, &conn_starts, &conn_counts);
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "circuit.D('1', 'anode_net', 'cathode_net', model='1N4148')") != null);
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
    const result = try emitCircuitDef(a, &h.pool, "test", &instances, &.{}, &.{}, &.{}, &.{});
    defer a.free(result);

    try std.testing.expectEqualStrings("circuit = Circuit('test')\n", result);
}
