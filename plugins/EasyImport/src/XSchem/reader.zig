// reader.zig - XSchem .sch/.sym file parser with tag-dispatch line parsing.
//
// Parses all XSchem element types (L, B, P, A, T, N, C) into the DOD Schematic
// container. K-block properties (type, format, template) extracted for .sym files.
// Multi-line property blocks handled via brace_depth tracking.
// Strict error returns on malformed input per D-06.
//
// Written from scratch per D-01; old XSchem.zig consulted as behavioral reference
// only per D-02.

const std = @import("std");
const types = @import("types.zig");
const props_mod = @import("props.zig");
const root = @import("root.zig");

const Schematic = root.Schematic;
const ParseError = types.ParseError;

/// Parse an XSchem .sch or .sym file from raw bytes into a Schematic.
/// All allocations go into the Schematic's arena.
/// Returns error on malformed input per D-06.
pub fn parse(backing: std.mem.Allocator, data: []const u8) ParseError!Schematic {
    _ = data;
    _ = backing;
    // Stub - TDD RED phase: this must fail tests
    return error.UnexpectedEof;
}
