//! utils.zig — CHN format: single source of truth
//!
//! All section definitions are comptime constants. Dispatch is O(1) via array index.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SchemifyMod = @import("../Schemify.zig");
const Devices = @import("../devices/Devices.zig");
const simd = @import("utility").simd;
const List = std.ArrayListUnmanaged;
const PinDir = SchemifyMod.PinDir;
const Schemify = SchemifyMod.Schemify;
const Prop = SchemifyMod.Prop;

// ─────────────────────────────────────────────────────────────────────────────
// TOP-LEVEL section enum (indent=0 markers)
// ─────────────────────────────────────────────────────────────────────────────

pub const ChnTopLevel = enum(u8) {
    symbol = 0,
    schematic,
    testbench,
};

// ─────────────────────────────────────────────────────────────────────────────
// SUB-SECTION enum (indent=1 headers → content at indent≥2)
// ─────────────────────────────────────────────────────────────────────────────

pub const ChnSection = enum(u8) {
    none = 0,
    pins,
    params,
    instances_kv,
    type_table,
    nets,
    wires,
    drawing,
    includes,
    analyses,
    measures,
    code_block,
    annotations,
    ann_voltages,
    ann_op_points,
    ann_measures,
    ann_notes,
    generate,
    spice_body,
};

pub const SECTION_COUNT = 19;

// ─────────────────────────────────────────────────────────────────────────────
// SECTION METADATA TABLE — comptime, O(1) indexed by ChnSection ordinal
// ─────────────────────────────────────────────────────────────────────────────

pub const SectionMeta = struct {
    top: ChnTopLevel,
    header: ?[]const u8,
    parent: ChnSection = .none,
};

pub const SECTION_TABLE: [SECTION_COUNT]SectionMeta = blk: {
    var table: [SECTION_COUNT]SectionMeta = undefined;
    for (0..SECTION_COUNT) |i| {
        table[i] = .{ .top = .schematic, .header = null, .parent = .none };
    }

    table[@intFromEnum(ChnSection.pins)].top = .symbol;
    table[@intFromEnum(ChnSection.params)].top = .symbol;
    table[@intFromEnum(ChnSection.drawing)].top = .symbol;
    table[@intFromEnum(ChnSection.type_table)].top = .symbol;

    table[@intFromEnum(ChnSection.instances_kv)].top = .schematic;
    table[@intFromEnum(ChnSection.nets)].top = .schematic;
    table[@intFromEnum(ChnSection.wires)].top = .schematic;
    table[@intFromEnum(ChnSection.includes)].top = .schematic;
    table[@intFromEnum(ChnSection.analyses)].top = .schematic;
    table[@intFromEnum(ChnSection.measures)].top = .schematic;
    table[@intFromEnum(ChnSection.code_block)].top = .schematic;
    table[@intFromEnum(ChnSection.annotations)].top = .schematic;
    table[@intFromEnum(ChnSection.generate)].top = .schematic;
    table[@intFromEnum(ChnSection.spice_body)].top = .schematic;

    table[@intFromEnum(ChnSection.ann_voltages)].top = .schematic;
    table[@intFromEnum(ChnSection.ann_voltages)].parent = .annotations;
    table[@intFromEnum(ChnSection.ann_op_points)].top = .schematic;
    table[@intFromEnum(ChnSection.ann_op_points)].parent = .annotations;
    table[@intFromEnum(ChnSection.ann_measures)].top = .schematic;
    table[@intFromEnum(ChnSection.ann_measures)].parent = .annotations;
    table[@intFromEnum(ChnSection.ann_notes)].top = .schematic;
    table[@intFromEnum(ChnSection.ann_notes)].parent = .annotations;

    table[@intFromEnum(ChnSection.pins)].header = "pins";
    table[@intFromEnum(ChnSection.params)].header = "params";
    table[@intFromEnum(ChnSection.instances_kv)].header = "instances";
    table[@intFromEnum(ChnSection.nets)].header = "nets";
    table[@intFromEnum(ChnSection.wires)].header = "wires";
    table[@intFromEnum(ChnSection.drawing)].header = "drawing";
    table[@intFromEnum(ChnSection.includes)].header = "includes";
    table[@intFromEnum(ChnSection.analyses)].header = "analyses";
    table[@intFromEnum(ChnSection.measures)].header = "measures";
    table[@intFromEnum(ChnSection.code_block)].header = "code_block";
    table[@intFromEnum(ChnSection.annotations)].header = "annotations";
    table[@intFromEnum(ChnSection.ann_voltages)].header = "node_voltages";
    table[@intFromEnum(ChnSection.ann_op_points)].header = "op_points";
    table[@intFromEnum(ChnSection.ann_measures)].header = "measures";
    table[@intFromEnum(ChnSection.ann_notes)].header = "notes";

    break :blk table;
};

// ─────────────────────────────────────────────────────────────────────────────
// O(1) HEADER LOOKUP
// ─────────────────────────────────────────────────────────────────────────────

const HEADER_MAP = std.ComptimeStringMap(ChnSection, .{
    .{ "pins", .pins },
    .{ "params", .params },
    .{ "instances", .instances_kv },
    .{ "nets", .nets },
    .{ "wires", .wires },
    .{ "drawing", .drawing },
    .{ "includes", .includes },
    .{ "analyses", .analyses },
    .{ "measures", .measures },
    .{ "code_block", .code_block },
    .{ "annotations", .annotations },
    .{ "node_voltages", .ann_voltages },
    .{ "op_points", .ann_op_points },
    .{ "notes", .ann_notes },
});

/// Exact-match section lookup by header string.
pub fn sectionFromExactHeader(h: []const u8) ?ChnSection {
    return HEADER_MAP.get(h);
}

// ─────────────────────────────────────────────────────────────────────────────
// PARSE STATE
// ─────────────────────────────────────────────────────────────────────────────

pub const TaggedConn = struct {
    inst_idx: u32,
    pin: []const u8,
    net: []const u8,
};

pub const TypeTableState = struct {
    type_name: []const u8 = "",
    kind: Devices.DeviceKind = .unknown,
    cols: ?[]const []const u8 = null,
    remaining: u32 = 0,
};

/// Generate block state — passed as pointer, not global.
pub const GenState = struct {
    var_: []const u8 = "",
    start: i32 = 0,
    end: i32 = 0,
    lines: List([]const u8) = .{},
};

pub const AnnState = struct {
    subsection: ChnSection = .annotations,
    op_cols: ?[]const []const u8 = null,
    note_idx: u32 = 0,
};

pub const ParseState = union(enum) {
    type_table: *TypeTableState,
    gen: *GenState,
    ann: *AnnState,
    none: void,
};

// ─────────────────────────────────────────────────────────────────────────────
// TOP-LEVEL PARSE ENTRY POINT
// ─────────────────────────────────────────────────────────────────────────────

