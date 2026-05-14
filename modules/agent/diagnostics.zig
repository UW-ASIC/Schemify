const std = @import("std");
const Allocator = std.mem.Allocator;
const Schemify = @import("schematic").Schemify;
const types = @import("schematic").types;
const helpers = @import("schematic").helpers;
const mcp = @import("types.zig");

const Instance = types.Instance;
const Wire = types.Wire;
const DeviceKind = types.DeviceKind;
const Property = types.Property;
const Conn = types.Conn;
const Net = types.Net;
const NetConn = types.NetConn;
const SymData = types.SymData;
const NetMap = types.NetMap;

// ═══════════════════════════════════════════════════════════════════════════════
// JSON writer helpers
// ═══════════════════════════════════════════════════════════════════════════════

const JsonWriter = std.ArrayList(u8).Writer;

fn jsonStr(w: anytype, s: []const u8) void {
    mcp.writeJsonStr(w, s) catch {};
}

fn jsonInt(w: anytype, v: i64) void {
    std.fmt.format(w, "{d}", .{v}) catch {};
}

fn jsonBool(w: anytype, v: bool) void {
    w.writeAll(if (v) "true" else "false") catch {};
}

// ═══════════════════════════════════════════════════════════════════════════════
// 1. unrouted_pins() -> [{instance, pin}]
// ═══════════════════════════════════════════════════════════════════════════════

/// Find pins that have no net connection (conn.net == "?" or empty, or the
/// instance has no conns at all despite having sym_data pins).
pub fn unroutedPins(a: Allocator, sch: *const Schemify) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"unrouted_pins\":[") catch return "{}";

    const names = sch.instances.items(.name);
    const kinds = sch.instances.items(.kind);
    const cs = sch.instances.items(.conn_start);
    const cc = sch.instances.items(.conn_count);

    var first = true;
    for (0..sch.instances.len) |i| {
        if (kinds[i].isNonElectrical()) continue;
        if (kinds[i].isPower()) continue;

        const conn_start: usize = cs[i];
        const conn_count: usize = cc[i];

        if (conn_count == 0) {
            // Instance has no connections at all — check if it should have pins
            if (i < sch.sym_data.items.len and sch.sym_data.items[i].pins.len > 0) {
                for (sch.sym_data.items[i].pins) |pin| {
                    if (!first) w.writeByte(',') catch {};
                    first = false;
                    w.writeAll("{\"instance\":") catch {};
                    jsonStr(w, names[i]);
                    w.writeAll(",\"pin\":") catch {};
                    jsonStr(w, pin.name);
                    w.writeAll(",\"reason\":\"no_connections\"}") catch {};
                }
            }
            continue;
        }

        // Check each connection
        for (sch.conns.items[conn_start..][0..conn_count]) |conn| {
            if (std.mem.eql(u8, conn.net, "?") or conn.net.len == 0) {
                if (!first) w.writeByte(',') catch {};
                first = false;
                w.writeAll("{\"instance\":") catch {};
                jsonStr(w, names[i]);
                w.writeAll(",\"pin\":") catch {};
                jsonStr(w, conn.pin);
                w.writeAll(",\"reason\":\"unrouted\"}") catch {};
            }
        }
    }

    w.writeAll("]}") catch {};
    return buf.items;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 3. floating_nets() -> [{net_name, single_connection}]
// ═══════════════════════════════════════════════════════════════════════════════

