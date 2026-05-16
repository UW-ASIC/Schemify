const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const types = @import("../types.zig");
const Property = types.Property;
const SchematicType = types.SchematicType;
const PinDir = types.PinDir;
const helpers = @import("../helpers.zig");
const StringPool = @import("../string_pool.zig").StringPool;
const Schemify = @import("../lib.zig").Schemify;

pub fn writeCHN(a: Allocator, s: *const Schemify) ?[]u8 {
    var buf: List(u8) = .{};
    buf.ensureTotalCapacity(a, 4096) catch {};
    writeCHNImpl(buf.writer(a), s, a) catch {
        buf.deinit(a);
        return null;
    };
    return buf.toOwnedSlice(a) catch {
        buf.deinit(a);
        return null;
    };
}

fn writeCHNImpl(w: anytype, s: *const Schemify, a: Allocator) !void {
    const pool = &s.strings;
    const eff: SchematicType = if (s.stype == .schematic and s.pins.len == 0) .testbench else s.stype;

    try w.writeAll(switch (eff) {
        .primitive => "chn_prim 1\n",
        .schematic, .symbol => "chn 1\n",
        .testbench => "chn_testbench 1\n",
    });

    if (eff != .testbench) {
        try w.writeAll("\nSYMBOL ");
        const name = pool.get(s.name);
        try w.writeAll(if (name.len > 0) name else "untitled");
        try w.writeByte('\n');

        if (helpers.findProp(pool, s.sym_props.items, "description")) |val| try w.print("  desc: {s}\n", .{val});
        if (helpers.findProp(pool, s.sym_props.items, "symbol_type")) |val| try w.print("  type: {s}\n", .{val});

        try writePins(w, s, pool);
        try writeParams(w, s, pool);

        for ([_][]const u8{ "spice_format", "spice_lib" }) |meta_key|
            if (helpers.findProp(pool, s.sym_props.items, meta_key)) |val|
                try w.print("  {s}: {s}\n", .{ meta_key, val });

        try writeDrawing(w, s);
    }

    if (eff != .primitive) {
        try w.writeByte('\n');
        if (eff == .testbench) {
            try w.writeAll("TESTBENCH ");
            const name = pool.get(s.name);
            try w.writeAll(if (name.len > 0) name else "untitled");
            try w.writeByte('\n');
            try writeIncludes(w, s, pool);
        } else {
            try w.writeAll("SCHEMATIC\n");
        }

        try writeInstances(w, s, pool, a);
        try writePrefixed(w, s.sym_props.items, pool, "analysis.", "analyses");
        try writePrefixed(w, s.sym_props.items, pool, "measure.", "measures");
        try writeCodeBlock(w, s, pool);
        try writeAnnotations(w, s, pool);
        try writeWires(w, s, pool);
    }

    for (s.plugin_blocks.items) |pb| {
        try w.writeAll("\nPLUGIN ");
        try w.writeAll(pool.get(pb.name));
        try w.writeByte('\n');
        for (pb.entries.items) |e| {
            const val = pool.get(e.val);
            if (std.mem.indexOfScalar(u8, val, '\n') != null) {
                try w.print("  {s}: |\n", .{pool.get(e.key)});
                var line_it = std.mem.splitScalar(u8, val, '\n');
                while (line_it.next()) |line| try w.print("    {s}\n", .{line});
            } else {
                try w.print("  {s}: {s}\n", .{ pool.get(e.key), val });
            }
        }
    }

    const pyspice = pool.get(s.pyspice_source);
    if (pyspice.len > 0) {
        try w.writeAll("\nPYSPICE\n");
        var line_it = std.mem.splitScalar(u8, pyspice, '\n');
        while (line_it.next()) |line| try w.print("  {s}\n", .{line});
    }

    const doc = pool.get(s.documentation);
    if (doc.len > 0) {
        try w.writeAll("\nDOCUMENTATION\n");
        var line_it = std.mem.splitScalar(u8, doc, '\n');
        while (line_it.next()) |line| try w.print("  {s}\n", .{line});
    }
}

fn writePins(w: anytype, s: *const Schemify, pool: *const StringPool) !void {
    if (s.pins.len == 0) return;
    try w.writeAll("  pins:\n");
    const pn = s.pins.items(.name);
    const pd = s.pins.items(.dir);
    const pw = s.pins.items(.width);
    const px = s.pins.items(.x);
    const py = s.pins.items(.y);
    for (0..s.pins.len) |i| {
        try w.print("    {s}  {s}", .{ pool.get(pn[i]), pinDirStr(pd[i]) });
        if (px[i] != 0 or py[i] != 0) try w.print("  x={d}  y={d}", .{ px[i], py[i] });
        if (pw[i] > 1) try w.print("  width={d}", .{pw[i]});
        try w.writeByte('\n');
    }
}

