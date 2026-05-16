//! Netlist.zig — Schemify schematic → SPICE netlist generation
//!
//! TODO: This module needs a full rewrite to work with the new StringRef-based
//! schematic types and the removed conn_start/conn_count/conns/nets fields.
//! The netlist generation will be replaced by pyspice.zig in the schematic module.
//! For now, emitSpice and emitPySpice return placeholder output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const schematic = @import("schematic");
const types = schematic.types;
const Property = types.Property;
const Conn = types.Conn;
const Net = types.Net;
const DeviceKind = types.DeviceKind;
const SpiceIF = @import("SpiceIF.zig");
const Devices = schematic.devices.Devices;
const h = schematic.helpers;

// ═════════════════════════════════════════════════════════════════════════════
// Public API
// ═════════════════════════════════════════════════════════════════════════════

/// Emit a SPICE netlist from a Schemify model.
///
/// TODO: Restore full implementation when Connectivity struct is integrated.
/// The old implementation relied on conn_start/conn_count/conns/nets fields
/// which have been removed from Schemify during the StringRef migration.
pub fn emitSpice(
    model: anytype,
    gpa: Allocator,
    pdk: ?*const Devices.Pdk,
) ![]u8 {
    _ = pdk;

    var out = List(u8){};
    errdefer out.deinit(gpa);
    const w = out.writer(gpa);

    const name_str = model.str(model.name);
    try w.print("* Schemify netlist: {s}\n", .{name_str});
    try w.writeAll("* TODO: Netlist generation pending Connectivity integration\n");
    try w.writeAll(".end\n");

    return out.toOwnedSlice(gpa);
}

/// Emit a PySpice Python script from a Schemify model.
///
/// TODO: Restore full implementation when Connectivity struct is integrated.
pub fn emitPySpice(
    model: anytype,
    gpa: Allocator,
    pdk: ?*const Devices.Pdk,
    backend: SpiceIF.Backend,
) ![]u8 {
    _ = pdk;

    var out = List(u8){};
    errdefer out.deinit(gpa);
    const w = out.writer(gpa);

    const name_str = model.str(model.name);
    try w.writeAll("from pyspice_rs import Circuit\n");
    try w.writeAll("from pyspice_rs.unit import *\n\n");
    try w.print("circuit = Circuit('{s}')\n", .{name_str});
    try w.print("# Backend: {s}\n", .{backend.displayName()});
    try w.writeAll("# TODO: Instance emission pending Connectivity integration\n");

    return out.toOwnedSlice(gpa);
}
