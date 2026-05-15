//! Reader.zig — CHN format parser
//!
//! Parses .chn, .chn_prim, and .chn_tb files into a Schemify struct.
//! Uses a state machine driven by indent level:
//!   indent 0 → top-level block (SYMBOL, SCHEMATIC, TESTBENCH)
//!   indent 1 → sub-section header or metadata key-value
//!   indent 2+ → section content data

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const types = @import("../types.zig");
const Property = types.Property;
const DeviceKind = types.DeviceKind;
const PinDir = types.PinDir;
const SchematicType = types.SchematicType;

// ─────────────────────────────────────────────────────────────────────────────
// Section state machine
// ─────────────────────────────────────────────────────────────────────────────

const TopLevel = enum { symbol, schematic, testbench };

const Section = enum(u8) {
    none,
    pins,
    params,
    instances,
    type_table,
    nets,
    wires,
    drawing,
    includes,
    analyses,
    measures,
    code_block,
    annotations,
    generate,
    plugin,
    plugin_multiline,
};

const section_map = std.StaticStringMap(Section).initComptime(.{
    .{ "pins", .pins },
    .{ "params", .params },
    .{ "instances", .instances },
    .{ "nets", .nets },
    .{ "wires", .wires },
    .{ "drawing", .drawing },
    .{ "includes", .includes },
    .{ "analyses", .analyses },
    .{ "measures", .measures },
    .{ "code_block", .code_block },
    .{ "annotations", .annotations },
});

// ─────────────────────────────────────────────────────────────────────────────
// Tagged connection for deferred net repacking
// ─────────────────────────────────────────────────────────────────────────────

const TaggedConn = struct {
    inst_idx: u32,
    pin: []const u8,
    net: []const u8,
};

// ─────────────────────────────────────────────────────────────────────────────
// Type-table state
// ─────────────────────────────────────────────────────────────────────────────

const TypeTableState = struct {
    type_name: []const u8 = "",
    kind: DeviceKind = .unknown,
    cols: ?[]const []const u8 = null,
    remaining: u32 = 0,
};

// ─────────────────────────────────────────────────────────────────────────────
// Generate block state
// ─────────────────────────────────────────────────────────────────────────────

const GenState = struct {
    var_: []const u8 = "",
    start: i32 = 0,
    end: i32 = 0,
    lines: List([]const u8) = .{},
};

// ─────────────────────────────────────────────────────────────────────────────
// Plugin multi-line value accumulator
// ─────────────────────────────────────────────────────────────────────────────

const PluginMLState = struct {
    key: []const u8 = "",
    lines: List([]const u8) = .{},
};

// ─────────────────────────────────────────────────────────────────────────────
// Schemify model — forward-declared interface
// ─────────────────────────────────────────────────────────────────────────────

// NOTE: The Reader writes directly into the Schemify struct's MultiArrayLists
// and ArrayListUnmanaged fields.  The Schemify struct is imported from the
// core module root.  For now we define a minimal interface here.

const Schemify = @import("../lib.zig").Schemify;

// ═════════════════════════════════════════════════════════════════════════════
// PUBLIC API
// ═════════════════════════════════════════════════════════════════════════════

pub fn readCHN(data: []const u8, alloc: Allocator) Schemify {
    var s: Schemify = .{};
    parse(&s, data, alloc);
    collapseBusPins(&s, alloc);
    synthesizePortInstances(&s, alloc);
    return s;
}

// ═════════════════════════════════════════════════════════════════════════════
// MAIN PARSER
// ═════════════════════════════════════════════════════════════════════════════