/// Find nets with only one connection (dangling/floating).
pub fn floatingNets(a: Allocator, sch: *const Schemify) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);

    // Count connections per net
    var net_conn_counts = a.alloc(u32, sch.nets.items.len) catch {
        w.writeAll("{\"floating_nets\":[],\"error\":\"allocation failed\"}") catch {};
        return buf.items;
    };
    defer a.free(net_conn_counts);
    @memset(net_conn_counts, 0);

    // Count unique instance pin connections per net (not wire endpoints)
    const all_cs = sch.instances.items(.conn_start);
    const all_cc = sch.instances.items(.conn_count);
    const all_kinds = sch.instances.items(.kind);

    for (0..sch.instances.len) |i| {
        if (all_kinds[i].isNonElectrical()) continue;
        const conn_start: usize = all_cs[i];
        const conn_count: usize = all_cc[i];
        for (sch.conns.items[conn_start..][0..conn_count]) |conn| {
            if (std.mem.eql(u8, conn.net, "?") or conn.net.len == 0) continue;
            // Find net index
            for (sch.nets.items, 0..) |net, ni| {
                if (std.mem.eql(u8, net.name, conn.net)) {
                    net_conn_counts[ni] += 1;
                    break;
                }
            }
        }
    }

    // Report nets with only 1 connection
    w.writeAll("{\"floating_nets\":[") catch return "{}";
    var first = true;
    for (sch.nets.items, 0..) |net, ni| {
        if (net_conn_counts[ni] == 1) {
            if (!first) w.writeByte(',') catch {};
            first = false;
            w.writeAll("{\"net_name\":") catch {};
            jsonStr(w, net.name);

            // Find the single connection
            w.writeAll(",\"single_connection\":") catch {};
            var found = false;
            for (0..sch.instances.len) |i| {
                if (found) break;
                if (all_kinds[i].isNonElectrical()) continue;
                const conn_start: usize = all_cs[i];
                const conn_count: usize = all_cc[i];
                const names = sch.instances.items(.name);
                for (sch.conns.items[conn_start..][0..conn_count]) |conn| {
                    if (std.mem.eql(u8, conn.net, net.name)) {
                        w.writeAll("{\"instance\":") catch {};
                        jsonStr(w, names[i]);
                        w.writeAll(",\"pin\":") catch {};
                        jsonStr(w, conn.pin);
                        w.writeByte('}') catch {};
                        found = true;
                        break;
                    }
                }
            }
            if (!found) w.writeAll("null") catch {};
            w.writeByte('}') catch {};
        }
    }
    w.writeAll("]}") catch {};
    return buf.items;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 4. drc_check() -> [{type, message, severity, location}]
// ═══════════════════════════════════════════════════════════════════════════════

const Severity = enum { err, warning, info };
const DrcViolation = struct {
    vtype: []const u8,
    message: []const u8,
    severity: Severity,
    instance: ?[]const u8 = null,
    x: ?i32 = null,
    y: ?i32 = null,
};

/// Run design rule checks on the schematic.
pub fn drcCheck(a: Allocator, sch: *const Schemify) []const u8 {
    var violations = std.ArrayList(DrcViolation){};
    defer violations.deinit(a);

    checkMinWL(a, sch, &violations);
    checkUnconnectedPins(a, sch, &violations);
    checkShortCircuits(a, sch, &violations);
    checkMissingBodyConnections(a, sch, &violations);
    checkFloatingGates(a, sch, &violations);

    // Build JSON output
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"violations\":[") catch return "{}";

    for (violations.items, 0..) |v, i| {
        if (i > 0) w.writeByte(',') catch {};
        w.writeAll("{\"type\":") catch {};
        jsonStr(w, v.vtype);
        w.writeAll(",\"message\":") catch {};
        jsonStr(w, v.message);
        w.writeAll(",\"severity\":") catch {};
        jsonStr(w, @tagName(v.severity));
        if (v.instance) |inst| {
            w.writeAll(",\"instance\":") catch {};
            jsonStr(w, inst);
        }
        if (v.x) |x| {
            w.writeAll(",\"location\":{\"x\":") catch {};
            jsonInt(w, x);
            if (v.y) |y| {
                w.writeAll(",\"y\":") catch {};
                jsonInt(w, y);
            }
            w.writeByte('}') catch {};
        }
        w.writeByte('}') catch {};
    }

    w.writeAll("],\"total\":") catch {};
    jsonInt(w, @intCast(violations.items.len));

    // Count by severity
    var errors: u32 = 0;
    var warnings: u32 = 0;
    var infos: u32 = 0;
    for (violations.items) |v| {
        switch (v.severity) {
            .err => errors += 1,
            .warning => warnings += 1,
            .info => infos += 1,
        }
    }
    std.fmt.format(w, ",\"errors\":{d},\"warnings\":{d},\"info\":{d}", .{ errors, warnings, infos }) catch {};
    w.writeByte('}') catch {};
    return buf.items;
}

