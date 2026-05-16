// exporter.zig - Schemify -> XSchem export conversion.
//
// This is the reverse direction from converter.zig (which handles XSchem -> Schemify).
// Separated because export (native -> foreign) is a distinct concern from import
// (foreign -> native), even though both live under the XSchem backend.

const std = @import("std");
const core = @import("schematic");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const XSchemFiles = types.XSchemFiles;
const Schemify = core.Schemify;

// -- Coordinate helpers ----------------------------------------------------

fn i2f(v: i32) f64 {
    return @as(f64, @floatFromInt(v));
}

// -- Schemify -> XSchemFiles -----------------------------------------------

pub fn mapSchemifyToXSchem(backing: Allocator, sfy: *const Schemify) Allocator.Error!XSchemFiles {
    var xs = XSchemFiles.init(backing);
    errdefer xs.deinit();
    const arena = xs.arena.allocator();

    xs.name = sfy.name;
    xs.file_type = if (sfy.stype == .symbol or sfy.stype == .primitive) .symbol else .schematic;

    // Geometry
    const lines = sfy.lines.slice();
    for (0..sfy.lines.len) |i| {
        try xs.lines.append(arena, .{
            .layer = @intCast(lines.items(.layer)[i]),
            .x0 = i2f(lines.items(.x0)[i]),
            .y0 = i2f(lines.items(.y0)[i]),
            .x1 = i2f(lines.items(.x1)[i]),
            .y1 = i2f(lines.items(.y1)[i]),
        });
    }

    const rects = sfy.rects.slice();
    for (0..sfy.rects.len) |i| {
        try xs.rects.append(arena, .{
            .layer = @intCast(rects.items(.layer)[i]),
            .x0 = i2f(rects.items(.x0)[i]),
            .y0 = i2f(rects.items(.y0)[i]),
            .x1 = i2f(rects.items(.x1)[i]),
            .y1 = i2f(rects.items(.y1)[i]),
        });
    }

    const arcs = sfy.arcs.slice();
    for (0..sfy.arcs.len) |i| {
        try xs.arcs.append(arena, .{
            .layer = @intCast(arcs.items(.layer)[i]),
            .cx = i2f(arcs.items(.cx)[i]),
            .cy = i2f(arcs.items(.cy)[i]),
            .radius = i2f(arcs.items(.radius)[i]),
            .start_angle = @as(f64, @floatFromInt(arcs.items(.start_angle)[i])),
            .sweep_angle = @as(f64, @floatFromInt(arcs.items(.sweep_angle)[i])),
        });
    }

    const circles = sfy.circles.slice();
    for (0..sfy.circles.len) |i| {
        try xs.circles.append(arena, .{
            .layer = @intCast(circles.items(.layer)[i]),
            .cx = i2f(circles.items(.cx)[i]),
            .cy = i2f(circles.items(.cy)[i]),
            .radius = i2f(circles.items(.radius)[i]),
        });
    }

    const wires = sfy.wires.slice();
    for (0..sfy.wires.len) |i| {
        try xs.wires.append(arena, .{
            .x0 = i2f(wires.items(.x0)[i]),
            .y0 = i2f(wires.items(.y0)[i]),
            .x1 = i2f(wires.items(.x1)[i]),
            .y1 = i2f(wires.items(.y1)[i]),
            .net_name = wires.items(.net_name)[i],
            .bus = wires.items(.bus)[i],
        });
    }

    const texts = sfy.texts.slice();
    for (0..sfy.texts.len) |i| {
        try xs.texts.append(arena, .{
            .content = texts.items(.content)[i],
            .x = i2f(texts.items(.x)[i]),
            .y = i2f(texts.items(.y)[i]),
            .layer = @intCast(texts.items(.layer)[i]),
            .size = @as(f64, @floatFromInt(texts.items(.size)[i])) / 25.0,
            .rotation = @intCast(@mod(@as(u32, texts.items(.rotation)[i]), 16)),
        });
    }

    // Pins
    const pins = sfy.pins.slice();
    for (0..sfy.pins.len) |i| {
        try xs.pins.append(arena, .{
            .name = pins.items(.name)[i],
            .x = i2f(pins.items(.x)[i]),
            .y = i2f(pins.items(.y)[i]),
            .direction = @enumFromInt(@intFromEnum(pins.items(.dir)[i])),
            .number = @intCast(pins.items(.num)[i] orelse 0),
        });
    }

    // Instances
    const instances = sfy.instances.slice();
    for (0..sfy.instances.len) |i| {
        const prop_start: u32 = @intCast(xs.props.items.len);
        const inst_props = sfy.props.items[instances.items(.prop_start)[i]..][0..instances.items(.prop_count)[i]];
        for (inst_props) |p| {
            try xs.props.append(arena, .{ .key = p.key, .value = p.val });
        }
        const prop_count: u16 = @intCast(inst_props.len);
        try xs.instances.append(arena, .{
            .name = instances.items(.name)[i],
            .symbol = instances.items(.symbol)[i],
            .x = i2f(instances.items(.x)[i]),
            .y = i2f(instances.items(.y)[i]),
            .rot = @intCast(instances.items(.rot)[i]),
            .flip = instances.items(.flip)[i],
            .prop_start = prop_start,
            .prop_count = prop_count,
        });
    }

    // K-block
    for (sfy.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "type")) {
            xs.k_type = p.val;
        } else if (std.mem.eql(u8, p.key, "format")) {
            xs.k_format = p.val;
        } else if (std.mem.eql(u8, p.key, "template")) {
            xs.k_template = p.val;
        } else if (std.mem.eql(u8, p.key, "extra")) {
            xs.k_extra = p.val;
        } else if (std.mem.eql(u8, p.key, "global")) {
            xs.k_global = std.mem.eql(u8, p.val, "true");
        } else if (std.mem.eql(u8, p.key, "spice_sym_def")) {
            xs.k_spice_sym_def = p.val;
        }
    }

    // S-block
    xs.s_block = sfy.spice_body;

    return xs;
}