pub fn parse(s: *Schemify, input: []const u8) void {
    const a = s.alloc();
    var it = simd.LineIterator.init(input);
    var tagged: List(TaggedConn) = .{};

    var top: ChnTopLevel = .schematic;
    var subsection: ChnSection = .none;

    var type_table_state: TypeTableState = .{};
    var gen_state: GenState = .{};
    var ann_state: AnnState = .{};

    var type_table_remaining: u32 = 0;

    const hdr_raw = it.next() orelse return;
    const hdr = std.mem.trim(u8, hdr_raw, " \t\r");
    s.stype = parseHeader(hdr);
    var ver_tok = std.mem.tokenizeAny(u8, hdr, " \t");
    if (ver_tok.next()) |v| {
        if (!std.mem.eql(u8, v, "1.0") and !std.mem.eql(u8, v, "1")) {
            s.emit(.warn, "unsupported chn version: {s}", .{v});
        }
    }

    while (it.next()) |raw| {
        const full = trimLine(raw);
        if (full.len == 0) continue;
        const line = stripComment(full);
        if (line.len == 0) continue;

        const indent = indentLevel(line);
        const trimmed = std.mem.trimLeft(u8, line, " ");

        if (indent == 0) {
            top = topLevelFromLine(trimmed) orelse top;
            subsection = .none;
            // Extract name from "SYMBOL <name>" or "TESTBENCH <name>" at indent 0
            if (std.mem.startsWith(u8, trimmed, "SYMBOL ")) {
                const name = std.mem.trim(u8, trimmed["SYMBOL ".len..], " \t");
                s.setName(name);
            } else if (std.mem.startsWith(u8, trimmed, "TESTBENCH ")) {
                const name = std.mem.trim(u8, trimmed["TESTBENCH ".len..], " \t");
                s.setName(name);
            }
            continue;
        }

        if (indent == 1) {
            subsection = resolveSubSection(trimmed, s, a, &gen_state) orelse .none;
            if (subsection == .type_table) {
                parseTypeTableHeaderInit(a, trimmed, &type_table_state);
                type_table_remaining = type_table_state.remaining;
            }
            continue;
        }

        if (subsection == .none) continue;

        const meta = &SECTION_TABLE[@intFromEnum(subsection)];
        const sec: ChnSection = if (meta.parent != .none) meta.parent else subsection;

        switch (sec) {
            .pins => Pins.read(a, s, trimmed, &gen_state),
            .params => Params.read(a, s, trimmed, &gen_state),
            .instances_kv => {
                if (std.mem.startsWith(u8, trimmed, ".parameters{"))
                    parseInstanceParameters(a, s, trimmed)
                else
                    Instances.read(a, s, trimmed, &gen_state);
            },
            .type_table => {
                if (type_table_remaining > 0) {
                    TypeTable.read(a, s, trimmed, &type_table_state);
                    type_table_remaining -= 1;
                }
            },
            .nets => Nets.read(a, s, trimmed, &tagged),
            .wires => Wires.read(a, s, trimmed, &gen_state),
            .drawing => Drawing.read(a, s, trimmed, &gen_state),
            .includes => Includes.read(a, s, trimmed, &gen_state),
            .analyses => Analyses.read(a, s, trimmed, &gen_state),
            .measures => Measures.read(a, s, trimmed, &gen_state),
            .code_block => CodeBlock.read(a, s, trimmed, &gen_state),
            .annotations => Annotations.read(a, s, trimmed, &ann_state),
            .ann_voltages, .ann_op_points, .ann_measures, .ann_notes => {},
            .generate => {
                const copy = a.dupe(u8, line) catch return;
                gen_state.lines.append(a, copy) catch {};
            },
            .spice_body => {},
            .none => {},
        }
    }

    if (gen_state.lines.items.len > 0) {
        flushGenerate(a, s, gen_state.var_, gen_state.start, gen_state.end,
                      gen_state.lines.items, &tagged);
    }

    repackConns(a, s, tagged.items);

    s.emit(.info, "parsed {s} \"{s}\": {d} inst, {d} conn, {d} pin, {d} prop", .{
        switch (s.stype) {
            .testbench => "testbench",
            .primitive => "primitive",
            .component => "component",
        },
        s.name,
        s.instances.len,
        s.conns.items.len,
        s.pins.len,
        s.props.items.len,
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// HEADER PARSING
// ─────────────────────────────────────────────────────────────────────────────

fn parseHeader(hdr: []const u8) SchemifyMod.SifyType {
    if (std.mem.startsWith(u8, hdr, "chn_testbench ")) return .testbench;
    if (std.mem.startsWith(u8, hdr, "chn_prim ")) return .primitive;
    return .component;
}

fn topLevelFromLine(trimmed: []const u8) ?ChnTopLevel {
    if (std.mem.startsWith(u8, trimmed, "SYMBOL")) return .symbol;
    if (std.mem.startsWith(u8, trimmed, "SCHEMATIC")) return .schematic;
    if (std.mem.startsWith(u8, trimmed, "TESTBENCH")) return .testbench;
    return null;
}

fn resolveSubSection(trimmed: []const u8, s: *Schemify, a: Allocator, gs: *GenState) ?ChnSection {
    // Key-value metadata lines: "prefix:" -> sym_prop with mapped key name.
    const kv_metadata = .{
        .{ "desc:", "description" },
        .{ "spice_prefix:", "spice_prefix" },
        .{ "spice_format:", "spice_format" },
        .{ "spice_lib:", "spice_lib" },
    };
    inline for (kv_metadata) |entry| {
        if (std.mem.startsWith(u8, trimmed, entry[0])) {
            const val = std.mem.trim(u8, trimmed[entry[0].len..], " \t");
            if (val.len > 0) {
                s.sym_props.append(a, .{
                    .key = a.dupe(u8, entry[1]) catch return null,
                    .val = a.dupe(u8, val) catch return null,
                }) catch {};
            }
            return .none;
        }
    }

    if (std.mem.startsWith(u8, trimmed, "type:")) {
        const val = std.mem.trim(u8, trimmed[5..], " \t");
        s.sym_props.append(a, .{
            .key = a.dupe(u8, "symbol_type") catch return null,
            .val = a.dupe(u8, val) catch return null,
        }) catch {};
        return .none;
    }

    // Section headers: match by prefix(es) and return the corresponding section.
    const section_prefixes = .{
        .{ .sec = ChnSection.pins, .prefixes = .{ "pins ", "pins[" } },
        .{ .sec = ChnSection.params, .prefixes = .{ "params ", "params[" } },
        .{ .sec = ChnSection.instances_kv, .prefixes = .{ "instances:", "instances ", "instances[" } },
        .{ .sec = ChnSection.nets, .prefixes = .{ "nets ", "nets[", "nets:" } },
        .{ .sec = ChnSection.wires, .prefixes = .{ "wires:", "wires ", "wires[" } },
        .{ .sec = ChnSection.drawing, .prefixes = .{ "drawing:", "drawing ", "shapes:", "shapes " } },
        .{ .sec = ChnSection.includes, .prefixes = .{ "includes ", "includes[" } },
        .{ .sec = ChnSection.analyses, .prefixes = .{ "analyses ", "analyses[" } },
        .{ .sec = ChnSection.measures, .prefixes = .{ "measures ", "measures[" } },
        .{ .sec = ChnSection.code_block, .prefixes = .{"code_block:"} },
        .{ .sec = ChnSection.annotations, .prefixes = .{ "annotations:", "annotations " } },
    };
    inline for (section_prefixes) |entry| {
        inline for (entry.prefixes) |prefix| {
            if (std.mem.startsWith(u8, trimmed, prefix) or std.mem.eql(u8, trimmed, prefix)) {
                return entry.sec;
            }
        }
    }

    if (std.mem.startsWith(u8, trimmed, "generate ")) {
        parseGenerateHeader(trimmed, gs);
        return .generate;
    }
    if (isTypeTableHeader(trimmed)) {
        return .type_table;
    }
    return null;
}

fn parseGenerateHeader(trimmed: []const u8, gs: *GenState) void {
    var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t:");
    _ = tok_it.next();
    gs.var_ = tok_it.next() orelse "i";
    _ = tok_it.next();
    const range = tok_it.next() orelse "0..0";
    if (std.mem.indexOf(u8, range, "..")) |dots| {
        gs.start = std.fmt.parseInt(i32, range[0..dots], 10) catch 0;
        gs.end = std.fmt.parseInt(i32, range[dots + 2 ..], 10) catch 0;
    }
}

fn flushGenerate(
    a: Allocator,
    s: *Schemify,
    gen_var: []const u8,
    start: i32,
    end: i32,
    lines: []const []const u8,
    tagged: *List(TaggedConn),
) void {
    if (gen_var.len == 0 or lines.len == 0) return;
    const pattern = std.fmt.allocPrint(a, "{{{s}}}", .{gen_var}) catch return;
    var val = start;
    while (val <= end) : (val += 1) {
        const val_str = std.fmt.allocPrint(a, "{d}", .{val}) catch continue;
        for (lines) |l| {
            const expanded = substituteAll(a, l, pattern, val_str) catch continue;
            const trimmed = std.mem.trimLeft(u8, expanded, " ");
            if (isTypeTableHeader(trimmed)) {
                // Type-table row inside generate — handled via parseTypeTableRow
            } else if (std.mem.indexOf(u8, trimmed, "->") != null and
                !std.mem.startsWith(u8, trimmed, "nets")) {
                Nets.read(a, s, trimmed, tagged);
            }
        }
    }
}

fn substituteAll(a: Allocator, src: []const u8, pattern: []const u8, replacement: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, src, pattern) == null) return a.dupe(u8, src);
    var result = List(u8){};
    var pos: usize = 0;
    while (pos < src.len) {
        if (pos + pattern.len <= src.len and std.mem.eql(u8, src[pos..][0..pattern.len], pattern)) {
            try result.appendSlice(a, replacement);
            pos += pattern.len;
        } else {
            try result.append(a, src[pos]);
            pos += 1;
        }
    }
    return result.toOwnedSlice(a);
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED LINE UTILITIES
// ─────────────────────────────────────────────────────────────────────────────

pub fn indentLevel(line: []const u8) u32 {
    var spaces: u32 = 0;
    for (line) |c| {
        if (c == ' ') spaces += 1 else break;
    }
    return spaces / 2;
}

pub fn trimLine(raw: []const u8) []const u8 {
    return std.mem.trimRight(u8, raw, " \t\r");
}

pub fn stripComment(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
            return std.mem.trimRight(u8, line[0..i], " \t");
        }
    }
    return line;
}

