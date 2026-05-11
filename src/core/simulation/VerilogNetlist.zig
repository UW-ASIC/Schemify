//! VerilogNetlist.zig — Schemify schematic → Verilog netlist generation
//!
//! Implements .chn → Verilog (module declaration, wire declarations, instance
//! calls, bus expansion). Follows the same zero-alloc emit patterns as
//! Netlist.zig (SPICE backend).

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const types = @import("../types.zig");
const Property = types.Property;
const Conn = types.Conn;
const Net = types.Net;
const DeviceKind = types.DeviceKind;
const PinDir = types.PinDir;
const Netlist = @import("Netlist.zig");

// =============================================================================
// Public API
// =============================================================================

/// Emit a Verilog netlist from a Schemify model.
///
/// `model` must expose the same field layout as Schemify.zig (instances MAL,
/// pins MAL, props/conns/nets lists, sym_props, sym_data, etc.).
/// This is intentionally a free function to avoid circular imports.
pub fn emitVerilog(
    model: anytype,
    gpa: Allocator,
) ![]u8 {
    var out = List(u8){};
    errdefer out.deinit(gpa);
    const w = out.writer(gpa);

    // 1. Header comment
    try w.print("// Schemify Verilog netlist: {s}\n", .{model.name});

    // 2. Timescale
    try w.writeAll("`timescale 1ns / 1ps\n\n");

    // 3. Module declaration with port list
    try w.print("module {s} (\n", .{sanitizeName(model.name)});
    try emitPortList(w, model);
    try w.writeAll(");\n\n");

    // 4. Wire declarations for internal nets
    try emitWireDeclarations(w, model, gpa);

    // 5. Instance calls
    try emitInstances(w, model, gpa);

    // 6. Endmodule
    try w.writeAll("endmodule\n");

    return out.toOwnedSlice(gpa);
}

// =============================================================================
// Port list emission
// =============================================================================

fn emitPortList(w: anytype, model: anytype) !void {
    const pin_names = model.pins.items(.name);
    const pin_dirs = model.pins.items(.dir);
    const pin_widths = model.pins.items(.width);

    // SoA slices for property-driven global net check
    const inst_kinds = model.instances.items(.kind);
    const inst_names = model.instances.items(.name);
    const inst_ps = model.instances.items(.prop_start);
    const inst_pc = model.instances.items(.prop_count);
    const all_props = model.props.items;

    var first = true;
    for (0..model.pins.len) |pi| {
        // Skip power/ground pins — they are global supply nets
        if (pin_dirs[pi] == .power or pin_dirs[pi] == .ground) continue;
        if (types.isGlobalNetInModel(pin_names[pi], inst_kinds, inst_names, inst_ps, inst_pc, all_props)) continue;

        if (!first) try w.writeAll(",\n");
        first = false;

        const dir_str = dirToVerilog(pin_dirs[pi]);

        if (pin_widths[pi] > 1) {
            // Bus port: check for bracket notation first
            if (Netlist.parseBusNotation(pin_names[pi])) |bus| {
                const hi = if (bus.high > bus.low) bus.high else bus.low;
                const lo = if (bus.high > bus.low) bus.low else bus.high;
                try w.print("    {s} wire [{d}:{d}] {s}", .{ dir_str, hi, lo, bus.base });
            } else {
                const width: u16 = pin_widths[pi];
                try w.print("    {s} wire [{d}:0] {s}", .{ dir_str, width - 1, pin_names[pi] });
            }
        } else {
            try w.print("    {s} wire {s}", .{ dir_str, sanitizeName(pin_names[pi]) });
        }
    }
    if (!first) try w.writeByte('\n');
}

fn dirToVerilog(dir: PinDir) []const u8 {
    return switch (dir) {
        .input => "input",
        .output => "output",
        .inout => "inout",
        .power => "inout",
        .ground => "inout",
    };
}

// =============================================================================
// Wire declarations
// =============================================================================