/// Check MOSFETs for minimum W/L values.
fn checkMinWL(a: Allocator, sch: *const Schemify, violations: *std.ArrayList(DrcViolation)) void {
    const names = sch.instances.items(.name);
    const kinds = sch.instances.items(.kind);
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const ps = sch.instances.items(.prop_start);
    const pc = sch.instances.items(.prop_count);

    for (0..sch.instances.len) |i| {
        const kind = kinds[i];
        const is_mosfet = switch (kind) {
            .nmos3, .pmos3, .nmos4, .pmos4, .nmos4_depl, .nmos_sub, .pmos_sub, .nmoshv4, .pmoshv4, .rnmos4 => true,
            else => false,
        };
        if (!is_mosfet) continue;

        const prop_start: usize = ps[i];
        const prop_count: usize = pc[i];
        const inst_props = sch.props.items[prop_start..][0..prop_count];

        var has_w = false;
        var has_l = false;
        for (inst_props) |p| {
            if (std.mem.eql(u8, p.key, "W")) has_w = true;
            if (std.mem.eql(u8, p.key, "L")) has_l = true;
        }

        if (!has_w) {
            const msg = std.fmt.allocPrint(a, "MOSFET {s} has no W (width) parameter", .{names[i]}) catch "MOSFET missing W";
            violations.append(a, .{
                .vtype = "missing_width",
                .message = msg,
                .severity = .warning,
                .instance = names[i],
                .x = xs[i],
                .y = ys[i],
            }) catch {};
        }
        if (!has_l) {
            const msg = std.fmt.allocPrint(a, "MOSFET {s} has no L (length) parameter", .{names[i]}) catch "MOSFET missing L";
            violations.append(a, .{
                .vtype = "missing_length",
                .message = msg,
                .severity = .warning,
                .instance = names[i],
                .x = xs[i],
                .y = ys[i],
            }) catch {};
        }
    }
}

/// Check for unconnected pins (net == "?").
fn checkUnconnectedPins(a: Allocator, sch: *const Schemify, violations: *std.ArrayList(DrcViolation)) void {
    const names = sch.instances.items(.name);
    const kinds = sch.instances.items(.kind);
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const cs = sch.instances.items(.conn_start);
    const cc = sch.instances.items(.conn_count);

    for (0..sch.instances.len) |i| {
        if (kinds[i].isNonElectrical()) continue;
        if (kinds[i].isPower()) continue;

        const conn_start: usize = cs[i];
        const conn_count: usize = cc[i];

        for (sch.conns.items[conn_start..][0..conn_count]) |conn| {
            if (std.mem.eql(u8, conn.net, "?") or conn.net.len == 0) {
                const msg = std.fmt.allocPrint(a, "Pin '{s}' on {s} is unconnected", .{ conn.pin, names[i] }) catch "Unconnected pin";
                violations.append(a, .{
                    .vtype = "unconnected_pin",
                    .message = msg,
                    .severity = .err,
                    .instance = names[i],
                    .x = xs[i],
                    .y = ys[i],
                }) catch {};
            }
        }
    }
}

/// Detect short circuits: multiple power symbols (vdd/gnd with different
/// injected net names) connected to the same net.
fn checkShortCircuits(a: Allocator, sch: *const Schemify, violations: *std.ArrayList(DrcViolation)) void {
    // Build map: net_name -> list of power kinds connected
    const names = sch.instances.items(.name);
    const kinds = sch.instances.items(.kind);
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const cs = sch.instances.items(.conn_start);
    const cc = sch.instances.items(.conn_count);

    // Track nets that have power connections
    const PowerConn = struct {
        kind: DeviceKind,
        instance: []const u8,
    };

    var net_power = std.StringHashMapUnmanaged(std.ArrayList(PowerConn)){};
    defer {
        var it = net_power.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(a);
        }
        net_power.deinit(a);
    }

    for (0..sch.instances.len) |i| {
        if (!kinds[i].isPower()) continue;
        const conn_start: usize = cs[i];
        const conn_count: usize = cc[i];

        for (sch.conns.items[conn_start..][0..conn_count]) |conn| {
            if (std.mem.eql(u8, conn.net, "?") or conn.net.len == 0) continue;
            const gop = net_power.getOrPut(a, conn.net) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(PowerConn){};
            gop.value_ptr.append(a, .{ .kind = kinds[i], .instance = names[i] }) catch {};
        }
    }

    // Check for conflicts: a net with both vdd and gnd
    var it = net_power.iterator();
    while (it.next()) |entry| {
        const pconns = entry.value_ptr.items;
        if (pconns.len < 2) continue;

        var has_vdd = false;
        var has_gnd = false;
        for (pconns) |pc| {
            if (pc.kind == .vdd) has_vdd = true;
            if (pc.kind == .gnd) has_gnd = true;
        }

        if (has_vdd and has_gnd) {
            const msg = std.fmt.allocPrint(a, "Short circuit: net '{s}' has both VDD and GND connections", .{entry.key_ptr.*}) catch "Short circuit detected";
            violations.append(a, .{
                .vtype = "short_circuit",
                .message = msg,
                .severity = .err,
                .instance = pconns[0].instance,
                .x = xs[0],
                .y = ys[0],
            }) catch {};
        }
    }
}

