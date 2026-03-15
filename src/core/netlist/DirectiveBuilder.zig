//! DirectiveBuilder — building typed SPICE directives from device props.
//!
//! Covers:
//!   - `emitDeviceModelBlock` — device_model= top-level code block
//!   - `buildCode` — `.code` device → netlist code block (with TCL unescape,
//!     simulator/only_toplevel filtering, .param simplification)
//!   - Symbol helpers: `hasXschemTemplateM`, `hasXschemTemplateBjt`, `hasXschemTemplateJfet`
//!   - `symbolIn` utility

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const fm = @import("FeatureModel.zig");
const te = @import("TemplateExpander.zig");

// Deferred import to avoid circular deps — caller provides the Netlist type.
const univ = @import("../spice/universal.zig");

// ── Device model block ────────────────────────────────────────────────────── //

pub fn emitDeviceModelBlock(netlist: *univ.Netlist, props: []const fm.DeviceProp, a: Allocator) error{OutOfMemory}!void {
    const dm = te.lookupPropValue(props, "device_model") orelse return;
    const stripped = std.mem.trim(u8, dm, "\"");
    var buf: List(u8) = .{};
    defer buf.deinit(a);
    var it = std.mem.splitScalar(u8, stripped, '\n');
    while (it.next()) |raw_ln| {
        const ln = std.mem.trimLeft(u8, raw_ln, " \t\r");
        if (ln.len == 0) continue;
        if (ln[0] == '+') {
            buf.append(a, ' ') catch {};
            buf.appendSlice(a, std.mem.trimLeft(u8, ln[1..], " \t")) catch {};
        } else {
            if (ln[0] == '*') continue;
            if (buf.items.len > 0) buf.append(a, '\n') catch {};
            buf.appendSlice(a, ln) catch {};
        }
    }
    if (buf.items.len > 0) {
        try netlist.addToplevelCodeBlock(try a.dupe(u8, buf.items));
    }
}

// ── Symbol template helpers ───────────────────────────────────────────────── //

pub fn symbolIn(symbol: []const u8, comptime names: []const []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, symbol, '/')) |i| symbol[i + 1 ..] else symbol;
    inline for (names) |k| if (std.mem.eql(u8, base, k)) return true;
    return false;
}

pub inline fn hasXschemTemplateM(symbol: []const u8) bool {
    return symbolIn(symbol, &.{ "res.sym", "capa.sym", "ind.sym", "capa-2.sym", "res2.sym" });
}

pub inline fn hasXschemTemplateJfet(symbol: []const u8) bool {
    return symbolIn(symbol, &.{ "njfet.sym", "pjfet.sym" });
}

pub inline fn hasXschemTemplateBjt(symbol: []const u8) bool {
    return symbolIn(symbol, &.{ "npn.sym", "pnp.sym", "npn2.sym", "pnp2.sym" });
}
