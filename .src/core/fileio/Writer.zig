//! Writer.zig — CHN format serializer
//!
//! Writes a Schemify struct back to the CHN text format.
//! Uses std.io.bufferedWriter for output performance.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const types = @import("../types.zig");
const Property = types.Property;
const SchematicType = types.SchematicType;
const PinDir = types.PinDir;
const helpers = @import("../helpers.zig");
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
    const eff: SchematicType = if (s.stype == .schematic and s.pins.len == 0) .testbench else s.stype;

    // ── Header ──
    try w.writeAll(switch (eff) {
        .primitive => "chn_prim 1\n",
        .schematic, .symbol => "chn 1\n",
        .testbench => "chn_testbench 1\n",
    });

    // ── SYMBOL section (component and primitive) ──
    if (eff != .testbench) {
        try w.writeAll("\nSYMBOL ");
        try w.writeAll(if (s.name.len > 0) s.name else "untitled");
        try w.writeByte('\n');

        // Metadata lines
        if (helpers.findProp(s.sym_props.items, "description")) |val| try w.print("  desc: {s}\n", .{val});
        if (helpers.findProp(s.sym_props.items, "symbol_type")) |val| try w.print("  type: {s}\n", .{val});

        try writePins(w, s);
        try writeParams(w, s);

        for ([_][]const u8{ "spice_format", "spice_lib" }) |meta_key|
            if (helpers.findProp(s.sym_props.items, meta_key)) |val|
                try w.print("  {s}: {s}\n", .{ meta_key, val });

        try writeDrawing(w, s);
    }

    // ── SCHEMATIC / TESTBENCH section ──
    if (eff != .primitive) {
        try w.writeByte('\n');
        if (eff == .testbench) {
            try w.writeAll("TESTBENCH ");
            try w.writeAll(if (s.name.len > 0) s.name else "untitled");
            try w.writeByte('\n');
            try writeIncludes(w, s);
        } else {
            try w.writeAll("SCHEMATIC\n");
        }

        try writeInstances(w, s, a);
        try writeNets(w, s, a);
        try writePrefixed(w, s.sym_props.items, "analysis.", "analyses");
        try writePrefixed(w, s.sym_props.items, "measure.", "measures");
        try writeCodeBlock(w, s);
        try writeAnnotations(w, s);
        try writeWires(w, s);
    }

    // ── Plugin blocks ──
    for (s.plugin_blocks.items) |pb| {
        try w.writeAll("\nPLUGIN ");
        try w.writeAll(pb.name);
        try w.writeByte('\n');
        for (pb.entries.items) |e| {
            if (std.mem.indexOfScalar(u8, e.val, '\n') != null) {
                try w.print("  {s}: |\n", .{e.key});
                var line_it = std.mem.splitScalar(u8, e.val, '\n');
                while (line_it.next()) |line| try w.print("    {s}\n", .{line});
            } else {
                try w.print("  {s}: {s}\n", .{ e.key, e.val });
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section writers
// ─────────────────────────────────────────────────────────────────────────────

fn writePins(w: anytype, s: *const Schemify) !void {
    if (s.pins.len == 0) return;
    try w.writeAll("  pins:\n");
    const pn = s.pins.items(.name);
    const pd = s.pins.items(.dir);
    const pw = s.pins.items(.width);
    const px = s.pins.items(.x);
    const py = s.pins.items(.y);
    for (0..s.pins.len) |i| {
        try w.print("    {s}  {s}", .{ pn[i], pinDirStr(pd[i]) });
        if (px[i] != 0 or py[i] != 0) try w.print("  x={d}  y={d}", .{ px[i], py[i] });
        if (pw[i] > 1) try w.print("  width={d}", .{pw[i]});
        try w.writeByte('\n');
    }
}

fn writeParams(w: anytype, s: *const Schemify) !void {
    var count: usize = 0;
    for (s.sym_props.items) |p| if (!helpers.isSymPropMetadata(p.key)) { count += 1; };
    if (count == 0) return;
    try w.writeAll("  params:\n");
    for (s.sym_props.items) |p| {
        if (helpers.isSymPropMetadata(p.key)) continue;
        try w.print("    {s} = {s}\n", .{ p.key, p.val });
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

fn writeInstances(w: anytype, s: *const Schemify, a: Allocator) !void {
    const ikind = s.instances.items(.kind);
    var writable: usize = 0;
    for (0..s.instances.len) |i| if (isWritable(ikind[i])) { writable += 1; };
    if (writable == 0) return;

    try w.writeAll("  instances:\n");

    for (0..s.instances.len) |idx| {
        if (!isWritable(ikind[idx])) continue;
        const iname = s.instances.items(.name)[idx];
        const ix = s.instances.items(.x)[idx];
        const iy = s.instances.items(.y)[idx];
        const flags = s.instances.items(.flags)[idx];
        const isym = s.instances.items(.symbol)[idx];
        const ips = s.instances.items(.prop_start)[idx];
        const ipc = s.instances.items(.prop_count)[idx];

        try w.print("    {s}  {s}  x={d}  y={d}", .{ iname, kindToName(ikind[idx]), ix, iy });
        if (flags.rot != 0) try w.print("  rot={d}", .{@as(u8, flags.rot)});
        if (flags.flip) try w.writeAll("  flip=1");
        if (isym.len > 0) try w.print("  sym={s}", .{stripSymbolExt(isym)});

        if (ipc > 0) {
            const props = s.props.items[ips..][0..ipc];
            var param_count: usize = 0;
            for (props) |p| if (!helpers.isStructuralProp(p.key)) { param_count += 1; };

            if (param_count > 0) {
                const use_block = param_count > 3;
                if (use_block) try w.writeAll("\n      .parameters{ ");
                var written: usize = 0;
                for (props) |p| {
                    if (helpers.isStructuralProp(p.key)) continue;
                    const nv = normalizeVal(a, p.val);
                    defer if (nv.owned) a.free(nv.val);
                    if (use_block and written > 0) try w.writeAll("  ") else try w.writeAll("  ");
                    try w.print("{s}={s}", .{ p.key, nv.val });
                    written += 1;
                }
                if (use_block) try w.writeAll(" }");
            }
        }
        try w.writeByte('\n');
    }
}

fn writeNets(w: anytype, s: *const Schemify, a: Allocator) !void {
    const iname = s.instances.items(.name);
    const ikind = s.instances.items(.kind);
    const ics = s.instances.items(.conn_start);
    const icc = s.instances.items(.conn_count);

    var net_map = std.StringArrayHashMap(List([]const u8)).init(a);
    defer {
        for (net_map.values()) |*list| {
            for (list.items) |ip| a.free(ip);
            list.deinit(a);
        }
        net_map.deinit();
    }

    for (0..s.instances.len) |i| {
        if (ikind[i].isNonElectrical()) continue;
        if (icc[i] == 0) continue;
        for (s.conns.items[ics[i]..][0..icc[i]]) |c| {
            if (c.net.len == 0 or std.mem.eql(u8, c.net, "?")) continue;
            const ip = std.fmt.allocPrint(a, "{s}.{s}", .{ iname[i], c.pin }) catch continue;
            const gop = net_map.getOrPut(c.net) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.append(a, ip) catch continue;
        }
    }

    if (net_map.count() == 0) return;
    var meaningful: usize = 0;
    var chk = net_map.iterator();
    while (chk.next()) |e| if (!isAutoNet(e.key_ptr.*)) { meaningful += 1; };
    if (meaningful == 0) return;

    try w.writeAll("\n  nets:\n");
    var iter = net_map.iterator();
    while (iter.next()) |e| {
        if (isAutoNet(e.key_ptr.*)) continue;
        try w.print("    {s}  -> ", .{e.key_ptr.*});
        for (e.value_ptr.items, 0..) |ip, j| {
            if (j > 0) try w.writeAll(", ");
            try w.writeAll(ip);
        }
        try w.writeByte('\n');
    }
}

fn writeWires(w: anytype, s: *const Schemify) !void {
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
        if (wnn[i]) |n| try w.print(" {s}", .{n});
        try w.writeByte('\n');
    }
}

fn writeIncludes(w: anytype, s: *const Schemify) !void {
    var count: usize = 0;
    for (s.sym_props.items) |p| if (std.mem.eql(u8, p.key, "include")) { count += 1; };
    if (count == 0) return;
    try w.writeAll("  includes:\n");
    for (s.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "include")) try w.print("    {s}\n", .{p.val});
    }
}

fn writePrefixed(w: anytype, props: []const Property, prefix: []const u8, section_name: []const u8) !void {
    var count: usize = 0;
    for (props) |p| if (std.mem.startsWith(u8, p.key, prefix)) { count += 1; };
    if (count == 0) return;
    try w.print("\n  {s}:\n", .{section_name});
    for (props) |p| {
        if (!std.mem.startsWith(u8, p.key, prefix)) continue;
        try w.print("    {s}: {s}\n", .{ p.key[prefix.len..], p.val });
    }
}

fn writeCodeBlock(w: anytype, s: *const Schemify) !void {
    const body = s.spice_body orelse return;
    if (body.len == 0) return;
    try w.writeAll("  code_block:\n");
    var line_it = std.mem.splitScalar(u8, body, '\n');
    while (line_it.next()) |line| try w.print("    {s}\n", .{line});
}

fn writeAnnotations(w: anytype, s: *const Schemify) !void {
    var has = false;
    for (s.sym_props.items) |p| if (std.mem.startsWith(u8, p.key, "ann.")) { has = true; break; };
    if (!has) return;
    try w.writeAll("\n  annotations:\n");
    for (s.sym_props.items) |p| {
        if (!std.mem.startsWith(u8, p.key, "ann.")) continue;
        const sub = p.key["ann.".len..];
        // Skip sub-sections
        for ([_][]const u8{ "op.", "measure.", "note.", "voltage." }) |skip|
            if (std.mem.startsWith(u8, sub, skip)) continue;
        try w.print("    {s}: {s}\n", .{ sub, p.val });
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

fn isAutoNet(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "net") or name.len <= 3) return false;
    for (name[3..]) |c| if (c < '0' or c > '9') return false;
    return true;
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