/// Check 4-terminal MOSFETs for missing body/substrate connections.
fn checkMissingBodyConnections(a: Allocator, sch: *const Schemify, violations: *std.ArrayList(DrcViolation)) void {
    const names = sch.instances.items(.name);
    const kinds = sch.instances.items(.kind);
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const cs = sch.instances.items(.conn_start);
    const cc = sch.instances.items(.conn_count);

    for (0..sch.instances.len) |i| {
        const kind = kinds[i];
        const is_4t = switch (kind) {
            .nmos4, .pmos4, .nmos4_depl, .nmoshv4, .pmoshv4, .rnmos4 => true,
            else => false,
        };
        if (!is_4t) continue;

        const conn_start: usize = cs[i];
        const conn_count: usize = cc[i];

        // Look for body/bulk pin
        var has_body = false;
        for (sch.conns.items[conn_start..][0..conn_count]) |conn| {
            if (std.mem.eql(u8, conn.pin, "b") or
                std.mem.eql(u8, conn.pin, "bulk") or
                std.mem.eql(u8, conn.pin, "body") or
                std.mem.eql(u8, conn.pin, "sub"))
            {
                if (!std.mem.eql(u8, conn.net, "?") and conn.net.len > 0) {
                    has_body = true;
                }
                break;
            }
        }

        if (!has_body and conn_count > 0) {
            // Check if the body pin exists but is unconnected
            var body_exists = false;
            for (sch.conns.items[conn_start..][0..conn_count]) |conn| {
                if (std.mem.eql(u8, conn.pin, "b") or
                    std.mem.eql(u8, conn.pin, "bulk") or
                    std.mem.eql(u8, conn.pin, "body") or
                    std.mem.eql(u8, conn.pin, "sub"))
                {
                    body_exists = true;
                    break;
                }
            }

            if (body_exists) {
                const msg = std.fmt.allocPrint(a, "MOSFET {s} body/substrate pin is unconnected", .{names[i]}) catch "Missing body connection";
                violations.append(a, .{
                    .vtype = "missing_body_connection",
                    .message = msg,
                    .severity = .warning,
                    .instance = names[i],
                    .x = xs[i],
                    .y = ys[i],
                }) catch {};
            }
        }
    }
}