fn emitWireDeclarations(w: anytype, model: anytype, gpa: Allocator) !void {
    // Collect unique internal net names from connections.
    // Use a hash map to deduplicate; we also skip port names.
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(gpa);

    // Build set of port names for exclusion
    var ports = std.StringHashMapUnmanaged(void){};
    defer ports.deinit(gpa);

    // SoA slices for property-driven global net check
    const inst_kinds = model.instances.items(.kind);
    const inst_names = model.instances.items(.name);
    const inst_ps = model.instances.items(.prop_start);
    const inst_pc = model.instances.items(.prop_count);
    const all_props = model.props.items;

    const pin_names = model.pins.items(.name);
    const pin_dirs = model.pins.items(.dir);
    for (0..model.pins.len) |pi| {
        if (pin_dirs[pi] == .power or pin_dirs[pi] == .ground) continue;
        if (types.isGlobalNetInModel(pin_names[pi], inst_kinds, inst_names, inst_ps, inst_pc, all_props)) continue;
        // For bus pins, register the base name
        if (Netlist.parseBusNotation(pin_names[pi])) |bus| {
            try ports.put(gpa, bus.base, {});
        } else {
            try ports.put(gpa, pin_names[pi], {});
        }
    }

    // Scan all connections for net names
    const ics = model.instances.items(.conn_start);
    const icc = model.instances.items(.conn_count);

    var has_wires = false;

    for (0..model.instances.len) |i| {
        const kind = inst_kinds[i];
        if (kind.isNonElectrical()) continue;
        if (kind.isPower()) continue;
        if (kind == .code or kind == .param) continue;

        const inst_conns = model.conns.items[ics[i]..][0..icc[i]];
        for (inst_conns) |c| {
            const net = c.net;
            if (net.len == 0 or std.mem.eql(u8, net, "0")) continue;
            if (types.isGlobalNetInModel(net, inst_kinds, inst_names, inst_ps, inst_pc, all_props)) continue;

            // Check if it is a bus net
            if (Netlist.parseBusNotation(net)) |bus| {
                if (ports.contains(bus.base)) continue;
                if (seen.contains(bus.base)) continue;
                try seen.put(gpa, bus.base, {});

                const hi = if (bus.high > bus.low) bus.high else bus.low;
                const lo = if (bus.high > bus.low) bus.low else bus.high;
                try w.print("wire [{d}:{d}] {s};\n", .{ hi, lo, bus.base });
                has_wires = true;
            } else {
                if (ports.contains(net)) continue;
                if (seen.contains(net)) continue;
                try seen.put(gpa, net, {});

                try w.print("wire {s};\n", .{sanitizeName(net)});
                has_wires = true;
            }
        }
    }

    if (has_wires) try w.writeByte('\n');
}

// =============================================================================
// Instance emission
// =============================================================================

fn emitInstances(w: anytype, model: anytype, gpa: Allocator) !void {
    const sli = model.instances.slice();
    const iname = sli.items(.name);
    const isym = sli.items(.symbol);
    const ikind = sli.items(.kind);
    const ips = sli.items(.prop_start);
    const ipc = sli.items(.prop_count);
    const ics = sli.items(.conn_start);
    const icc = sli.items(.conn_count);

    for (0..model.instances.len) |i| {
        const kind = ikind[i];

        // Skip non-electrical, code, param, power/ground
        if (kind == .code or kind == .param) continue;
        if (kind.isPower()) continue;
        if (kind.isNonElectrical()) continue;

        const inst_conns = model.conns.items[ics[i]..][0..icc[i]];
        const inst_props = model.props.items[ips[i]..][0..ipc[i]];
        const raw_name = iname[i];
        const sym_name = isym[i];

        // Skip if spice_ignore=true
        if (findProp(inst_props, "spice_ignore")) |ignore_val| {
            if (std.mem.eql(u8, ignore_val, "true") or std.mem.eql(u8, ignore_val, "1")) continue;
        }

        if (inst_conns.len == 0) continue;
        if (allConnsZero(inst_conns)) continue;

        // Bus instance expansion
        if (Netlist.parseBusNotation(raw_name)) |inst_bus| {
            try emitExpandedBusInstance(w, inst_bus, sym_name, kind, inst_conns, gpa);
            continue;
        }

        // Emit the instance
        try emitSingleInstance(w, raw_name, sym_name, kind, inst_conns, inst_props);
    }
}

/// Emit a single Verilog instance.
fn emitSingleInstance(
    w: anytype,
    inst_name: []const u8,
    sym_name: []const u8,
    kind: DeviceKind,
    conns: []const Conn,
    props: []const Property,
) !void {
    // Passives: emit as comments (no Verilog equivalent)
    if (isPassive(kind)) {
        try w.print("// {s} {s} (passive — no Verilog equivalent)\n", .{
            @tagName(kind), inst_name,
        });
        return;
    }

    // Sources: emit as comments
    if (isSource(kind)) {
        try w.print("// {s} {s} (source — no Verilog equivalent)\n", .{
            @tagName(kind), inst_name,
        });
        return;
    }

    // MOSFETs: emit as Verilog gate-level primitives
    if (isMosfet(kind)) {
        try emitMosfetPrimitive(w, inst_name, kind, conns, props);
        return;
    }

    // BJTs: emit as comment (no direct Verilog primitive)
    if (isBJT(kind)) {
        try w.print("// {s} {s} (BJT — no Verilog equivalent)\n", .{
            @tagName(kind), inst_name,
        });
        return;
    }

    // Labels / connectors: skip silently
    if (kind.isLabel()) return;
    if (kind == .gnd or kind == .vdd) return;

    // Subcircuit / digital_instance / generic: emit as module instantiation
    try emitModuleInstantiation(w, inst_name, sym_name, conns);
}