pub fn pinDirFromStr(s: []const u8) PinDir {
    return switch (s[0]) {
        'i' => if (std.mem.eql(u8, s, "in")) .input else .inout,
        'o' => if (std.mem.eql(u8, s, "out")) .output else .inout,
        else => .inout,
    };
}

pub fn pinDirToChnStr(dir: PinDir) []const u8 {
    return switch (dir) {
        .input => "in",
        .output => "out",
        .inout => "inout",
        .power => "inout",
        .ground => "inout",
    };
}

pub fn typeGroupToKind(name: []const u8) Devices.DeviceKind {
    const direct = Devices.DeviceKind.fromStr(name);
    if (direct != .unknown) return direct;
    if (std.mem.eql(u8, name, "nmos")) return .nmos4;
    if (std.mem.eql(u8, name, "pmos")) return .pmos4;
    if (std.mem.eql(u8, name, "capacitors")) return .capacitor;
    if (std.mem.eql(u8, name, "resistors")) return .resistor;
    if (std.mem.eql(u8, name, "inductors")) return .inductor;
    if (std.mem.eql(u8, name, "diodes")) return .diode;
    if (std.mem.eql(u8, name, "ipin")) return .input_pin;
    if (std.mem.eql(u8, name, "opin")) return .output_pin;
    if (std.mem.eql(u8, name, "iopin")) return .inout_pin;
    return .subckt;
}