/// Check for floating gates (MOSFET gate pin connected to a net with no driver).
fn checkFloatingGates(a: Allocator, sch: *const Schemify, violations: *std.ArrayList(DrcViolation)) void {
    const names = sch.instances.items(.name);
    const kinds = sch.instances.items(.kind);
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const cs = sch.instances.items(.conn_start);
    const cc = sch.instances.items(.conn_count);

    // Build a set of nets that are driven (connected to a source, drain, or
    // non-gate pin of some device, or to a voltage source)
    var driven_nets = std.StringHashMapUnmanaged(void){};
    defer driven_nets.deinit(a);

    for (0..sch.instances.len) |i| {
        if (kinds[i].isNonElectrical()) continue;
        const conn_start: usize = cs[i];
        const conn_count: usize = cc[i];

        for (sch.conns.items[conn_start..][0..conn_count]) |conn| {
            if (std.mem.eql(u8, conn.net, "?") or conn.net.len == 0) continue;

            const is_driver = switch (kinds[i]) {
                // Voltage/current sources always drive
                .vsource, .isource, .sqwsource, .behavioral, .vcvs, .vccs, .ccvs, .cccs => true,
                // Power symbols drive
                .vdd, .gnd => true,
                // For MOSFETs, drain and source pins are driven/drivers
                .nmos3, .pmos3, .nmos4, .pmos4, .nmos4_depl, .nmos_sub, .pmos_sub, .nmoshv4, .pmoshv4, .rnmos4 => !std.mem.eql(u8, conn.pin, "g") and !std.mem.eql(u8, conn.pin, "gate"),
                // BJTs: collector and emitter drive
                .npn, .pnp => !std.mem.eql(u8, conn.pin, "b") and !std.mem.eql(u8, conn.pin, "base"),
                // Passives always connect through
                .resistor, .resistor3, .var_resistor, .capacitor, .inductor => true,
                // Labels/pins drive
                .lab_pin, .input_pin, .output_pin, .inout_pin => true,
                else => true,
            };

            if (is_driver) {
                driven_nets.put(a, conn.net, {}) catch {};
            }
        }
    }

    // Now check MOSFET gate pins
    for (0..sch.instances.len) |i| {
        const kind = kinds[i];
        const is_mosfet = switch (kind) {
            .nmos3, .pmos3, .nmos4, .pmos4, .nmos4_depl, .nmos_sub, .pmos_sub, .nmoshv4, .pmoshv4, .rnmos4 => true,
            else => false,
        };
        if (!is_mosfet) continue;

        const conn_start: usize = cs[i];
        const conn_count: usize = cc[i];

        for (sch.conns.items[conn_start..][0..conn_count]) |conn| {
            if (!std.mem.eql(u8, conn.pin, "g") and !std.mem.eql(u8, conn.pin, "gate")) continue;
            if (std.mem.eql(u8, conn.net, "?") or conn.net.len == 0) continue;

            if (!driven_nets.contains(conn.net)) {
                const msg = std.fmt.allocPrint(a, "MOSFET {s} has floating gate (net '{s}' has no driver)", .{ names[i], conn.net }) catch "Floating gate";
                violations.append(a, .{
                    .vtype = "floating_gate",
                    .message = msg,
                    .severity = .err,
                    .instance = names[i],
                    .x = xs[i],
                    .y = ys[i],
                }) catch {};
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 5. netlist() -> SPICE text
// ═══════════════════════════════════════════════════════════════════════════════

/// Generate a SPICE netlist from the schematic.
/// The schematic must have had resolveNets() called.
pub fn netlist(a: Allocator, sch: *const Schemify) []const u8 {
    // Use the Netlist module directly to avoid anytype forwarding issues
    const NetlistMod = @import("simulation").Netlist;
    const result = NetlistMod.emitSpice(sch, a, null) catch |err| {
        var buf: std.ArrayList(u8) = .{};
        const w = buf.writer(a);
        w.writeAll("* Schemify SPICE netlist generation failed: ") catch {};
        std.fmt.format(w, "{}", .{err}) catch {};
        w.writeAll("\n.end\n") catch {};
        return buf.items;
    };
    return result;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 6. validate_circuit() -> {valid, errors}
// ═══════════════════════════════════════════════════════════════════════════════

/// Run all validation checks and return a structured result.
pub fn validateCircuit(a: Allocator, sch: *const Schemify) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);

    var all_errors = std.ArrayList(ValidationError){};
    defer all_errors.deinit(a);

    // Check 1: empty schematic
    if (sch.instances.len == 0 and sch.wires.len == 0) {
        all_errors.append(a, .{
            .etype = "empty_schematic",
            .message = "Schematic is empty (no instances or wires)",
        }) catch {};
    }

    // Check 2: instances with no symbol
    {
        const names = sch.instances.items(.name);
        const symbols = sch.instances.items(.symbol);
        for (0..sch.instances.len) |i| {
            if (symbols[i].len == 0) {
                const msg = std.fmt.allocPrint(a, "Instance '{s}' has no symbol assigned", .{names[i]}) catch "Missing symbol";
                all_errors.append(a, .{
                    .etype = "missing_symbol",
                    .message = msg,
                }) catch {};
            }
        }
    }

    // Check 3: duplicate instance names
    {
        const names = sch.instances.items(.name);
        for (0..sch.instances.len) |i| {
            if (names[i].len == 0) continue;
            for (i + 1..sch.instances.len) |j| {
                if (std.mem.eql(u8, names[i], names[j])) {
                    const msg = std.fmt.allocPrint(a, "Duplicate instance name: '{s}'", .{names[i]}) catch "Duplicate name";
                    all_errors.append(a, .{
                        .etype = "duplicate_instance_name",
                        .message = msg,
                    }) catch {};
                    break; // Only report once per name
                }
            }
        }
    }

    // Check 4: zero-length wires
    {
        const wx0 = sch.wires.items(.x0);
        const wy0 = sch.wires.items(.y0);
        const wx1 = sch.wires.items(.x1);
        const wy1 = sch.wires.items(.y1);

        for (0..sch.wires.len) |i| {
            if (wx0[i] == wx1[i] and wy0[i] == wy1[i]) {
                const msg = std.fmt.allocPrint(a, "Zero-length wire at ({d}, {d})", .{ wx0[i], wy0[i] }) catch "Zero-length wire";
                all_errors.append(a, .{
                    .etype = "zero_length_wire",
                    .message = msg,
                }) catch {};
            }
        }
    }

    // Check 5: Run DRC and extract errors
    {
        const drc_json = drcCheck(a, sch);
        // Parse DRC results to count errors
        const parsed = std.json.parseFromSlice(std.json.Value, a, drc_json, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("violations")) |viol_val| {
                if (viol_val == .array) {
                    for (viol_val.array.items) |v| {
                        if (v != .object) continue;
                        const sev = if (v.object.get("severity")) |sv|
                            (if (sv == .string) sv.string else "err")
                        else
                            "err";
                        const msg_val = if (v.object.get("message")) |mv|
                            (if (mv == .string) mv.string else "DRC violation")
                        else
                            "DRC violation";
                        const type_val = if (v.object.get("type")) |tv|
                            (if (tv == .string) tv.string else "drc")
                        else
                            "drc";

                        if (std.mem.eql(u8, sev, "err")) {
                            all_errors.append(a, .{
                                .etype = type_val,
                                .message = msg_val,
                            }) catch {};
                        }
                    }
                }
            }
        }
    }

    // Check 6: unrouted pins
    {
        const unrouted = unroutedPins(a, sch);
        const parsed = std.json.parseFromSlice(std.json.Value, a, unrouted, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("unrouted_pins")) |up| {
                if (up == .array and up.array.items.len > 0) {
                    const msg = std.fmt.allocPrint(a, "{d} unrouted pin(s) found", .{up.array.items.len}) catch "Unrouted pins";
                    all_errors.append(a, .{
                        .etype = "unrouted_pins",
                        .message = msg,
                    }) catch {};
                }
            }
        }
    }

    // Build final JSON
    const valid = all_errors.items.len == 0;
    w.writeAll("{\"valid\":") catch return "{}";
    jsonBool(w, valid);
    w.writeAll(",\"errors\":[") catch {};
    for (all_errors.items, 0..) |err, i| {
        if (i > 0) w.writeByte(',') catch {};
        w.writeAll("{\"type\":") catch {};
        jsonStr(w, err.etype);
        w.writeAll(",\"message\":") catch {};
        jsonStr(w, err.message);
        w.writeByte('}') catch {};
    }
    w.writeAll("],\"instance_count\":") catch {};
    jsonInt(w, @intCast(sch.instances.len));
    w.writeAll(",\"wire_count\":") catch {};
    jsonInt(w, @intCast(sch.wires.len));
    w.writeAll(",\"net_count\":") catch {};
    jsonInt(w, @intCast(sch.nets.items.len));
    w.writeByte('}') catch {};
    return buf.items;
}

const ValidationError = struct {
    etype: []const u8,
    message: []const u8,
};

// ═══════════════════════════════════════════════════════════════════════════════
// Opaque-pointer wrappers (called from tools.zig)
// ═══════════════════════════════════════════════════════════════════════════════

/// Extract a JSON array field from a JSON object string and write it to a writer.
/// Falls back to "[]" on any parse or field-missing error.
pub fn extractJsonArrayField(w: anytype, a: Allocator, json_str: []const u8, field_name: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_str, .{}) catch {
        w.writeAll("[]") catch {};
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        w.writeAll("[]") catch {};
        return;
    }
    const arr_val = parsed.value.object.get(field_name) orelse {
        w.writeAll("[]") catch {};
        return;
    };
    if (arr_val != .array) {
        w.writeAll("[]") catch {};
        return;
    }
    // Re-serialize the array by manually writing its JSON
    const items = arr_val.array.items;
    w.writeByte('[') catch {};
    for (items, 0..) |item, i| {
        if (i > 0) w.writeByte(',') catch {};
        writeJsonValue(w, item);
    }
    w.writeByte(']') catch {};
}