fn writeParams(w: anytype, s: *const Schemify, pool: *const StringPool) !void {
    var count: usize = 0;
    for (s.sym_props.items) |p| if (!helpers.isSymPropMetadata(pool.get(p.key))) { count += 1; };
    if (count == 0) return;
    try w.writeAll("  params:\n");
    for (s.sym_props.items) |p| {
        const key = pool.get(p.key);
        if (helpers.isSymPropMetadata(key)) continue;
        try w.print("    {s} = {s}\n", .{ key, pool.get(p.val) });
    }
}

fn writeDrawing(w: anytype, s: *const Schemify) !void {
    if (s.lines.len == 0 and s.rects.len == 0 and s.arcs.len == 0 and s.circles.len == 0) return;
    try w.writeAll("  drawing:\n");
    for (0..s.lines.len) |i| try w.print("    line {d} {d} {d} {d}\n", .{
        s.lines.items(.x0)[i], s.lines.items(.y0)[i], s.lines.items(.x1)[i], s.lines.items(.y1)[i],
    });
    for (0..s.rects.len) |i| try w.print("    rect {d} {d} {d} {d}\n", .{
        s.rects.items(.x0)[i], s.rects.items(.y0)[i], s.rects.items(.x1)[i], s.rects.items(.y1)[i],
    });
    for (0..s.arcs.len) |i| try w.print("    arc {d} {d} {d} {d} {d}\n", .{
        s.arcs.items(.cx)[i], s.arcs.items(.cy)[i], s.arcs.items(.radius)[i],
        s.arcs.items(.start_angle)[i], s.arcs.items(.sweep_angle)[i],
    });
    for (0..s.circles.len) |i| try w.print("    circle {d} {d} {d}\n", .{
        s.circles.items(.cx)[i], s.circles.items(.cy)[i], s.circles.items(.radius)[i],
    });
}

fn writeInstances(w: anytype, s: *const Schemify, pool: *const StringPool, a: Allocator) !void {
    const ikind = s.instances.items(.kind);
    var writable: usize = 0;
    for (0..s.instances.len) |i| if (isWritable(ikind[i])) { writable += 1; };
    if (writable == 0) return;

    try w.writeAll("  instances:\n");

    for (0..s.instances.len) |idx| {
        if (!isWritable(ikind[idx])) continue;
        const iname = pool.get(s.instances.items(.name)[idx]);
        const ix = s.instances.items(.x)[idx];
        const iy = s.instances.items(.y)[idx];
        const flags = s.instances.items(.flags)[idx];
        const isym = pool.get(s.instances.items(.symbol)[idx]);
        const ips = s.instances.items(.prop_start)[idx];
        const ipc = s.instances.items(.prop_count)[idx];

        try w.print("    {s}  {s}  x={d}  y={d}", .{ iname, kindToName(ikind[idx]), ix, iy });
        if (flags.rot != 0) try w.print("  rot={d}", .{@as(u8, flags.rot)});
        if (flags.flip) try w.writeAll("  flip=1");
        if (isym.len > 0) try w.print("  sym={s}", .{stripSymbolExt(isym)});

        if (ipc > 0) {
            const props = s.props.items[ips..][0..ipc];
            var param_count: usize = 0;
            for (props) |p| if (!helpers.isStructuralProp(pool.get(p.key))) { param_count += 1; };

            if (param_count > 0) {
                const use_block = param_count > 3;
                if (use_block) try w.writeAll("\n      .parameters{ ");
                var written: usize = 0;
                for (props) |p| {
                    const key = pool.get(p.key);
                    if (helpers.isStructuralProp(key)) continue;
                    const nv = normalizeVal(a, pool.get(p.val));
                    defer if (nv.owned) a.free(nv.val);
                    if (use_block and written > 0) try w.writeAll("  ") else try w.writeAll("  ");
                    try w.print("{s}={s}", .{ key, nv.val });
                    written += 1;
                }
                if (use_block) try w.writeAll(" }");
            }
        }
        try w.writeByte('\n');
    }
}

fn writeWires(w: anytype, s: *const Schemify, pool: *const StringPool) !void {
    if (s.wires.len == 0) return;
    try w.writeAll("\n  wires:\n");
    const wx0 = s.wires.items(.x0);
    const wy0 = s.wires.items(.y0);
    const wx1 = s.wires.items(.x1);
    const wy1 = s.wires.items(.y1);
    const wnn = s.wires.items(.net_name);
    for (0..s.wires.len) |i| {
        if (wx0[i] == wx1[i] and wy0[i] == wy1[i]) continue;
        try w.print("    {d} {d} {d} {d}", .{ wx0[i], wy0[i], wx1[i], wy1[i] });
        const nn = pool.get(wnn[i]);
        if (nn.len > 0) try w.print(" {s}", .{nn});
        try w.writeByte('\n');
    }
}