pub fn writeFlatValue(w: anytype, val: []const u8) !void {
    if (std.mem.indexOfScalar(u8, val, '\n') != null) {
        for (val) |c| {
            try w.writeByte(if (c == '\n') ' ' else c);
        }
    } else {
        try w.writeAll(val);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION HANDLERS
// ─────────────────────────────────────────────────────────────────────────────

pub const Pins = struct {
    pub const section = ChnSection.pins;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, _: *anyopaque) void {
        var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t");
        const name = tok_it.next() orelse return;
        const dir_str = tok_it.next() orelse "inout";
        var width: u16 = 1;
        var pin_x: i32 = 0;
        var pin_y: i32 = 0;
        while (tok_it.next()) |attr| {
            if (std.mem.startsWith(u8, attr, "width=")) {
                width = std.fmt.parseInt(u16, attr[6..], 10) catch 1;
            } else if (std.mem.startsWith(u8, attr, "x=")) {
                pin_x = std.fmt.parseInt(i32, attr[2..], 10) catch 0;
            } else if (std.mem.startsWith(u8, attr, "y=")) {
                pin_y = std.fmt.parseInt(i32, attr[2..], 10) catch 0;
            }
        }
        s.pins.append(a, .{
            .name = a.dupe(u8, name) catch return,
            .x = pin_x,
            .y = pin_y,
            .dir = pinDirFromStr(dir_str),
            .num = null,
            .width = width,
        }) catch {};
    }

    pub fn write(w: anytype, s: *const Schemify) !void {
        if (s.pins.len == 0) return;
        try w.writeAll("  pins:\n");
        const pname = s.pins.items(.name);
        const pdir = s.pins.items(.dir);
        const pwidth = s.pins.items(.width);
        const px = s.pins.items(.x);
        const py = s.pins.items(.y);
        for (0..s.pins.len) |i| {
            try w.writeAll("    ");
            try w.writeAll(pname[i]);
            try w.writeAll("  ");
            try w.writeAll(pinDirToChnStr(pdir[i]));
            if (px[i] != 0 or py[i] != 0) {
                try w.print("  x={d}  y={d}", .{ px[i], py[i] });
            }
            if (pwidth[i] > 1) {
                try w.print("  width={d}", .{pwidth[i]});
            }
            try w.writeByte('\n');
        }
    }
};

pub const Params = struct {
    pub const section = ChnSection.params;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, _: *anyopaque) void {
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (key.len == 0) return;
        s.sym_props.append(a, .{
            .key = a.dupe(u8, key) catch return,
            .val = a.dupe(u8, val) catch return,
        }) catch {};
    }

    pub fn write(w: anytype, s: *const Schemify) !void {
        var count: usize = 0;
        for (s.sym_props.items) |p| {
            if (!isSymPropMetadata(p.key)) count += 1;
        }
        if (count == 0) return;
        try w.writeAll("  params:\n");
        for (s.sym_props.items) |p| {
            if (isSymPropMetadata(p.key)) continue;
            try w.writeAll("    ");
            try w.writeAll(p.key);
            try w.writeAll(" = ");
            try writeFlatValue(w, p.val);
            try w.writeByte('\n');
        }
    }
};

pub const Instances = struct {
    pub const section = ChnSection.instances_kv;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, _: *anyopaque) void {
        parseInstance(a, s, trimmed);
    }

    pub fn write(w: anytype, s: *const Schemify, a: Allocator) !void {
        try writeInstances(w, s, a);
    }
};

pub const Nets = struct {
    pub const section = ChnSection.nets;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, state: *anyopaque) void {
        const tagged = @as(*List(TaggedConn), @ptrCast(@alignCast(state)));
        parseNet(a, s, trimmed, tagged);
    }

    pub fn write(w: anytype, s: *const Schemify, a: Allocator) !void {
        try writeNets(w, s, a);
    }
};

pub const Wires = struct {
    pub const section = ChnSection.wires;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, _: *anyopaque) void {
        var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
        const x0s = tok.next() orelse return;
        const y0s = tok.next() orelse return;
        const x1s = tok.next() orelse return;
        const y1s = tok.next() orelse return;
        const net = tok.next();
        const x0 = std.fmt.parseInt(i32, x0s, 10) catch return;
        const y0 = std.fmt.parseInt(i32, y0s, 10) catch return;
        const x1 = std.fmt.parseInt(i32, x1s, 10) catch return;
        const y1 = std.fmt.parseInt(i32, y1s, 10) catch return;
        // Zero-length wires are connectivity markers (pin stubs), not segments.
        if (x0 == x1 and y0 == y1) return;
        s.wires.append(a, .{
            .x0 = x0,
            .y0 = y0,
            .x1 = x1,
            .y1 = y1,
            .net_name = if (net) |n| (a.dupe(u8, n) catch null) else null,
        }) catch {};
    }

    pub fn write(w: anytype, s: *const Schemify) !void {
        if (s.wires.len == 0) return;
        try w.writeByte('\n');
        try w.writeAll("  wires:\n");
        const wx0 = s.wires.items(.x0);
        const wy0 = s.wires.items(.y0);
        const wx1 = s.wires.items(.x1);
        const wy1 = s.wires.items(.y1);
        const wnn = s.wires.items(.net_name);
        for (0..s.wires.len) |i| {
            // Zero-length wires are connectivity markers (pin stubs), not segments.
            if (wx0[i] == wx1[i] and wy0[i] == wy1[i]) continue;
            try w.print("    {d} {d} {d} {d}", .{ wx0[i], wy0[i], wx1[i], wy1[i] });
            if (wnn[i]) |n| {
                try w.writeByte(' ');
                try w.writeAll(n);
            }
            try w.writeByte('\n');
        }
    }
};

pub const Drawing = struct {
    pub const section = ChnSection.drawing;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, _: *anyopaque) void {
        parseDrawingLine(a, s, trimmed);
    }

    pub fn write(w: anytype, s: *const Schemify) !void {
        const has_drawing = s.lines.len > 0 or s.rects.len > 0 or s.arcs.len > 0 or s.circles.len > 0;
        if (!has_drawing) return;
        try w.writeAll("  drawing:\n");
        const lx0 = s.lines.items(.x0);
        const ly0 = s.lines.items(.y0);
        const lx1 = s.lines.items(.x1);
        const ly1 = s.lines.items(.y1);
        for (0..s.lines.len) |i| {
            try w.print("    line {d} {d} {d} {d}\n", .{ lx0[i], ly0[i], lx1[i], ly1[i] });
        }
        const rx0 = s.rects.items(.x0);
        const ry0 = s.rects.items(.y0);
        const rx1 = s.rects.items(.x1);
        const ry1 = s.rects.items(.y1);
        for (0..s.rects.len) |i| {
            try w.print("    rect {d} {d} {d} {d}\n", .{ rx0[i], ry0[i], rx1[i], ry1[i] });
        }
        const acx = s.arcs.items(.cx);
        const acy = s.arcs.items(.cy);
        const arad = s.arcs.items(.radius);
        const asa = s.arcs.items(.start_angle);
        const asw = s.arcs.items(.sweep_angle);
        for (0..s.arcs.len) |i| {
            try w.print("    arc {d} {d} {d} {d} {d}\n", .{ acx[i], acy[i], arad[i], asa[i], asw[i] });
        }
        const ccx = s.circles.items(.cx);
        const ccy = s.circles.items(.cy);
        const crad = s.circles.items(.radius);
        for (0..s.circles.len) |i| {
            try w.print("    circle {d} {d} {d}\n", .{ ccx[i], ccy[i], crad[i] });
        }
    }
};

pub const Includes = struct {
    pub const section = ChnSection.includes;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, _: *anyopaque) void {
        if (trimmed.len == 0) return;
        s.sym_props.append(a, .{
            .key = a.dupe(u8, "include") catch return,
            .val = a.dupe(u8, trimmed) catch return,
        }) catch {};
    }

    pub fn write(w: anytype, s: *const Schemify) !void {
        var count: usize = 0;
        for (s.sym_props.items) |p| {
            if (std.mem.eql(u8, p.key, "include")) count += 1;
        }
        if (count == 0) return;
        try w.writeAll("  includes:\n");
        for (s.sym_props.items) |p| {
            if (std.mem.eql(u8, p.key, "include")) {
                try w.writeAll("    ");
                try w.writeAll(p.val);
                try w.writeByte('\n');
            }
        }
    }
};