/// Manually write a std.json.Value to a writer.
fn writeJsonValue(w: anytype, val: std.json.Value) void {
    switch (val) {
        .null => w.writeAll("null") catch {},
        .bool => |b| w.writeAll(if (b) "true" else "false") catch {},
        .integer => |v| std.fmt.format(w, "{d}", .{v}) catch {},
        .float => |v| std.fmt.format(w, "{d}", .{v}) catch {},
        .number_string => |s| w.writeAll(s) catch {},
        .string => |s| mcp.writeJsonStr(w, s) catch {},
        .array => |arr| {
            w.writeByte('[') catch {};
            for (arr.items, 0..) |item, i| {
                if (i > 0) w.writeByte(',') catch {};
                writeJsonValue(w, item);
            }
            w.writeByte(']') catch {};
        },
        .object => |obj| {
            w.writeByte('{') catch {};
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) w.writeByte(',') catch {};
                first = false;
                mcp.writeJsonStr(w, entry.key_ptr.*) catch {};
                w.writeByte(':') catch {};
                writeJsonValue(w, entry.value_ptr.*);
            }
            w.writeByte('}') catch {};
        },
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "empty schematic validates with warning" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sch = Schemify{};
    defer sch.deinit(a);

    const result = validateCircuit(arena, &sch);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"valid\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "empty_schematic") != null);
}

