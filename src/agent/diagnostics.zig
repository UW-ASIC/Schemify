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
const SymData = types.SymData;

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

/// Find pins that have no net connection.
/// TODO: Restore when Connectivity struct is integrated — conn_start/conn_count/conns removed from Schemify.
pub fn unroutedPins(a: Allocator, sch: *const Schemify) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"unrouted_pins\":[") catch return "{}";

    const names = sch.instances.items(.name);
    const kinds = sch.instances.items(.kind);

    var first = true;
    for (0..sch.instances.len) |i| {
        if (kinds[i].isNonElectrical()) continue;
        if (kinds[i].isPower()) continue;

        // Without connectivity data, check if instance has sym_data pins but
        // we can't verify net connections. Report instances with pins as potentially unrouted.
        if (i < sch.sym_data.items.len and sch.sym_data.items[i].pins.len > 0) {
            for (sch.sym_data.items[i].pins) |pin| {
                if (!first) w.writeByte(',') catch {};
                first = false;
                w.writeAll("{\"instance\":") catch {};
                jsonStr(w, sch.str(names[i]));
                w.writeAll(",\"pin\":") catch {};
                jsonStr(w, sch.str(pin.name));
                w.writeAll(",\"reason\":\"no_connections\"}") catch {};
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
/// TODO: Restore when Connectivity struct is integrated — nets/conns removed from Schemify.
pub fn floatingNets(a: Allocator, sch: *const Schemify) []const u8 {
    _ = sch;
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"floating_nets\":[],\"note\":\"Connectivity data not yet available\"}") catch return "{}";
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
    // TODO: Restore connectivity-dependent checks when Connectivity struct is integrated
    // checkUnconnectedPins(a, sch, &violations);
    // checkShortCircuits(a, sch, &violations);
    // checkMissingBodyConnections(a, sch, &violations);
    // checkFloatingGates(a, sch, &violations);

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
            if (std.mem.eql(u8, sch.str(p.key), "W")) has_w = true;
            if (std.mem.eql(u8, sch.str(p.key), "L")) has_l = true;
        }

        const inst_name = sch.str(names[i]);
        if (!has_w) {
            const msg = std.fmt.allocPrint(a, "MOSFET {s} has no W (width) parameter", .{inst_name}) catch "MOSFET missing W";
            violations.append(a, .{
                .vtype = "missing_width",
                .message = msg,
                .severity = .warning,
                .instance = inst_name,
                .x = xs[i],
                .y = ys[i],
            }) catch {};
        }
        if (!has_l) {
            const msg = std.fmt.allocPrint(a, "MOSFET {s} has no L (length) parameter", .{inst_name}) catch "MOSFET missing L";
            violations.append(a, .{
                .vtype = "missing_length",
                .message = msg,
                .severity = .warning,
                .instance = inst_name,
                .x = xs[i],
                .y = ys[i],
            }) catch {};
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
            if (sch.str(symbols[i]).len == 0) {
                const msg = std.fmt.allocPrint(a, "Instance '{s}' has no symbol assigned", .{sch.str(names[i])}) catch "Missing symbol";
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
            if (sch.str(names[i]).len == 0) continue;
            for (i + 1..sch.instances.len) |j| {
                if (std.mem.eql(u8, sch.str(names[i]), sch.str(names[j]))) {
                    const msg = std.fmt.allocPrint(a, "Duplicate instance name: '{s}'", .{sch.str(names[i])}) catch "Duplicate name";
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
    w.writeAll(",\"net_count\":0}") catch {};
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
                .{ .name = .empty, .x = 0, .y = -20 },
                .{ .name = .empty, .x = 0, .y = 20 },
            },
        },
    });

    const result = unroutedPins(arena, &sch);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"unrouted_pins\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "R1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "no_connections") != null);
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

    _ = try sch.addComponent(a, .{ .name = "R1", .symbol = "resistor", .x = 0, .y = 0 });
    _ = try sch.addComponent(a, .{ .name = "R1", .symbol = "resistor", .x = 100, .y = 0 });

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
    });

    // Add a wire to make it non-empty
    _ = try sch.addWire(a, 0, 0, 100, 0);

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
