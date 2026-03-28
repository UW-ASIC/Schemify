// convert_types.zig - Shared conversion result types for all EasyImport backends.

const std = @import("std");
const core = @import("core");

/// A single converted schematic from any import backend.
pub const ConvertResult = struct {
    name: []const u8,
    sch_path: ?[]const u8,
    sym_path: ?[]const u8,
    schemify: core.Schemify,
};

/// Owning list of ConvertResults returned by Backend.convertProject.
pub const ConvertResultList = struct {
    results: []ConvertResult,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ConvertResultList) void {
        for (self.results) |*r| {
            r.schemify.deinit();
        }
        self.arena.deinit();
    }
};
