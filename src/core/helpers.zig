//! helpers.zig — Shared helper functions for the core module.
//!
//! These functions were previously duplicated in Writer.zig and Netlist.zig.

const std = @import("std");
const types = @import("types.zig");
const Prop = types.Prop;

/// Find a value in a slice of Prop by key.
pub fn findSymProp(props: []const Prop, key: []const u8) ?[]const u8 {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.val;
    }
    return null;
}

/// Returns true for instance prop keys that are XSchem-internal structural fields
/// and should never appear in the Schemify instances output.
/// These are already encoded as named fields (name, sym, x, y, rot, flip) or are
/// EDA-tool-specific metadata with no meaning in Schemify.
pub fn isInstanceStructuralProp(key: []const u8) bool {
    // Already written as named fields
    if (std.mem.eql(u8, key, "name")) return true;
    if (std.mem.eql(u8, key, "sym")) return true;
    if (std.mem.eql(u8, key, "x")) return true;
    if (std.mem.eql(u8, key, "y")) return true;
    if (std.mem.eql(u8, key, "rot")) return true;
    if (std.mem.eql(u8, key, "flip")) return true;
    // XSchem symbol format metadata — not user parameters
    if (std.mem.eql(u8, key, "format")) return true;
    if (std.mem.eql(u8, key, "template")) return true;
    if (std.mem.eql(u8, key, "type")) return true;
    if (std.mem.eql(u8, key, "schematic")) return true;
    // Net/label keys — expressed via wires, not instance props
    if (std.mem.eql(u8, key, "lab")) return true;
    if (std.mem.eql(u8, key, "net")) return true;
    // XSchem SPICE-generation keys — used internally for netlist but not user params
    if (std.mem.eql(u8, key, "device_model")) return true;
    return false;
}

/// Returns true for keys that are emitted as dedicated lines/sections, not as params.
pub fn isSymPropMetadata(key: []const u8) bool {
    return std.mem.eql(u8, key, "description") or
        std.mem.eql(u8, key, "spice_prefix") or
        std.mem.eql(u8, key, "spice_format") or
        std.mem.eql(u8, key, "spice_lib") or
        std.mem.startsWith(u8, key, "include") or
        std.mem.startsWith(u8, key, "ann.") or
        std.mem.startsWith(u8, key, "analysis.") or
        std.mem.startsWith(u8, key, "measure.");
}