pub const Analyses = struct {
    pub const section = ChnSection.analyses;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, _: *anyopaque) void {
        prefixedSymPropRead(a, s, trimmed, "analysis.");
    }

    pub fn write(w: anytype, s: *const Schemify) !void {
        try writePrefixedSymProps(w, s.sym_props.items, "analysis.", "analyses");
    }
};

pub const Measures = struct {
    pub const section = ChnSection.measures;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, _: *anyopaque) void {
        prefixedSymPropRead(a, s, trimmed, "measure.");
    }

    pub fn write(w: anytype, s: *const Schemify) !void {
        try writePrefixedSymProps(w, s.sym_props.items, "measure.", "measures");
    }
};

pub const CodeBlock = struct {
    pub const section = ChnSection.code_block;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, _: *anyopaque) void {
        const prev = s.spice_body orelse "";
        s.spice_body = std.fmt.allocPrint(a, "{s}\n{s}", .{ prev, trimmed }) catch return;
    }

    pub fn write(w: anytype, s: *const Schemify) !void {
        const body = s.spice_body orelse return;
        if (body.len == 0) return;
        try w.writeAll("  code_block:\n");
        var line_it = std.mem.splitScalar(u8, body, '\n');
        while (line_it.next()) |line| {
            try w.writeAll("    ");
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
};

pub const Annotations = struct {
    pub const section = ChnSection.annotations;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, _: *anyopaque) void {
        parseAnnotationLine(a, s, trimmed);
    }

    pub fn write(w: anytype, s: *const Schemify) !void {
        try writeAnnotations(w, s);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// INTERNAL HELPERS
// ─────────────────────────────────────────────────────────────────────────────

fn isSymPropMetadata(key: []const u8) bool {
    return std.mem.eql(u8, key, "description") or
        std.mem.eql(u8, key, "symbol_type") or
        std.mem.eql(u8, key, "spice_prefix") or
        std.mem.eql(u8, key, "spice_format") or
        std.mem.eql(u8, key, "spice_lib") or
        std.mem.startsWith(u8, key, "ann.") or
        std.mem.startsWith(u8, key, "analysis.") or
        std.mem.startsWith(u8, key, "measure.") or
        std.mem.eql(u8, key, "include");
}

fn prefixedSymPropRead(a: Allocator, s: *Schemify, trimmed: []const u8, prefix: []const u8) void {
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return;
    const key = std.mem.trim(u8, trimmed[0..colon], " \t");
    const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
    if (key.len == 0) return;
    const pk = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, key }) catch return;
    s.sym_props.append(a, .{ .key = pk, .val = a.dupe(u8, val) catch return }) catch {};
}