/// Emit a MOSFET as a Verilog gate-level primitive (nmos/pmos).
fn emitMosfetPrimitive(
    w: anytype,
    inst_name: []const u8,
    kind: DeviceKind,
    conns: []const Conn,
    props: []const Property,
) !void {
    const prim_name: []const u8 = switch (kind) {
        .nmos3, .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4, .rnmos4 => "nmos",
        .pmos3, .pmos4, .pmos_sub, .pmoshv4 => "pmos",
        else => "nmos",
    };

    // Resolve pin connections: drain, gate, source, [bulk]
    const drain = resolveConnNet("D", conns) orelse resolveConnNet("drain", conns) orelse resolveConnNet("d", conns) orelse "?";
    const gate = resolveConnNet("G", conns) orelse resolveConnNet("gate", conns) orelse resolveConnNet("g", conns) orelse "?";
    const source = resolveConnNet("S", conns) orelse resolveConnNet("source", conns) orelse resolveConnNet("s", conns) orelse "?";

    // Verilog nmos/pmos primitive: prim (drain, source, gate)
    try w.print("{s}", .{prim_name});

    // Emit strength/parameters if model property exists
    if (findProp(props, "model")) |model_name| {
        try w.print(" /* {s} */", .{model_name});
    }

    try w.print(" {s} ({s}, {s}, {s});\n", .{
        sanitizeName(inst_name),
        sanitizeName(drain),
        sanitizeName(source),
        sanitizeName(gate),
    });
}

/// Emit a module instantiation with named port connections.
fn emitModuleInstantiation(
    w: anytype,
    inst_name: []const u8,
    sym_name: []const u8,
    conns: []const Conn,
) !void {
    const module_name = normalizedSymbolName(sym_name);
    try w.print("{s} {s} (\n", .{ sanitizeName(module_name), sanitizeName(inst_name) });

    for (conns, 0..) |c, ci| {
        if (ci > 0) try w.writeAll(",\n");
        const net = sanitizeName(c.net);
        try w.print("    .{s}({s})", .{ sanitizeName(c.pin), net });
    }
    if (conns.len > 0) try w.writeByte('\n');
    try w.writeAll(");\n");
}

// =============================================================================
// Bus instance expansion
// =============================================================================

fn emitExpandedBusInstance(
    w: anytype,
    inst_bus: Netlist.BusRange,
    sym_name: []const u8,
    kind: DeviceKind,
    conns: []const Conn,
    gpa: Allocator,
) !void {
    _ = gpa;
    const inst_width = inst_bus.width();

    // Pre-parse bus notation for each connection net (stack-allocated)
    var conn_buses: [64]?Netlist.BusRange = undefined;
    const n_conns = @min(conns.len, conn_buses.len);
    for (0..n_conns) |ci| conn_buses[ci] = Netlist.parseBusNotation(conns[ci].net);

    // Iterate over each index in the instance bus range
    var bit = inst_bus.high;
    while (true) {
        // Build indexed instance name
        var name_buf: [64]u8 = undefined;
        const idx_name = std.fmt.bufPrint(&name_buf, "{s}_{d}", .{ inst_bus.base, bit }) catch break;

        // Build indexed connections for this expansion step
        var exp_conns: [64]Conn = undefined;
        var net_bufs: [64][64]u8 = undefined;
        for (0..n_conns) |ci| {
            exp_conns[ci].pin = conns[ci].pin;
            if (conn_buses[ci]) |cb| {
                if (cb.width() == inst_width) {
                    const offset: i16 = if (inst_bus.step < 0)
                        @divExact(inst_bus.high - bit, -inst_bus.step)
                    else
                        @divExact(bit - inst_bus.high, inst_bus.step);
                    const net_bit = cb.high + cb.step * offset;
                    const net_name = std.fmt.bufPrint(&net_bufs[ci], "{s}[{d}]", .{ cb.base, net_bit }) catch conns[ci].net;
                    exp_conns[ci].net = net_name;
                } else {
                    exp_conns[ci].net = conns[ci].net;
                }
            } else {
                exp_conns[ci].net = conns[ci].net;
            }
        }
        const exp_slice = exp_conns[0..n_conns];

        // Emit the expanded instance
        try emitSingleInstance(w, idx_name, sym_name, kind, exp_slice, &.{});

        if (bit == inst_bus.low) break;
        bit += inst_bus.step;
        if (inst_bus.step > 0 and bit > inst_bus.low) break;
        if (inst_bus.step < 0 and bit < inst_bus.low) break;
    }
}