fn parse(s: *Schemify, input: []const u8, a: Allocator) void {
    var it = std.mem.splitScalar(u8, input, '\n');
    var tagged: List(TaggedConn) = .{};
    defer tagged.deinit(a);

    var top: TopLevel = .schematic;
    var section: Section = .none;

    var tt_state: TypeTableState = .{};
    var gen_state: GenState = .{};
    var plugin_ml: PluginMLState = .{};

    // Parse header line
    const hdr_raw = it.next() orelse return;
    const hdr = std.mem.trim(u8, hdr_raw, " \t\r");
    s.stype = parseHeader(hdr);

    while (it.next()) |raw| {
        const full = std.mem.trimRight(u8, raw, " \t\r");
        if (full.len == 0) continue;
        const line = stripComment(full);
        if (line.len == 0) continue;

        const indent = indentLevel(line);
        const trimmed = std.mem.trimLeft(u8, line, " ");

        // ── indent 0: top-level block ──
        if (indent == 0) {
            flushPluginML(a, s, &plugin_ml);
            top = topLevelFromLine(trimmed) orelse top;
            section = .none;
            if (std.mem.startsWith(u8, trimmed, "SYMBOL ")) {
                if (s.name.len > 0) a.free(@constCast(s.name));
                s.name = dupe(a, std.mem.trim(u8, trimmed["SYMBOL ".len..], " \t"));
            } else if (std.mem.startsWith(u8, trimmed, "TESTBENCH ")) {
                if (s.name.len > 0) a.free(@constCast(s.name));
                s.name = dupe(a, std.mem.trim(u8, trimmed["TESTBENCH ".len..], " \t"));
            } else if (std.mem.startsWith(u8, trimmed, "PLUGIN ")) {
                const pname = std.mem.trim(u8, trimmed["PLUGIN ".len..], " \t");
                s.plugin_blocks.append(a, .{
                    .name = dupe(a, pname),
                }) catch {};
                section = .plugin;
            }
            continue;
        }

        // ── indent 1: sub-section header or metadata ──
        if (indent == 1) {
            if (section == .plugin or section == .plugin_multiline) {
                flushPluginML(a, s, &plugin_ml);
                readPluginEntry(a, s, trimmed, &plugin_ml, &section);
                continue;
            }
            section = resolveSubSection(trimmed, s, a, &gen_state) orelse .none;
            if (section == .type_table) {
                parseTypeTableHeader(a, trimmed, &tt_state);
            }
            continue;
        }

        if (section == .none) continue;

        // ── indent 2+: section data ──
        switch (section) {
            .plugin_multiline => {
                // Strip base indent (4 spaces) but preserve relative indentation
                const raw_content = if (line.len >= 4 and std.mem.eql(u8, line[0..4], "    "))
                    line[4..]
                else
                    trimmed;
                plugin_ml.lines.append(a, dupe(a, raw_content)) catch {};
                continue;
            },
            .plugin => continue,
            .pins => readPin(a, s, trimmed),
            .params => readParam(a, s, trimmed),
            .instances => {
                if (std.mem.startsWith(u8, trimmed, ".parameters{"))
                    readInstanceParameters(a, s, trimmed)
                else
                    readInstance(a, s, trimmed);
            },
            .type_table => {
                if (tt_state.remaining > 0) {
                    readTypeTableRow(a, s, trimmed, &tt_state);
                    tt_state.remaining -|= 1;
                }
            },
            .nets => readNet(a, s, trimmed, &tagged),
            .wires => readWire(a, s, trimmed),
            .drawing => readDrawing(a, s, trimmed),
            .includes => readInclude(a, s, trimmed),
            .analyses => readPrefixedProp(a, s, trimmed, "analysis."),
            .measures => readPrefixedProp(a, s, trimmed, "measure."),
            .code_block => {
                const prev = s.spice_body orelse "";
                const new = std.fmt.allocPrint(a, "{s}\n{s}", .{ prev, trimmed }) catch null;
                if (s.spice_body) |old| a.free(@constCast(old));
                s.spice_body = new;
            },
            .annotations => readAnnotation(a, s, trimmed),
            .generate => {
                gen_state.lines.append(a, dupe(a, line)) catch {};
            },
            .none => {},
        }
    }

    if (gen_state.lines.items.len > 0) {
        flushGenerate(a, s, &gen_state, &tagged);
    }

    flushPluginML(a, s, &plugin_ml);
    repackConns(a, s, tagged.items);
}

// ─────────────────────────────────────────────────────────────────────────────
// HEADER
// ─────────────────────────────────────────────────────────────────────────────

fn parseHeader(hdr: []const u8) SchematicType {
    if (std.mem.startsWith(u8, hdr, "chn_testbench")) return .testbench;
    if (std.mem.startsWith(u8, hdr, "chn_prim")) return .primitive;
    return .schematic;
}

