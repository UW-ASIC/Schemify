//! UniversalLowering — bus expansion helpers and waveform/value parsing.
//!
//! These functions are used during the Netlister → univ.Netlist conversion
//! (`convertToSpice` in the main netlist module) and during format-template
//! expansion for bus instances.
//!
//! Covers:
//!   - `parseBusRange` / `expandBusNet` / `expandBusNetByPos`
//!   - `parseWaveform` / `parseOptF64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const fm = @import("FeatureModel.zig");
const univ = @import("../spice/universal.zig");

// ── Bus range helpers ─────────────────────────────────────────────────────── //

pub fn parseBusRange(name: []const u8) ?fm.BusRange {
    const ob = std.mem.indexOfScalar(u8, name, '[') orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, name, ob + 1, ':') orelse return null;
    const cb = std.mem.indexOfScalarPos(u8, name, colon + 1, ']') orelse return null;
    const hi = std.fmt.parseInt(i32, name[ob + 1 .. colon], 10) catch return null;
    const lo = std.fmt.parseInt(i32, name[colon + 1 .. cb], 10) catch return null;
    return .{ .prefix = name[0..ob], .hi = hi, .lo = lo, .suffix = name[cb + 1 ..] };
}

pub fn expandBusNetByPos(net: []const u8, pos: u32, a: Allocator) []const u8 {
    if (std.mem.indexOfScalar(u8, net, ',') != null) {
        var it = std.mem.tokenizeScalar(u8, net, ',');
        var elem_idx: u32 = 0;
        while (it.next()) |elem| {
            if (elem_idx == pos) return elem;
            elem_idx += 1;
        }
        return net;
    }
    const ob = std.mem.indexOfScalar(u8, net, '[') orelse return net;
    var sep_start: usize = 0;
    var sep_end: usize = 0;
    var use_dot_notation = false;
    if (std.mem.indexOfScalarPos(u8, net, ob + 1, ':')) |colon| {
        sep_start = colon;
        sep_end = colon + 1;
    } else if (std.mem.indexOfPos(u8, net, ob + 1, "..")) |dot2| {
        sep_start = dot2;
        sep_end = dot2 + 2;
        use_dot_notation = true;
    } else return net;
    const cb = std.mem.indexOfScalarPos(u8, net, sep_end, ']') orelse return net;
    const hi = std.fmt.parseInt(i32, net[ob + 1 .. sep_start], 10) catch return net;
    const lo = std.fmt.parseInt(i32, net[sep_end .. cb], 10) catch return net;
    const size: i32 = @as(i32, @intCast(@abs(hi - lo))) + 1;
    if (@as(i32, @intCast(pos)) >= size) return net;
    const idx: i32 = if (hi >= lo) hi - @as(i32, @intCast(pos)) else hi + @as(i32, @intCast(pos));
    const prefix = net[0..ob];
    const suffix = net[cb + 1 ..];
    if (use_dot_notation) {
        return std.fmt.allocPrint(a, "{s}{d}{s}", .{ prefix, idx, suffix }) catch net;
    } else {
        return std.fmt.allocPrint(a, "{s}[{d}]{s}", .{ prefix, idx, suffix }) catch net;
    }
}

pub fn expandBusNet(a: Allocator, net: []const u8, out: *std.ArrayListUnmanaged(u8)) bool {
    const ob = std.mem.indexOfScalar(u8, net, '[') orelse return false;
    var sep_start: usize = 0;
    var sep_end: usize = 0;
    var use_dot = false;
    if (std.mem.indexOfScalarPos(u8, net, ob + 1, ':')) |colon| {
        sep_start = colon;
        sep_end = colon + 1;
    } else if (std.mem.indexOfPos(u8, net, ob + 1, "..")) |dot2| {
        sep_start = dot2;
        sep_end = dot2 + 2;
        use_dot = true;
    } else return false;
    const cb = std.mem.indexOfScalarPos(u8, net, sep_end, ']') orelse return false;
    const hi = std.fmt.parseInt(i32, net[ob + 1 .. sep_start], 10) catch return false;
    const lo = std.fmt.parseInt(i32, net[sep_end .. cb], 10) catch return false;
    const prefix = net[0..ob];
    const suffix = net[cb + 1 ..];
    const step: i32 = if (hi >= lo) -1 else 1;
    var idx = hi;
    var first = true;
    while (true) {
        if (!first) out.append(a, ' ') catch {};
        first = false;
        if (use_dot) {
            const s = std.fmt.allocPrint(a, "{s}{d}{s}", .{ prefix, idx, suffix }) catch break;
            out.appendSlice(a, s) catch {};
        } else {
            const s = std.fmt.allocPrint(a, "{s}[{d}]{s}", .{ prefix, idx, suffix }) catch break;
            out.appendSlice(a, s) catch {};
        }
        if (idx == lo) break;
        idx += step;
    }
    return true;
}

// ── Waveform / value parsing ──────────────────────────────────────────────── //

pub fn parseOptF64(props: []const fm.DeviceProp, key: []const u8) ?f64 {
    const s = @import("TemplateExpander.zig").lookupPropValue(props, key) orelse return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

pub fn parseWaveform(props: []const fm.DeviceProp) ?univ.SourceWaveform {
    if (@import("TemplateExpander.zig").lookupPropValue(props, "pulse")) |_| {
        return .{ .pulse = .{
            .v1     = parseOptF64(props, "v1")  orelse 0,
            .v2     = parseOptF64(props, "v2")  orelse 1,
            .delay  = parseOptF64(props, "td")  orelse 0,
            .rise   = parseOptF64(props, "tr")  orelse 0,
            .fall   = parseOptF64(props, "tf")  orelse 0,
            .width  = parseOptF64(props, "pw")  orelse 1e-9,
            .period = parseOptF64(props, "per") orelse 2e-9,
        } };
    }
    if (@import("TemplateExpander.zig").lookupPropValue(props, "sin")) |_| {
        return .{ .sin = .{
            .offset    = parseOptF64(props, "vo")   orelse 0,
            .amplitude = parseOptF64(props, "va")   orelse 1,
            .freq      = parseOptF64(props, "freq") orelse 1e6,
        } };
    }
    return null;
}
