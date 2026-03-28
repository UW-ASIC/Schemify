const std = @import("std");
const ct = @import("convert_types");

pub const ConvertResultList = ct.ConvertResultList;

pub const Backend = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Backend {
        return .{ .alloc = alloc };
    }

    pub fn deinit(_: *Backend) void {}

    pub fn label(_: *const Backend) []const u8 {
        return "Cadence Virtuoso";
    }

    pub fn detectProjectRoot(self: *const Backend, project_dir: []const u8) bool {
        const cds = std.fs.path.join(self.alloc, &.{ project_dir, "cds.lib" }) catch return false;
        defer self.alloc.free(cds);
        std.fs.cwd().access(cds, .{}) catch return false;
        return true;
    }

    pub fn convertProject(
        _: *const Backend,
        _: []const u8,
    ) !ConvertResultList {
        return error.BackendNotImplemented;
    }

    pub fn getFiles(
        _: *const Backend,
        _: []const u8,
    ) !void {
        return error.BackendNotImplemented;
    }
};

pub const Converter = Backend;

pub const OA = @import("oa.zig");
pub const Skill = @import("skill.zig");
