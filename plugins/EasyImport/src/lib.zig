//! Multi-backend import bridge entry point.
//!
//! Backend modules are built separately and imported directly here.
//! This file exposes the EasyImport facade and the backend union.

const std = @import("std");
const XSchem = @import("xschem");
const Virtuoso = @import("virtuoso");
const ct = @import("convert_types");

pub const ConvertResult = ct.ConvertResult;
pub const ConvertResultList = ct.ConvertResultList;

pub const BackendKind = enum(u8) {
    xschem,
    virtuoso,
};

pub const BackendUnion = union(BackendKind) {
    xschem: XSchem.Backend,
    virtuoso: Virtuoso.Backend,

    comptime {
        const required_decls = .{
            "init",
            "deinit",
            "label",
            "detectProjectRoot",
            "convertProject",
            "getFiles",
        };
        for (required_decls) |name| {
            if (!@hasDecl(XSchem.Backend, name))
                @compileError("XSchem.Backend missing required method: " ++ name);
            if (!@hasDecl(Virtuoso.Backend, name))
                @compileError("Virtuoso.Backend missing required method: " ++ name);
        }
    }
};

pub const EasyImport = struct {
    alloc: std.mem.Allocator,
    project_path: []const u8,
    backend: BackendUnion,

    pub fn init(alloc: std.mem.Allocator, project_path: []const u8, backend: BackendKind) EasyImport {
        return .{
            .alloc = alloc,
            .project_path = project_path,
            .backend = switch (backend) {
                .xschem => .{ .xschem = XSchem.Backend.init(alloc) },
                .virtuoso => .{ .virtuoso = Virtuoso.Backend.init(alloc) },
            },
        };
    }

    pub fn label(self: *const EasyImport) []const u8 {
        return switch (self.backend) {
            inline else => |*b| b.label(),
        };
    }

    pub fn convertProject(self: *const EasyImport) !ConvertResultList {
        return switch (self.backend) {
            inline else => |*b| b.convertProject(self.project_path),
        };
    }

    pub fn getFiles(self: *const EasyImport) !XSchem.FileList {
        return switch (self.backend) {
            .xschem => |*b| b.getFiles(self.project_path),
            .virtuoso => error.BackendNotImplemented,
        };
    }
};