fn writePrefixedSymProps(w: anytype, props: []const Prop, prefix: []const u8, section_name: []const u8) !void {
    var count: usize = 0;
    for (props) |p| {
        if (std.mem.startsWith(u8, p.key, prefix)) count += 1;
    }
    if (count == 0) return;
    try w.writeByte('\n');
    try w.print("  {s}:\n", .{section_name});
    for (props) |p| {
        if (std.mem.startsWith(u8, p.key, prefix)) {
            const key = p.key[prefix.len..];
            try w.writeAll("    ");
            try w.writeAll(key);
            try w.writeAll(": ");
            try w.writeAll(p.val);
            try w.writeByte('\n');
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// PARSING HELPERS
// ─────────────────────────────────────────────────────────────────────────────

fn parseCountFromBracket(tok: []const u8) ?u32 {
    if (tok.len < 3 or tok[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, tok, ']') orelse return null;
    return std.fmt.parseInt(u32, tok[1..close], 10) catch null;
}

pub fn parseColumnNames(a: Allocator, header_rest: []const u8) ?[]const []const u8 {
    const open = std.mem.indexOfScalar(u8, header_rest, '{') orelse return null;
    const close = std.mem.indexOfScalar(u8, header_rest, '}') orelse return null;
    if (close <= open) return null;
    const cols_str = header_rest[open + 1 .. close];
    var cols = List([]const u8){};
    var col_it = std.mem.tokenizeAny(u8, cols_str, ", \t");
    while (col_it.next()) |col| {
        cols.append(a, col) catch return null;
    }
    return cols.toOwnedSlice(a) catch null;
}

fn isTypeTableHeader(trimmed: []const u8) bool {
    if (!std.mem.endsWith(u8, trimmed, ":")) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '[') == null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') == null) return false;
    if (std.mem.startsWith(u8, trimmed, "pins")) return false;
    if (std.mem.startsWith(u8, trimmed, "params")) return false;
    if (std.mem.startsWith(u8, trimmed, "nets")) return false;
    if (std.mem.startsWith(u8, trimmed, "instances")) return false;
    if (std.mem.startsWith(u8, trimmed, "op_points")) return false;
    return true;
}

fn parseTypeTableHeaderInit(a: Allocator, trimmed: []const u8, state: *TypeTableState) void {
    const first_delim = blk: {
        for (trimmed, 0..) |c, i| {
            if (c == ' ' or c == '[') break :blk i;
        }
        break :blk trimmed.len;
    };
    state.type_name = a.dupe(u8, trimmed[0..first_delim]) catch "";
    state.kind = typeGroupToKind(state.type_name);
    state.remaining = parseCountFromBracket(trimmed[first_delim..]) orelse 0;
    if (state.remaining == 0) {
        if (std.mem.indexOfScalarPos(u8, trimmed, first_delim, '[')) |bracket_start| {
            state.remaining = parseCountFromBracket(trimmed[bracket_start..]) orelse 0;
        }
    }
    state.cols = parseColumnNames(a, trimmed);
}

pub const TypeTable = struct {
    pub const section = ChnSection.type_table;

    pub fn read(a: Allocator, s: *Schemify, trimmed: []const u8, state: *anyopaque) void {
        const st = @as(*TypeTableState, @ptrCast(@alignCast(state)));
        parseTypeTableRow(a, s, trimmed, st.type_name, st.kind, st.cols);
        st.remaining -= 1;
        if (st.remaining == 0) {
            st.* = .{};
        }
    }
};

fn parseTypeTableRow(
    a: Allocator,
    s: *Schemify,
    trimmed: []const u8,
    type_name: []const u8,
    kind: Devices.DeviceKind,
    cols: ?[]const []const u8,
) void {
    const columns = cols orelse return;
    if (columns.len == 0) return;

    var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t");
    var col_idx: usize = 0;
    var inst_name: []const u8 = "";
    var inst_x: i32 = 0;
    var inst_y: i32 = 0;
    var inst_rot: u2 = 0;
    var inst_flip: bool = false;
    const prop_start: u32 = @intCast(s.props.items.len);

    while (tok_it.next()) |val| {
        if (col_idx >= columns.len) break;
        const col = columns[col_idx];
        if (std.mem.eql(u8, col, "name")) {
            inst_name = a.dupe(u8, val) catch "";
        } else if (std.mem.eql(u8, col, "x")) {
            inst_x = std.fmt.parseInt(i32, val, 10) catch 0;
        } else if (std.mem.eql(u8, col, "y")) {
            inst_y = std.fmt.parseInt(i32, val, 10) catch 0;
        } else if (std.mem.eql(u8, col, "rot")) {
            inst_rot = std.fmt.parseInt(u2, val, 10) catch 0;
        } else if (std.mem.eql(u8, col, "flip")) {
            inst_flip = std.fmt.parseInt(u1, val, 10) catch 0 != 0;
        } else {
            const prop_val = if (col_idx == columns.len - 1) blk: {
                const tok_start = @intFromPtr(val.ptr) - @intFromPtr(trimmed.ptr);
                break :blk std.mem.trimRight(u8, trimmed[tok_start..], " \t\r");
            } else val;
            s.props.append(a, .{
                .key = a.dupe(u8, col) catch continue,
                .val = a.dupe(u8, prop_val) catch continue,
            }) catch {};
        }
        col_idx += 1;
    }

    s.instances.append(a, .{
        .name = inst_name,
        .symbol = a.dupe(u8, type_name) catch "",
        .kind = kind,
        .x = inst_x,
        .y = inst_y,
        .rot = inst_rot,
        .flip = inst_flip,
        .prop_start = prop_start,
        .prop_count = @intCast(s.props.items.len - prop_start),
        .conn_start = 0,
        .conn_count = 0,
    }) catch {};
}

fn parseInstance(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const inst_name = tok_it.next() orelse return;
    const symbol = tok_it.next() orelse return;

    const prop_start: u32 = @intCast(s.props.items.len);
    var inst_x: i32 = 0;
    var inst_y: i32 = 0;
    var inst_rot: u2 = 0;
    var inst_flip: bool = false;

    while (tok_it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        const val = kv[eq + 1 ..];
        if (std.mem.eql(u8, key, "x")) {
            inst_x = std.fmt.parseInt(i32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "y")) {
            inst_y = std.fmt.parseInt(i32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "rot")) {
            inst_rot = std.fmt.parseInt(u2, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "flip")) {
            inst_flip = std.fmt.parseInt(u1, val, 10) catch 0 != 0;
        } else if (std.mem.eql(u8, key, "sym")) {
            s.props.append(a, .{
                .key = a.dupe(u8, "sym") catch continue,
                .val = a.dupe(u8, val) catch continue,
            }) catch {};
        } else {
            s.props.append(a, .{
                .key = a.dupe(u8, key) catch continue,
                .val = a.dupe(u8, val) catch continue,
            }) catch {};
        }
    }

    const kind = typeGroupToKind(symbol);
    s.instances.append(a, .{
        .name = a.dupe(u8, inst_name) catch "",
        .symbol = a.dupe(u8, symbol) catch "",
        .kind = kind,
        .x = inst_x,
        .y = inst_y,
        .rot = inst_rot,
        .flip = inst_flip,
        .prop_start = prop_start,
        .prop_count = @intCast(s.props.items.len - prop_start),
        .conn_start = 0,
        .conn_count = 0,
    }) catch {};
}

/// Parse a `.parameters{ key=val key=val ... }` continuation line and append
/// the key-value pairs to the most-recently-added instance's props.
fn parseInstanceParameters(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    if (s.instances.len == 0) return;

    // Extract content between '{' and '}'.
    const open = std.mem.indexOfScalar(u8, trimmed, '{') orelse return;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse trimmed.len;
    if (open + 1 >= close) return;
    const body = std.mem.trim(u8, trimmed[open + 1 .. close], " \t");
    if (body.len == 0) return;

    // Parse key=value pairs, respecting quoted values.
    var pos: usize = 0;
    while (pos < body.len) {
        // Skip whitespace between pairs.
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) : (pos += 1) {}
        if (pos >= body.len) break;

        // Find the '=' separator.
        const eq = std.mem.indexOfScalarPos(u8, body, pos, '=') orelse break;
        const key = std.mem.trim(u8, body[pos..eq], " \t");
        if (key.len == 0) break;

        pos = eq + 1;
        if (pos >= body.len) break;

        // Parse the value — may be quoted.
        var val: []const u8 = undefined;
        if (body[pos] == '"' or body[pos] == '\'') {
            const quote = body[pos];
            pos += 1; // skip opening quote
            const end = std.mem.indexOfScalarPos(u8, body, pos, quote) orelse body.len;
            val = body[pos..end];
            pos = if (end < body.len) end + 1 else end;
        } else {
            const start = pos;
            while (pos < body.len and body[pos] != ' ' and body[pos] != '\t') : (pos += 1) {}
            val = body[start..pos];
        }

        // Skip structural props that are already captured on the instance line.
        if (std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "y") or
            std.mem.eql(u8, key, "rot") or std.mem.eql(u8, key, "flip"))
            continue;

        s.props.append(a, .{
            .key = a.dupe(u8, key) catch continue,
            .val = a.dupe(u8, val) catch continue,
        }) catch {};
    }

    // Update the last instance's prop_count to include the newly-added props.
    const last = s.instances.len - 1;
    const pstart = s.instances.items(.prop_start)[last];
    s.instances.items(.prop_count)[last] = @intCast(s.props.items.len - pstart);
}

fn parseNet(a: Allocator, s: *Schemify, trimmed: []const u8, tagged: *List(TaggedConn)) void {
    const arrow = std.mem.indexOf(u8, trimmed, "->") orelse return;
    var net_name = std.mem.trim(u8, trimmed[0..arrow], " \t");
    const pins_str = std.mem.trim(u8, trimmed[arrow + 2 ..], " \t");
    if (net_name.len == 0 or pins_str.len == 0) return;

    net_name = normalizeBusRange(a, net_name);

    var pin_it = std.mem.tokenizeAny(u8, pins_str, ", \t");
    while (pin_it.next()) |pin_ref| {
        const actual_ref: []const u8 = blk: {
            if (std.mem.indexOf(u8, pin_ref, "->")) |na| {
                break :blk pin_ref[0..na];
            }
            break :blk pin_ref;
        };
        const dot = std.mem.indexOfScalar(u8, actual_ref, '.') orelse continue;
        const pin_name = actual_ref[dot + 1 ..];
        if (pin_name.len == 0) continue;
        const inst_name = actual_ref[0..dot];
        const inst_idx = findInstanceByName(s, inst_name) orelse continue;
        tagged.append(a, .{
            .inst_idx = @intCast(inst_idx),
            .pin = a.dupe(u8, pin_name) catch continue,
            .net = a.dupe(u8, net_name) catch continue,
        }) catch {};
    }
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

fn findInstanceByName(s: *Schemify, name: []const u8) ?usize {
    const names = s.instances.items(.name);
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

pub fn repackConns(a: Allocator, s: *Schemify, tagged: []const TaggedConn) void {
    if (tagged.len == 0) return;
    for (0..s.instances.len) |i| {
        const start: u16 = @intCast(s.conns.items.len);
        for (tagged) |e| {
            if (e.inst_idx == @as(u32, @intCast(i))) {
                s.conns.append(a, .{ .pin = e.pin, .net = e.net }) catch {};
            }
        }
        const count: u16 = @as(u16, @intCast(s.conns.items.len)) - start;
        s.instances.items(.conn_start)[i] = start;
        s.instances.items(.conn_count)[i] = count;
    }
}

fn parseDrawingLine(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    if (std.mem.startsWith(u8, trimmed, "lines:")) return;
    if (std.mem.startsWith(u8, trimmed, "text:")) return;

    if (std.mem.startsWith(u8, trimmed, "line ")) {
        var dtok = std.mem.tokenizeAny(u8, trimmed[5..], " \t");
        const dx0 = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const dy0 = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const dx1 = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const dy1 = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        s.lines.append(a, .{ .layer = 0, .x0 = dx0, .y0 = dy0, .x1 = dx1, .y1 = dy1 }) catch {};
        return;
    }
    if (std.mem.startsWith(u8, trimmed, "rect ") or std.mem.startsWith(u8, trimmed, "rect:")) {
        const rest = trimmed[5..];
        var dtok = std.mem.tokenizeAny(u8, rest, " \t");
        const dx0 = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const dy0 = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const dx1 = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const dy1 = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        s.rects.append(a, .{ .layer = 0, .x0 = dx0, .y0 = dy0, .x1 = dx1, .y1 = dy1 }) catch {};
        return;
    }
    if (std.mem.startsWith(u8, trimmed, "arc ") or std.mem.startsWith(u8, trimmed, "arc:")) {
        const rest = trimmed[4..];
        var dtok = std.mem.tokenizeAny(u8, rest, " \t");
        const dcx = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const dcy = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const drad = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const dsa = std.fmt.parseInt(i16, dtok.next() orelse return, 10) catch return;
        const dsw = std.fmt.parseInt(i16, dtok.next() orelse return, 10) catch return;
        s.arcs.append(a, .{ .layer = 0, .cx = dcx, .cy = dcy, .radius = drad, .start_angle = dsa, .sweep_angle = dsw }) catch {};
        return;
    }
    if (std.mem.startsWith(u8, trimmed, "circle ") or std.mem.startsWith(u8, trimmed, "circle:")) {
        const rest = trimmed[7..];
        var dtok = std.mem.tokenizeAny(u8, rest, " \t");
        const dcx = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const dcy = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        const drad = std.fmt.parseInt(i32, dtok.next() orelse return, 10) catch return;
        s.circles.append(a, .{ .layer = 0, .cx = dcx, .cy = dcy, .radius = drad }) catch {};
        return;
    }
}

fn parseAnnotationLine(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    if (std.mem.startsWith(u8, trimmed, "op_points ") or
        std.mem.startsWith(u8, trimmed, "op_points["))
    {
        return;
    }
    if (std.mem.startsWith(u8, trimmed, "measures:")) return;
    if (std.mem.startsWith(u8, trimmed, "notes:")) return;
    if (std.mem.startsWith(u8, trimmed, "node_voltages:")) return;

    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (key.len > 0 and val.len > 0) {
            const pk = std.fmt.allocPrint(a, "ann.{s}", .{key}) catch return;
            s.sym_props.append(a, .{ .key = pk, .val = a.dupe(u8, val) catch return }) catch {};
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// WRITE HELPERS
// ─────────────────────────────────────────────────────────────────────────────

fn isWritableInstance(kind: Devices.DeviceKind) bool {
    if (!kind.isNonElectrical()) return true;
    return kind == .input_pin or kind == .output_pin or kind == .inout_pin or
        kind == .lab_pin or kind == .gnd or kind == .vdd;
}

fn deviceKindToName(kind: Devices.DeviceKind) []const u8 {
    return switch (kind) {
        .nmos3, .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4, .rnmos4 => "nmos",
        .pmos3, .pmos4, .pmos_sub, .pmoshv4 => "pmos",
        .capacitor => "capacitor",
        .resistor, .resistor3, .var_resistor => "resistor",
        .inductor => "inductor",
        .diode, .zener => "diode",
        .npn => "npn",
        .pnp => "pnp",
        .njfet => "njfet",
        .pjfet => "pjfet",
        .vsource, .sqwsource => "vsource",
        .isource => "isource",
        .ammeter => "vsource",
        .behavioral => "behavioral",
        .vcvs => "vcvs",
        .vccs => "vccs",
        .ccvs => "ccvs",
        .cccs => "cccs",
        .subckt => "subckt",
        .annotation => "annotation",
        .input_pin => "ipin",
        .output_pin => "opin",
        .inout_pin => "iopin",
        .lab_pin => "lab_pin",
        .gnd => "gnd",
        .vdd => "vdd",
        else => @tagName(kind),
    };
}

fn stripSymbolExt(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".sch")) return path[0..path.len - 4];
    if (std.mem.endsWith(u8, path, ".sym")) return path[0..path.len - 4];
    return path;
}

const NormalizedVal = struct { val: []const u8, owned: bool };

fn normalizeVal(a: Allocator, val: []const u8) !NormalizedVal {
    if (std.mem.indexOf(u8, val, "..")) |_| {
        var result = List(u8){};
        var i: usize = 0;
        while (i < val.len) : (i += 1) {
            if (i + 1 < val.len and val[i] == '.' and val[i + 1] == '.') {
                try result.append(a, ':');
                i += 1;
            } else {
                try result.append(a, val[i]);
            }
        }
        return .{ .val = try result.toOwnedSlice(a), .owned = true };
    }
    return .{ .val = val, .owned = false };
}

fn writeInstances(w: anytype, s: *const Schemify, a: Allocator) !void {
    const ikind = s.instances.items(.kind);
    var writable_count: usize = 0;
    for (0..s.instances.len) |i| {
        if (isWritableInstance(ikind[i])) writable_count += 1;
    }
    if (writable_count == 0) return;

    try w.writeAll("  instances:\n");

    for (0..s.instances.len) |idx| {
        if (!isWritableInstance(ikind[idx])) continue;
        const iname = s.instances.items(.name)[idx];
        const iprops = s.instances.items(.prop_start)[idx];
        const ipcount = s.instances.items(.prop_count)[idx];
        const isym = s.instances.items(.symbol)[idx];
        const ix = s.instances.items(.x)[idx];
        const iy = s.instances.items(.y)[idx];
        const irot = s.instances.items(.rot)[idx];
        const iflip = s.instances.items(.flip)[idx];

        try w.writeAll("    ");
        try w.writeAll(iname);
        try w.writeAll("  ");
        try w.writeAll(deviceKindToName(ikind[idx]));
        try w.print("  x={d}  y={d}", .{ ix, iy });
        if (irot != 0) try w.print("  rot={d}", .{@as(u8, irot)});
        if (iflip) try w.writeAll("  flip=1");
        if (isym.len > 0) {
            try w.writeAll("  sym=");
            try w.writeAll(stripSymbolExt(isym));
        }

        if (ipcount > 0) {
            const props_slice = s.props.items[iprops..][0..ipcount];

            // Count non-structural props to decide inline vs block format.
            var param_count: usize = 0;
            for (props_slice) |p| {
                if (!isInstanceStructuralProp(p.key)) param_count += 1;
            }

            if (param_count > 0) {
                const use_block = param_count > 3;
                if (use_block) try w.writeAll("\n      .parameters{ ");

                var written: usize = 0;
                for (props_slice) |p| {
                    if (isInstanceStructuralProp(p.key)) continue;
                    const norm = try normalizeVal(a, p.val);
                    defer if (norm.owned) a.free(norm.val);

                    if (use_block) {
                        if (written > 0) try w.writeAll("  ");
                    } else {
                        try w.writeAll("  ");
                    }
                    try w.writeAll(p.key);
                    try w.writeByte('=');
                    try w.writeAll(norm.val);
                    written += 1;
                }

                if (use_block) try w.writeAll(" }");
            }
        }
        try w.writeByte('\n');
    }
}

fn isInstanceStructuralProp(key: []const u8) bool {
    const h = @import("../helpers.zig");
    return h.isInstanceStructuralProp(key);
}

fn writeNets(w: anytype, s: *const Schemify, a: Allocator) !void {
    const iname = s.instances.items(.name);
    const ikind = s.instances.items(.kind);
    const ics = s.instances.items(.conn_start);
    const icc = s.instances.items(.conn_count);

    var net_map = std.StringArrayHashMap(List([]const u8)).init(a);
    defer {
        for (net_map.values()) |*list| {
            for (list.items) |inst_pin| a.free(inst_pin);
            list.deinit(a);
        }
        net_map.deinit();
    }

    for (0..s.instances.len) |i| {
        if (ikind[i].isNonElectrical()) continue;
        const cc = icc[i];
        if (cc == 0) continue;
        const conns_slice = s.conns.items[ics[i]..][0..cc];
        for (conns_slice) |c| {
            const net_name = c.net;
            if (net_name.len == 0 or std.mem.eql(u8, net_name, "?")) continue;
            const inst_pin = std.fmt.allocPrint(a, "{s}.{s}", .{ iname[i], c.pin }) catch continue;
            const gop = net_map.getOrPut(net_name) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.append(a, inst_pin) catch continue;
        }
    }

    if (net_map.count() == 0) return;

    var meaningful: usize = 0;
    var check_iter = net_map.iterator();
    while (check_iter.next()) |entry| {
        if (!isAutoNetName(entry.key_ptr.*)) meaningful += 1;
    }
    if (meaningful == 0) return;

    try w.writeByte('\n');
    try w.writeAll("  nets:\n");

    var iter = net_map.iterator();
    while (iter.next()) |entry| {
        if (isAutoNetName(entry.key_ptr.*)) continue;
        try w.writeAll("    ");
        try w.writeAll(entry.key_ptr.*);
        try w.writeAll("  -> ");
        for (entry.value_ptr.items, 0..) |inst_pin, j| {
            if (j > 0) try w.writeAll(", ");
            try w.writeAll(inst_pin);
        }
        try w.writeByte('\n');
    }
}

fn isAutoNetName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "net")) return false;
    const suffix = name["net".len..];
    if (suffix.len == 0) return false;
    for (suffix) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn writeAnnotations(w: anytype, s: *const Schemify) !void {
    var has_ann = false;
    for (s.sym_props.items) |p| {
        if (std.mem.startsWith(u8, p.key, "ann.")) { has_ann = true; break; }
    }
    if (!has_ann) return;

    try w.writeAll("\n  annotations:\n");

    for (s.sym_props.items) |p| {
        if (!std.mem.startsWith(u8, p.key, "ann.")) continue;
        const sub = p.key["ann.".len..];
        if (std.mem.startsWith(u8, sub, "op.") or
            std.mem.startsWith(u8, sub, "measure.") or
            std.mem.startsWith(u8, sub, "note.") or
            std.mem.startsWith(u8, sub, "voltage.")) continue;
        try w.writeAll("    ");
        try w.writeAll(sub);
        try w.writeAll(": ");
        try w.writeAll(p.val);
        try w.writeByte('\n');
    }

    try writeAnnSubSection(w, s.sym_props.items, "ann.voltage.", "node_voltages");
    try writeAnnSubSection(w, s.sym_props.items, "ann.op.", "op_points");
    try writeAnnSubSection(w, s.sym_props.items, "ann.measure.", "measures");

    var ncount: usize = 0;
    for (s.sym_props.items) |p| {
        if (std.mem.startsWith(u8, p.key, "ann.note.")) ncount += 1;
    }
    if (ncount > 0) {
        try w.writeAll("\n    notes:\n");
        for (s.sym_props.items) |p| {
            if (!std.mem.startsWith(u8, p.key, "ann.note.")) continue;
            try w.writeAll("      - \"");
            try w.writeAll(p.val);
            try w.writeAll("\"\n");
        }
    }
}

fn writeAnnSubSection(w: anytype, props: []const Prop, prefix: []const u8, section_name: []const u8) !void {
    var count: usize = 0;
    for (props) |p| {
        if (std.mem.startsWith(u8, p.key, prefix)) count += 1;
    }
    if (count == 0) return;
    try w.writeAll("\n    ");
    try w.writeAll(section_name);
    try w.writeAll(":\n");
    for (props) |p| {
        if (!std.mem.startsWith(u8, p.key, prefix)) continue;
        const rest = p.key[prefix.len..];
        try w.print("      {s}:  {s}\n", .{ rest, p.val });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// PLUGIN BLOCK (standalone, used by Writer)
// ─────────────────────────────────────────────────────────────────────────────

pub fn writePluginBlock(w: anytype, name: []const u8, entries: []const Prop) !void {
    try w.writeByte('\n');
    try w.writeAll("PLUGIN ");
    try w.writeAll(name);
    try w.writeByte('\n');
    for (entries) |e| {
        try w.writeAll("  ");
        try w.writeAll(e.key);
        try w.writeAll(": ");
        try writeFlatValue(w, e.val);
        try w.writeByte('\n');
    }
}