fn topLevelFromLine(trimmed: []const u8) ?TopLevel {
    if (std.mem.startsWith(u8, trimmed, "SYMBOL")) return .symbol;
    if (std.mem.startsWith(u8, trimmed, "SCHEMATIC")) return .schematic;
    if (std.mem.startsWith(u8, trimmed, "TESTBENCH")) return .testbench;
    return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// SUB-SECTION RESOLUTION
// ─────────────────────────────────────────────────────────────────────────────

fn resolveSubSection(trimmed: []const u8, s: *Schemify, a: Allocator, gs: *GenState) ?Section {
    // Key-value metadata lines: "prefix:" -> sym_prop with mapped key
    const kv_meta = .{
        .{ "desc:", "description" },
        .{ "spice_prefix:", "spice_prefix" },
        .{ "spice_format:", "spice_format" },
        .{ "spice_lib:", "spice_lib" },
    };
    inline for (kv_meta) |entry| {
        if (std.mem.startsWith(u8, trimmed, entry[0])) {
            const val = std.mem.trim(u8, trimmed[entry[0].len..], " \t");
            if (val.len > 0) appendProp(a, &s.sym_props, entry[1], val);
            return .none;
        }
    }

    if (std.mem.startsWith(u8, trimmed, "type:")) {
        const val = std.mem.trim(u8, trimmed[5..], " \t");
        appendProp(a, &s.sym_props, "symbol_type", val);
        return .none;
    }

    // Section headers: match prefix up to ' ', '[', or ':'
    const first_word = blk: {
        for (trimmed, 0..) |c, i| {
            if (c == ' ' or c == '[' or c == ':') break :blk trimmed[0..i];
        }
        break :blk trimmed;
    };
    if (section_map.get(first_word)) |sec| return sec;

    // Check for "shapes:" as alias for drawing
    if (std.mem.startsWith(u8, trimmed, "shapes")) return .drawing;

    if (std.mem.startsWith(u8, trimmed, "generate ")) {
        parseGenerateHeader(trimmed, gs);
        return .generate;
    }

    if (isTypeTableHeader(trimmed)) return .type_table;

    return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION READERS
// ─────────────────────────────────────────────────────────────────────────────

fn readPin(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
    const name = tok.next() orelse return;
    const dir_str = tok.next() orelse "inout";
    var width: u16 = 1;
    var pin_x: i32 = 0;
    var pin_y: i32 = 0;
    while (tok.next()) |attr| {
        if (std.mem.startsWith(u8, attr, "width="))
            width = std.fmt.parseInt(u16, attr[6..], 10) catch 1
        else if (std.mem.startsWith(u8, attr, "x="))
            pin_x = std.fmt.parseInt(i32, attr[2..], 10) catch 0
        else if (std.mem.startsWith(u8, attr, "y="))
            pin_y = std.fmt.parseInt(i32, attr[2..], 10) catch 0;
    }
    s.pins.append(a, .{
        .name = dupe(a, name),
        .x = pin_x,
        .y = pin_y,
        .dir = PinDir.fromStr(dir_str),
        .width = width,
    }) catch {};
}

fn readParam(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return;
    const key = std.mem.trim(u8, trimmed[0..eq], " \t");
    const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    if (key.len == 0) return;
    appendProp(a, &s.sym_props, key, val);
}

fn readInstance(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
    const inst_name = tok.next() orelse return;
    const symbol = tok.next() orelse return;

    const prop_start: u32 = @intCast(s.props.items.len);
    var inst_x: i32 = 0;
    var inst_y: i32 = 0;
    var inst_rot: u2 = 0;
    var inst_flip: bool = false;

    while (tok.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        const val = kv[eq + 1 ..];
        if (std.mem.eql(u8, key, "x"))
            inst_x = std.fmt.parseInt(i32, val, 10) catch 0
        else if (std.mem.eql(u8, key, "y"))
            inst_y = std.fmt.parseInt(i32, val, 10) catch 0
        else if (std.mem.eql(u8, key, "rot"))
            inst_rot = std.fmt.parseInt(u2, val, 10) catch 0
        else if (std.mem.eql(u8, key, "flip"))
            inst_flip = (std.fmt.parseInt(u1, val, 10) catch 0) != 0
        else
            s.props.append(a, .{
                .key = dupe(a, key),
                .val = dupe(a, val),
            }) catch {};
    }

    s.instances.append(a, .{
        .name = dupe(a, inst_name),
        .symbol = dupe(a, symbol),
        .kind = typeGroupToKind(symbol),
        .x = inst_x,
        .y = inst_y,
        .flags = .{ .rot = inst_rot, .flip = inst_flip },
        .prop_start = prop_start,
        .prop_count = @intCast(s.props.items.len - prop_start),
    }) catch {};
}

fn readInstanceParameters(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    if (s.instances.len == 0) return;
    const open = std.mem.indexOfScalar(u8, trimmed, '{') orelse return;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse trimmed.len;
    if (open + 1 >= close) return;
    const body = std.mem.trim(u8, trimmed[open + 1 .. close], " \t");

    var pos: usize = 0;
    while (pos < body.len) {
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) pos += 1;
        if (pos >= body.len) break;
        const eq = std.mem.indexOfScalarPos(u8, body, pos, '=') orelse break;
        const key = std.mem.trim(u8, body[pos..eq], " \t");
        if (key.len == 0) break;
        pos = eq + 1;
        if (pos >= body.len) break;

        var val: []const u8 = undefined;
        if (body[pos] == '"' or body[pos] == '\'') {
            const q = body[pos];
            pos += 1;
            const end = std.mem.indexOfScalarPos(u8, body, pos, q) orelse body.len;
            val = body[pos..end];
            pos = if (end < body.len) end + 1 else end;
        } else {
            const start = pos;
            while (pos < body.len and body[pos] != ' ' and body[pos] != '\t') pos += 1;
            val = body[start..pos];
        }

        // Skip structural props already captured
        if (std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "y") or
            std.mem.eql(u8, key, "rot") or std.mem.eql(u8, key, "flip")) continue;

        s.props.append(a, .{ .key = dupe(a, key), .val = dupe(a, val) }) catch {};
    }

    const last = s.instances.len - 1;
    const pstart = s.instances.items(.prop_start)[last];
    s.instances.items(.prop_count)[last] = @intCast(s.props.items.len - pstart);
}