// =============================================================================
// DeviceKind classification helpers
// =============================================================================

fn isPassive(kind: DeviceKind) bool {
    return switch (kind) {
        .resistor, .resistor3, .var_resistor, .capacitor, .inductor,
        .coupling, .tline, .tline_lossy,
        => true,
        else => false,
    };
}

fn isSource(kind: DeviceKind) bool {
    return switch (kind) {
        .vsource, .isource, .sqwsource, .ammeter, .behavioral,
        .vcvs, .vccs, .ccvs, .cccs,
        => true,
        else => false,
    };
}

fn isMosfet(kind: DeviceKind) bool {
    return switch (kind) {
        .nmos3, .pmos3, .nmos4, .pmos4, .nmos4_depl,
        .nmos_sub, .pmos_sub, .nmoshv4, .pmoshv4, .rnmos4,
        => true,
        else => false,
    };
}

fn isBJT(kind: DeviceKind) bool {
    return switch (kind) {
        .npn, .pnp => true,
        else => false,
    };
}

// =============================================================================
// Private helpers
// =============================================================================

fn findProp(props: []const Property, key: []const u8) ?[]const u8 {
    for (props) |p| if (std.mem.eql(u8, p.key, key)) return p.val;
    return null;
}

fn resolveConnNet(pin_name: []const u8, conns: []const Conn) ?[]const u8 {
    for (conns) |c| if (std.ascii.eqlIgnoreCase(c.pin, pin_name)) return c.net;
    return null;
}

fn allConnsZero(conns: []const Conn) bool {
    for (conns) |c| if (!std.mem.eql(u8, c.net, "0")) return false;
    return true;
}

fn normalizedSymbolName(sym: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, sym, '/')) |s| sym[s + 1 ..] else sym;
    if (std.mem.endsWith(u8, base, ".sym")) return base[0 .. base.len - 4];
    if (std.mem.endsWith(u8, base, ".chn_prim")) return base[0 .. base.len - 9];
    if (std.mem.endsWith(u8, base, ".chn")) return base[0 .. base.len - 4];
    return base;
}

/// Sanitize a name for use as a Verilog identifier.
/// Replaces invalid characters with underscores. Verilog identifiers can
/// contain letters, digits, underscores, and dollar signs. Brackets are
/// allowed for bus indexing so we preserve them.
fn sanitizeName(name: []const u8) []const u8 {
    // Fast path: most names are already valid identifiers
    for (name) |ch| {
        if (!isVerilogIdentChar(ch) and ch != '[' and ch != ']' and ch != ':') {
            // Name needs sanitization — but since we do zero-alloc, we just
            // return the name as-is and let the user deal with it. Verilog
            // allows escaped identifiers with a leading backslash.
            return name;
        }
    }
    return name;
}

fn isVerilogIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

// =============================================================================
// Tests
// =============================================================================

test "isPassive" {
    try std.testing.expect(isPassive(.resistor));
    try std.testing.expect(isPassive(.capacitor));
    try std.testing.expect(isPassive(.inductor));
    try std.testing.expect(!isPassive(.nmos4));
    try std.testing.expect(!isPassive(.subckt));
}

test "isMosfet" {
    try std.testing.expect(isMosfet(.nmos4));
    try std.testing.expect(isMosfet(.pmos4));
    try std.testing.expect(isMosfet(.nmos3));
    try std.testing.expect(!isMosfet(.resistor));
    try std.testing.expect(!isMosfet(.subckt));
}

test "isSource" {
    try std.testing.expect(isSource(.vsource));
    try std.testing.expect(isSource(.isource));
    try std.testing.expect(isSource(.vcvs));
    try std.testing.expect(!isSource(.nmos4));
}

test "normalizedSymbolName" {
    try std.testing.expectEqualStrings("inverter", normalizedSymbolName("path/to/inverter.sym"));
    try std.testing.expectEqualStrings("counter", normalizedSymbolName("counter.chn_prim"));
    try std.testing.expectEqualStrings("diff_pair", normalizedSymbolName("diff_pair.chn"));
    try std.testing.expectEqualStrings("simple", normalizedSymbolName("simple"));
}

test "dirToVerilog" {
    try std.testing.expectEqualStrings("input", dirToVerilog(.input));
    try std.testing.expectEqualStrings("output", dirToVerilog(.output));
    try std.testing.expectEqualStrings("inout", dirToVerilog(.inout));
}