test "unrouted pins on instance with no connections" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sch = Schemify{};
    defer sch.deinit(a);

    // Add a resistor with sym_data pins but no conns
    _ = try sch.addComponent(a, .{
        .name = "R1",
        .symbol = "resistor",
        .kind = .resistor,
        .x = 0,
        .y = 0,
        .sym_data = .{
            .pins = &.{
                .{ .name = "p", .x = 0, .y = -20 },
                .{ .name = "n", .x = 0, .y = 20 },
            },
        },
    });

    const result = unroutedPins(arena, &sch);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"unrouted_pins\"") != null);
    // R1 has no conns at all but has sym_data pins -> unrouted
    try std.testing.expect(std.mem.indexOf(u8, result, "R1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "no_connections") != null);
}

test "floating nets detects single-connection nets" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sch = Schemify{};
    defer sch.deinit(a);

    // One resistor with one pin on "dangling_net", two pins total
    _ = try sch.addComponent(a, .{
        .name = "R1",
        .symbol = "resistor",
        .kind = .resistor,
        .x = 0,
        .y = 0,
        .conns = &.{
            .{ .pin = "p", .net = "dangling_net" },
            .{ .pin = "n", .net = "gnd" },
        },
        .sym_data = .{
            .pins = &.{
                .{ .name = "p", .x = 0, .y = -20 },
                .{ .name = "n", .x = 0, .y = 20 },
            },
        },
    });

    // Need to add nets manually since we're not using resolveNets
    try sch.nets.append(a, .{ .name = try a.dupe(u8, "dangling_net") });
    try sch.nets.append(a, .{ .name = try a.dupe(u8, "gnd") });

    const result = floatingNets(arena, &sch);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"floating_nets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "dangling_net") != null);
}