fn readNet(a: Allocator, s: *Schemify, trimmed: []const u8, tagged: *List(TaggedConn)) void {
    const arrow = std.mem.indexOf(u8, trimmed, "->") orelse return;
    const net_name = std.mem.trim(u8, trimmed[0..arrow], " \t");
    const pins_str = std.mem.trim(u8, trimmed[arrow + 2 ..], " \t");
    if (net_name.len == 0 or pins_str.len == 0) return;

    const nn = normalizeBusRange(a, net_name);

    var pin_it = std.mem.tokenizeAny(u8, pins_str, ", \t");
    while (pin_it.next()) |pin_ref| {
        const actual_ref = if (std.mem.indexOf(u8, pin_ref, "->")) |na|
            pin_ref[0..na]
        else
            pin_ref;
        const dot = std.mem.indexOfScalar(u8, actual_ref, '.') orelse continue;
        const pin_name = actual_ref[dot + 1 ..];
        if (pin_name.len == 0) continue;
        const inst_name = actual_ref[0..dot];
        const inst_idx = findInstance(s, inst_name) orelse continue;
        tagged.append(a, .{
            .inst_idx = @intCast(inst_idx),
            .pin = dupe(a, pin_name),
            .net = dupe(a, nn),
        }) catch {};
    }
}

fn readWire(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
    const x0 = std.fmt.parseInt(i32, tok.next() orelse return, 10) catch return;
    const y0 = std.fmt.parseInt(i32, tok.next() orelse return, 10) catch return;
    const x1 = std.fmt.parseInt(i32, tok.next() orelse return, 10) catch return;
    const y1 = std.fmt.parseInt(i32, tok.next() orelse return, 10) catch return;
    if (x0 == x1 and y0 == y1) return; // zero-length wire = pin stub
    const net = tok.next();
    s.wires.append(a, .{
        .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1,
        .net_name = if (net) |n| (a.dupe(u8, n) catch null) else null,
    }) catch {};
}

fn readDrawing(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    if (std.mem.startsWith(u8, trimmed, "lines:") or std.mem.startsWith(u8, trimmed, "text:")) return;

    const GeomSpec = struct { prefix: []const u8, count: u8 };
    const geom_specs = [_]GeomSpec{
        .{ .prefix = "line ", .count = 4 },
        .{ .prefix = "rect ", .count = 4 },
        .{ .prefix = "rect:", .count = 4 },
        .{ .prefix = "arc ", .count = 5 },
        .{ .prefix = "arc:", .count = 5 },
        .{ .prefix = "circle ", .count = 3 },
        .{ .prefix = "circle:", .count = 3 },
    };

    for (geom_specs) |spec| {
        if (std.mem.startsWith(u8, trimmed, spec.prefix)) {
            var tok = std.mem.tokenizeAny(u8, trimmed[spec.prefix.len..], " \t");
            var vals: [5]i32 = .{ 0, 0, 0, 0, 0 };
            for (0..spec.count) |vi| {
                vals[vi] = std.fmt.parseInt(i32, tok.next() orelse return, 10) catch return;
            }
            if (spec.count == 4 and std.mem.startsWith(u8, spec.prefix, "line")) {
                s.lines.append(a, .{ .x0 = vals[0], .y0 = vals[1], .x1 = vals[2], .y1 = vals[3] }) catch {};
            } else if (spec.count == 4 and std.mem.startsWith(u8, spec.prefix, "rect")) {
                s.rects.append(a, .{ .x0 = vals[0], .y0 = vals[1], .x1 = vals[2], .y1 = vals[3] }) catch {};
            } else if (spec.count == 5) {
                s.arcs.append(a, .{
                    .cx = vals[0], .cy = vals[1], .radius = vals[2],
                    .start_angle = @intCast(vals[3]), .sweep_angle = @intCast(vals[4]),
                }) catch {};
            } else if (spec.count == 3) {
                s.circles.append(a, .{ .cx = vals[0], .cy = vals[1], .radius = vals[2] }) catch {};
            }
            return;
        }
    }
}