fn writeIncludes(w: anytype, s: *const Schemify, pool: *const StringPool) !void {
    var count: usize = 0;
    for (s.sym_props.items) |p| if (std.mem.eql(u8, pool.get(p.key), "include")) { count += 1; };
    if (count == 0) return;
    try w.writeAll("  includes:\n");
    for (s.sym_props.items) |p| {
        if (std.mem.eql(u8, pool.get(p.key), "include")) try w.print("    {s}\n", .{pool.get(p.val)});
    }
}

fn writePrefixed(w: anytype, props: []const Property, pool: *const StringPool, prefix: []const u8, section_name: []const u8) !void {
    var count: usize = 0;
    for (props) |p| if (std.mem.startsWith(u8, pool.get(p.key), prefix)) { count += 1; };
    if (count == 0) return;
    try w.print("\n  {s}:\n", .{section_name});
    for (props) |p| {
        const key = pool.get(p.key);
        if (!std.mem.startsWith(u8, key, prefix)) continue;
        try w.print("    {s}: {s}\n", .{ key[prefix.len..], pool.get(p.val) });
    }
}

fn writeCodeBlock(w: anytype, s: *const Schemify, pool: *const StringPool) !void {
    const body = pool.get(s.spice_body);
    if (body.len == 0) return;
    try w.writeAll("  code_block:\n");
    var line_it = std.mem.splitScalar(u8, body, '\n');
    while (line_it.next()) |line| try w.print("    {s}\n", .{line});
}

fn writeAnnotations(w: anytype, s: *const Schemify, pool: *const StringPool) !void {
    var has = false;
    for (s.sym_props.items) |p| if (std.mem.startsWith(u8, pool.get(p.key), "ann.")) { has = true; break; };
    if (!has) return;
    try w.writeAll("\n  annotations:\n");
    for (s.sym_props.items) |p| {
        const key = pool.get(p.key);
        if (!std.mem.startsWith(u8, key, "ann.")) continue;
        const sub = key["ann.".len..];
        for ([_][]const u8{ "op.", "measure.", "note.", "voltage." }) |skip|
            if (std.mem.startsWith(u8, sub, skip)) continue;
        try w.print("    {s}: {s}\n", .{ sub, pool.get(p.val) });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn pinDirStr(dir: PinDir) []const u8 {
    return switch (dir) {
        .input => "in", .output => "out", .inout => "inout",
        .power => "inout", .ground => "inout",
    };
}

fn isWritable(kind: types.DeviceKind) bool {
    if (!kind.isNonElectrical()) return true;
    return kind.isLabel() or kind.isPower();
}

fn kindToName(kind: types.DeviceKind) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "nmos3", "nmos" },     .{ "nmos4", "nmos" },
        .{ "nmos4_depl", "nmos" }, .{ "nmos_sub", "nmos" },
        .{ "nmoshv4", "nmos" },    .{ "rnmos4", "nmos" },
        .{ "pmos3", "pmos" },      .{ "pmos4", "pmos" },
        .{ "pmos_sub", "pmos" },   .{ "pmoshv4", "pmos" },
        .{ "resistor3", "resistor" }, .{ "var_resistor", "resistor" },
        .{ "zener", "diode" },
        .{ "sqwsource", "vsource" }, .{ "ammeter", "vsource" },
        .{ "input_pin", "ipin" }, .{ "output_pin", "opin" }, .{ "inout_pin", "iopin" },
    });
    return map.get(@tagName(kind)) orelse @tagName(kind);
}

fn stripSymbolExt(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".sch") or std.mem.endsWith(u8, path, ".sym"))
        return path[0 .. path.len - 4];
    return path;
}

const NormVal = struct { val: []const u8, owned: bool };
fn normalizeVal(a: Allocator, val: []const u8) NormVal {
    if (std.mem.indexOf(u8, val, "..") == null) return .{ .val = val, .owned = false };
    var result = List(u8){};
    var i: usize = 0;
    while (i < val.len) : (i += 1) {
        if (i + 1 < val.len and val[i] == '.' and val[i + 1] == '.') {
            result.append(a, ':') catch break;
            i += 1;
        } else result.append(a, val[i]) catch break;
    }
    return .{ .val = result.toOwnedSlice(a) catch val, .owned = true };
}