test "DRC detects missing W/L on MOSFET" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sch = Schemify{};
    defer sch.deinit(a);

    // Add NMOS without W or L properties
    _ = try sch.addComponent(a, .{
        .name = "M1",
        .symbol = "nmos4",
        .kind = .nmos4,
        .x = 0,
        .y = 0,
        .conns = &.{
            .{ .pin = "d", .net = "out" },
            .{ .pin = "g", .net = "in" },
            .{ .pin = "s", .net = "gnd" },
            .{ .pin = "b", .net = "gnd" },
        },
    });

    const result = drcCheck(arena, &sch);
    try std.testing.expect(std.mem.indexOf(u8, result, "missing_width") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "missing_length") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "M1") != null);
}

test "DRC passes for MOSFET with W and L" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sch = Schemify{};
    defer sch.deinit(a);

    _ = try sch.addComponent(a, .{
        .name = "M1",
        .symbol = "nmos4",
        .kind = .nmos4,
        .x = 0,
        .y = 0,
        .props = &.{
            .{ .key = "W", .val = "1u" },
            .{ .key = "L", .val = "180n" },
        },
        .conns = &.{
            .{ .pin = "d", .net = "out" },
            .{ .pin = "g", .net = "in" },
            .{ .pin = "s", .net = "gnd" },
            .{ .pin = "b", .net = "gnd" },
        },
    });

    const result = drcCheck(arena, &sch);
    // Should not report missing_width or missing_length for M1
    try std.testing.expect(std.mem.indexOf(u8, result, "missing_width") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "missing_length") == null);
}

test "validate_circuit reports duplicate names" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sch = Schemify{};
    defer sch.deinit(a);

    _ = try sch.addInstance(a, "R1", "resistor", 0, 0);
    _ = try sch.addInstance(a, "R1", "resistor", 100, 0);

    const result = validateCircuit(arena, &sch);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"valid\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "duplicate_instance_name") != null);
}

test "validate_circuit passes for valid simple schematic" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sch = Schemify{};
    defer sch.deinit(a);

    _ = try sch.addComponent(a, .{
        .name = "R1",
        .symbol = "resistor",
        .kind = .resistor,
        .x = 0,
        .y = 0,
        .props = &.{
            .{ .key = "value", .val = "1k" },
        },
        .conns = &.{
            .{ .pin = "p", .net = "vdd" },
            .{ .pin = "n", .net = "out" },
        },
    });

    _ = try sch.addComponent(a, .{
        .name = "R2",
        .symbol = "resistor",
        .kind = .resistor,
        .x = 100,
        .y = 0,
        .props = &.{
            .{ .key = "value", .val = "2k" },
        },
        .conns = &.{
            .{ .pin = "p", .net = "out" },
            .{ .pin = "n", .net = "gnd" },
        },
    });

    // Add a wire to make it non-empty
    _ = try sch.addWire(a, 0, 0, 100, 0);

    // Add nets so floating_nets doesn't flag
    try sch.nets.append(a, .{ .name = try a.dupe(u8, "vdd") });
    try sch.nets.append(a, .{ .name = try a.dupe(u8, "out") });
    try sch.nets.append(a, .{ .name = try a.dupe(u8, "gnd") });

    const result = validateCircuit(arena, &sch);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"valid\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"instance_count\":2") != null);
}

test "zero-length wire detected" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sch = Schemify{};
    defer sch.deinit(a);

    _ = try sch.addWire(a, 50, 50, 50, 50);

    const result = validateCircuit(arena, &sch);
    try std.testing.expect(std.mem.indexOf(u8, result, "zero_length_wire") != null);
}

test "DRC detects unconnected pin" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sch = Schemify{};
    defer sch.deinit(a);

    // Resistor with one pin connected, one unconnected ("?")
    _ = try sch.addComponent(a, .{
        .name = "R1",
        .symbol = "resistor",
        .kind = .resistor,
        .x = 0,
        .y = 0,
        .conns = &.{
            .{ .pin = "p", .net = "vdd" },
            .{ .pin = "n", .net = "?" },
        },
    });

    const result = drcCheck(arena, &sch);
    try std.testing.expect(std.mem.indexOf(u8, result, "unconnected_pin") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "R1") != null);
}

test "netlist generation on empty schematic" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sch = Schemify{};
    defer sch.deinit(a);

    const result = netlist(arena, &sch);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, ".end") != null);
}