fn readInclude(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    if (trimmed.len == 0) return;
    appendProp(a, &s.sym_props, "include", trimmed);
}

fn readPrefixedProp(a: Allocator, s: *Schemify, trimmed: []const u8, prefix: []const u8) void {
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return;
    const key = std.mem.trim(u8, trimmed[0..colon], " \t");
    const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
    if (key.len == 0) return;
    const pk = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, key }) catch return;
    s.sym_props.append(a, .{ .key = pk, .val = dupe(a, val) }) catch {};
}

fn readAnnotation(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    // Skip sub-section headers
    for ([_][]const u8{ "op_points", "measures:", "notes:", "node_voltages:" }) |skip| {
        if (std.mem.startsWith(u8, trimmed, skip)) return;
    }
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return;
    const key = std.mem.trim(u8, trimmed[0..colon], " \t");
    const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
    if (key.len > 0 and val.len > 0) {
        const pk = std.fmt.allocPrint(a, "ann.{s}", .{key}) catch return;
        s.sym_props.append(a, .{ .key = pk, .val = dupe(a, val) }) catch {};
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// PLUGIN BLOCK ENTRIES
// ─────────────────────────────────────────────────────────────────────────────

fn readPluginEntry(a: Allocator, s: *Schemify, trimmed: []const u8, ml: *PluginMLState, section: *Section) void {
    if (s.plugin_blocks.items.len == 0) return;
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
        // No colon — treat as simple value entry with empty key? Skip.
        return;
    };
    const key = std.mem.trim(u8, trimmed[0..colon], " \t");
    const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
    if (key.len == 0) return;

    if (std.mem.eql(u8, val, "|")) {
        // Start multi-line value accumulation
        ml.key = dupe(a, key);
        ml.lines = .{};
        section.* = .plugin_multiline;
    } else {
        // Simple key-value entry
        const pb = &s.plugin_blocks.items[s.plugin_blocks.items.len - 1];
        pb.entries.append(a, .{ .key = dupe(a, key), .val = dupe(a, val) }) catch {};
        section.* = .plugin;
    }
}

fn flushPluginML(a: Allocator, s: *Schemify, ml: *PluginMLState) void {
    if (ml.key.len == 0 or ml.lines.items.len == 0) {
        ml.key = "";
        ml.lines = .{};
        return;
    }
    if (s.plugin_blocks.items.len == 0) return;

    // Join accumulated lines with newlines
    var total: usize = 0;
    for (ml.lines.items) |line| total += line.len + 1;
    if (total > 0) total -= 1; // no trailing newline

    const joined = a.alloc(u8, total) catch {
        ml.key = "";
        ml.lines = .{};
        return;
    };
    var pos: usize = 0;
    for (ml.lines.items, 0..) |line, i| {
        @memcpy(joined[pos..][0..line.len], line);
        pos += line.len;
        if (i < ml.lines.items.len - 1) {
            joined[pos] = '\n';
            pos += 1;
        }
    }

    const pb = &s.plugin_blocks.items[s.plugin_blocks.items.len - 1];
    pb.entries.append(a, .{ .key = ml.key, .val = joined }) catch {};
    ml.key = "";
    ml.lines = .{};
}

// ─────────────────────────────────────────────────────────────────────────────
// TYPE TABLE
// ─────────────────────────────────────────────────────────────────────────────

fn isTypeTableHeader(trimmed: []const u8) bool {
    if (!std.mem.endsWith(u8, trimmed, ":")) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '[') == null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') == null) return false;
    for ([_][]const u8{ "pins", "params", "nets", "instances", "op_points" }) |skip| {
        if (std.mem.startsWith(u8, trimmed, skip)) return false;
    }
    return true;
}

fn parseTypeTableHeader(a: Allocator, trimmed: []const u8, state: *TypeTableState) void {
    const delim = for (trimmed, 0..) |c, i| {
        if (c == ' ' or c == '[') break i;
    } else trimmed.len;
    state.type_name = dupe(a, trimmed[0..delim]);
    state.kind = typeGroupToKind(state.type_name);
    state.remaining = parseCountFromBracket(trimmed[delim..]) orelse blk: {
        if (std.mem.indexOfScalarPos(u8, trimmed, delim, '[')) |bs|
            break :blk parseCountFromBracket(trimmed[bs..]) orelse 0
        else
            break :blk 0;
    };
    state.cols = parseColumnNames(a, trimmed);
}

fn readTypeTableRow(a: Allocator, s: *Schemify, trimmed: []const u8, state: *TypeTableState) void {
    const columns = state.cols orelse return;
    if (columns.len == 0) return;

    var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
    var col_idx: usize = 0;
    var inst_name: []const u8 = "";
    var inst_x: i32 = 0;
    var inst_y: i32 = 0;
    var inst_rot: u2 = 0;
    var inst_flip: bool = false;
    const prop_start: u32 = @intCast(s.props.items.len);

    while (tok.next()) |val| {
        if (col_idx >= columns.len) break;
        const col = columns[col_idx];
        if (std.mem.eql(u8, col, "name"))
            inst_name = dupe(a, val)
        else if (std.mem.eql(u8, col, "x"))
            inst_x = std.fmt.parseInt(i32, val, 10) catch 0
        else if (std.mem.eql(u8, col, "y"))
            inst_y = std.fmt.parseInt(i32, val, 10) catch 0
        else if (std.mem.eql(u8, col, "rot"))
            inst_rot = std.fmt.parseInt(u2, val, 10) catch 0
        else if (std.mem.eql(u8, col, "flip"))
            inst_flip = (std.fmt.parseInt(u1, val, 10) catch 0) != 0
        else {
            // Last column captures the rest of the line
            const prop_val = if (col_idx == columns.len - 1) blk: {
                const off = @intFromPtr(val.ptr) - @intFromPtr(trimmed.ptr);
                break :blk std.mem.trimRight(u8, trimmed[off..], " \t\r");
            } else val;
            s.props.append(a, .{ .key = dupe(a, col), .val = dupe(a, prop_val) }) catch {};
        }
        col_idx += 1;
    }

    s.instances.append(a, .{
        .name = inst_name,
        .symbol = dupe(a, state.type_name),
        .kind = state.kind,
        .x = inst_x,
        .y = inst_y,
        .flags = .{ .rot = inst_rot, .flip = inst_flip },
        .prop_start = prop_start,
        .prop_count = @intCast(s.props.items.len - prop_start),
    }) catch {};
}

// ─────────────────────────────────────────────────────────────────────────────
// GENERATE BLOCKS
// ─────────────────────────────────────────────────────────────────────────────

fn parseGenerateHeader(trimmed: []const u8, gs: *GenState) void {
    var tok = std.mem.tokenizeAny(u8, trimmed, " \t:");
    _ = tok.next(); // "generate"
    gs.var_ = tok.next() orelse "i";
    _ = tok.next(); // "in" or range separator
    const range = tok.next() orelse "0..0";
    if (std.mem.indexOf(u8, range, "..")) |dots| {
        gs.start = std.fmt.parseInt(i32, range[0..dots], 10) catch 0;
        gs.end = std.fmt.parseInt(i32, range[dots + 2 ..], 10) catch 0;
    }
}

fn flushGenerate(a: Allocator, s: *Schemify, gs: *GenState, tagged: *List(TaggedConn)) void {
    if (gs.var_.len == 0 or gs.lines.items.len == 0) return;
    const pattern = std.fmt.allocPrint(a, "{{{s}}}", .{gs.var_}) catch return;
    var val = gs.start;
    while (val <= gs.end) : (val += 1) {
        const val_str = std.fmt.allocPrint(a, "{d}", .{val}) catch continue;
        for (gs.lines.items) |l| {
            const expanded = substituteAll(a, l, pattern, val_str) catch continue;
            const trimmed = std.mem.trimLeft(u8, expanded, " ");
            if (std.mem.indexOf(u8, trimmed, "->") != null and
                !std.mem.startsWith(u8, trimmed, "nets"))
            {
                readNet(a, s, trimmed, tagged);
            }
        }
    }
}

fn substituteAll(a: Allocator, src: []const u8, pattern: []const u8, repl: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, src, pattern) == null) return a.dupe(u8, src);
    var result = List(u8){};
    var pos: usize = 0;
    while (pos < src.len) {
        if (pos + pattern.len <= src.len and std.mem.eql(u8, src[pos..][0..pattern.len], pattern)) {
            try result.appendSlice(a, repl);
            pos += pattern.len;
        } else {
            try result.append(a, src[pos]);
            pos += 1;
        }
    }
    return result.toOwnedSlice(a);
}

// ─────────────────────────────────────────────────────────────────────────────
// CONN REPACKING
// ─────────────────────────────────────────────────────────────────────────────

fn repackConns(a: Allocator, s: *Schemify, tagged: []const TaggedConn) void {
    if (tagged.len == 0) return;
    for (0..s.instances.len) |i| {
        const start: u16 = @intCast(s.conns.items.len);
        for (tagged) |e| {
            if (e.inst_idx == @as(u32, @intCast(i)))
                s.conns.append(a, .{ .pin = e.pin, .net = e.net }) catch {};
        }
        const count: u16 = @as(u16, @intCast(s.conns.items.len)) - start;
        s.instances.items(.conn_start)[i] = start;
        s.instances.items(.conn_count)[i] = count;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// POST-PARSE: BUS PIN COLLAPSE
// ─────────────────────────────────────────────────────────────────────────────

fn collapseBusPins(s: *Schemify, a: Allocator) void {
    const n = s.pins.len;
    if (n <= 1) return;

    const pnames = s.pins.items(.name);
    const pdirs = s.pins.items(.dir);
    const pxs = s.pins.items(.x);
    const pys = s.pins.items(.y);

    const consumed = a.alloc(bool, n) catch return;
    defer a.free(consumed);
    @memset(consumed, false);

    var new_pins = std.MultiArrayList(types.Pin){};

    for (0..n) |i| {
        if (consumed[i]) continue;
        if (splitBusPin(pnames[i])) |parts| {
            var min_idx: u32 = parts.idx;
            var max_idx: u32 = parts.idx;
            var count: u32 = 1;
            for (0..n) |j| {
                if (j == i or consumed[j]) continue;
                const pj = splitBusPin(pnames[j]) orelse continue;
                if (!std.mem.eql(u8, parts.base, pj.base) or pdirs[j] != pdirs[i]) continue;
                count += 1;
                if (pj.idx < min_idx) min_idx = pj.idx;
                if (pj.idx > max_idx) max_idx = pj.idx;
            }
            const width = max_idx - min_idx + 1;
            if (count == width and width > 1) {
                consumed[i] = true;
                for (0..n) |j| {
                    if (j == i or consumed[j]) continue;
                    const pj = splitBusPin(pnames[j]) orelse continue;
                    if (std.mem.eql(u8, parts.base, pj.base) and pdirs[j] == pdirs[i])
                        consumed[j] = true;
                }
                const bus_name = std.fmt.allocPrint(a, "{s}[{d}:{d}]", .{ parts.base, max_idx, min_idx }) catch parts.base;
                new_pins.append(a, .{ .name = bus_name, .x = pxs[i], .y = pys[i], .dir = pdirs[i], .width = @intCast(width) }) catch continue;
                continue;
            }
        }
        consumed[i] = true;
        new_pins.append(a, .{ .name = pnames[i], .x = pxs[i], .y = pys[i], .dir = pdirs[i], .width = s.pins.items(.width)[i] }) catch continue;
    }
    s.pins = new_pins;
}

fn splitBusPin(name: []const u8) ?struct { base: []const u8, idx: u32 } {
    if (name.len < 4 or name[name.len - 1] != ']') return null;
    const open = std.mem.lastIndexOfScalar(u8, name, '[') orelse return null;
    const idx = std.fmt.parseInt(u32, name[open + 1 .. name.len - 1], 10) catch return null;
    return .{ .base = name[0..open], .idx = idx };
}

// ─────────────────────────────────────────────────────────────────────────────
// POST-PARSE: SYNTHESIZE PORT INSTANCES
// ─────────────────────────────────────────────────────────────────────────────

fn synthesizePortInstances(s: *Schemify, a: Allocator) void {
    if (s.pins.len == 0) return;
    const orig_len = s.instances.len;
    const pnames = s.pins.items(.name);
    const pdirs = s.pins.items(.dir);
    const pxs = s.pins.items(.x);
    const pys = s.pins.items(.y);

    for (0..s.pins.len) |pi| {
        const kind: DeviceKind = switch (pdirs[pi]) {
            .input => .input_pin,
            .output => .output_pin,
            else => .inout_pin,
        };
        // Check if an instance for this pin already exists
        var found = false;
        for (0..orig_len) |ii| {
            if (s.instances.items(.kind)[ii] != kind) continue;
            const ps = s.instances.items(.prop_start)[ii];
            const pc = s.instances.items(.prop_count)[ii];
            const props = s.props.items[ps..][0..pc];
            for (props) |p| {
                if (std.mem.eql(u8, p.key, "lab") and std.mem.eql(u8, p.val, pnames[pi])) {
                    found = true;
                    break;
                }
            }
            if (found) break;
        }
        if (found) continue;

        // Find wire location for this pin
        var x: i32 = pxs[pi];
        var y: i32 = pys[pi];
        const wnn = s.wires.items(.net_name);
        const wx0 = s.wires.items(.x0);
        const wy0 = s.wires.items(.y0);
        const wx1 = s.wires.items(.x1);
        const wy1 = s.wires.items(.y1);
        for (0..s.wires.len) |wi| {
            const nn = wnn[wi] orelse continue;
            if (wx0[wi] == wx1[wi] and wy0[wi] == wy1[wi] and
                std.mem.eql(u8, nn, pnames[pi]))
            {
                x = wx0[wi];
                y = wy0[wi];
                break;
            }
        }

        const prop_start: u32 = @intCast(s.props.items.len);
        s.props.append(a, .{ .key = dupe(a, "lab"), .val = dupe(a, pnames[pi]) }) catch continue;
        s.instances.append(a, .{
            .name = dupe(a, pnames[pi]),
            .symbol = dupe(a, @tagName(kind)),
            .x = x,
            .y = y,
            .kind = kind,
            .prop_start = prop_start,
            .prop_count = 1,
        }) catch continue;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED UTILITIES
// ─────────────────────────────────────────────────────────────────────────────

fn indentLevel(line: []const u8) u32 {
    var spaces: u32 = 0;
    for (line) |c| {
        if (c == ' ') spaces += 1 else break;
    }
    return spaces / 2;
}

fn stripComment(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t'))
            return std.mem.trimRight(u8, line[0..i], " \t");
    }
    return line;
}

fn typeGroupToKind(name: []const u8) DeviceKind {
    const map = std.StaticStringMap(DeviceKind).initComptime(.{
        .{ "nmos", .nmos4 },      .{ "pmos", .pmos4 },
        .{ "capacitors", .capacitor }, .{ "resistors", .resistor },
        .{ "inductors", .inductor },   .{ "diodes", .diode },
        .{ "ipin", .input_pin },       .{ "opin", .output_pin },
        .{ "iopin", .inout_pin },
    });
    if (map.get(name)) |k| return k;
    return std.meta.stringToEnum(DeviceKind, name) orelse .subckt;
}

fn normalizeBusRange(a: Allocator, name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, "..") == null) return name;
    var result = List(u8){};
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (i + 1 < name.len and name[i] == '.' and name[i + 1] == '.') {
            result.append(a, ':') catch break;
            i += 1;
        } else {
            result.append(a, name[i]) catch break;
        }
    }
    return result.toOwnedSlice(a) catch name;
}

fn findInstance(s: *Schemify, name: []const u8) ?usize {
    const names = s.instances.items(.name);
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

fn parseCountFromBracket(tok: []const u8) ?u32 {
    if (tok.len < 3 or tok[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, tok, ']') orelse return null;
    return std.fmt.parseInt(u32, tok[1..close], 10) catch null;
}

fn parseColumnNames(a: Allocator, header_rest: []const u8) ?[]const []const u8 {
    const open = std.mem.indexOfScalar(u8, header_rest, '{') orelse return null;
    const close = std.mem.indexOfScalar(u8, header_rest, '}') orelse return null;
    if (close <= open) return null;
    var cols = List([]const u8){};
    var col_it = std.mem.tokenizeAny(u8, header_rest[open + 1 .. close], ", \t");
    while (col_it.next()) |col| cols.append(a, col) catch return null;
    return cols.toOwnedSlice(a) catch null;
}

fn appendProp(a: Allocator, list: *List(Property), key: []const u8, val: []const u8) void {
    list.append(a, .{ .key = dupe(a, key), .val = dupe(a, val) }) catch {};
}

fn dupe(a: Allocator, s: []const u8) []const u8 {
    return a.dupe(u8, s) catch s;
}
