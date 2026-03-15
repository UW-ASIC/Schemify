//! FileIO — comptime backend wrapper for schematic I/O.
//!
//! One generic factory `FileIO(Backend)` validates the required backend surface
//! at compile time and wraps it with uniform read/write/transform methods.
//!
//! Required backend surface:
//!   readFile(data: []const u8, alloc, logger) Backend
//!   writeFile(self, alloc, logger) ?[]u8
//!
//! Optional backend surface (absent → BackendError.UnsupportedOperation):
//!   transformComponent(self, req, logger) !void
//!   addComponent(self, comp, pos, logger) !void
//!   removeComponent(self, selector, logger) !void
//!   checkDangling(self, logger) bool

const std = @import("std");
const log = @import("Logger.zig");
const Vfs = @import("Vfs.zig").Vfs;

const WriteError = error{WriteFailed};
const BackendError = error{UnsupportedOperation};

pub const TransformTarget = union(enum) {
    instance_index: usize,
    instance_name: []const u8,
};

pub const TransformOp = union(enum) {
    move: struct { dx: i32, dy: i32 },
    rotate_cw,
    rotate_ccw,
    flip_x,
    flip_y,
};

pub const TransformRequest = struct {
    target: TransformTarget,
    op: TransformOp,
};

/// Packed x/y pair passed to addComponent so callers need no intermediate struct.
pub const ComponentPlacement = packed struct {
    x: i32,
    y: i32,
};

/// Catch backend contract violations at compile time rather than at first use.
pub fn FileIO(comptime Backend: type) type {
    comptime {
        if (!@hasDecl(Backend, "readFile"))
            @compileError(@typeName(Backend) ++ " missing readFile()");
        if (!@hasDecl(Backend, "writeFile"))
            @compileError(@typeName(Backend) ++ " missing writeFile()");
    }

    return struct {
        alloc: std.mem.Allocator,
        path: []const u8,
        aux_path: ?[]const u8,
        logger: ?*log.Logger = null,

        /// Bind a filesystem path and allocator; no I/O yet.
        pub fn init(alloc: std.mem.Allocator, path: []const u8, aux_path: ?[]const u8) @This() {
            return .{
                .alloc = alloc,
                .path = path,
                .aux_path = aux_path,
            };
        }

        /// Poison the struct in debug builds so use-after-free is caught immediately.
        pub fn deinit(self: *@This()) void {
            self.* = undefined;
        }

        /// Load and parse the bound path; caller owns the returned Backend.
        pub fn readFile(self: *@This()) !Backend {
            const data = try Vfs.readAlloc(self.alloc, self.path);
            defer self.alloc.free(data);
            return Backend.readFile(data, self.alloc, self.logger);
        }

        /// Serialise `data` to bytes; caller owns the returned slice.
        pub fn writeFile(self: *@This(), data: *Backend) WriteError![]u8 {
            return data.writeFile(self.alloc, self.logger) orelse error.WriteFailed;
        }

        /// Apply a geometric transform; gracefully degrades if backend lacks support.
        pub fn transform(self: *@This(), data: *Backend, req: TransformRequest) BackendError!void {
            if (comptime !@hasDecl(Backend, "transformComponent")) return error.UnsupportedOperation;
            Backend.transformComponent(data, req, self.logger) catch return error.UnsupportedOperation;
        }

        /// Insert a component at `pos`; gracefully degrades if backend lacks support.
        pub fn addComponent(self: *@This(), data: *Backend, comp: anytype, pos: ComponentPlacement) BackendError!void {
            if (comptime !@hasDecl(Backend, "addComponent")) return error.UnsupportedOperation;
            Backend.addComponent(data, comp, pos, self.logger) catch return error.UnsupportedOperation;
        }

        /// Remove a component by selector; gracefully degrades if backend lacks support.
        pub fn removeComponent(self: *@This(), data: *Backend, selector: anytype) BackendError!void {
            if (comptime !@hasDecl(Backend, "removeComponent")) return error.UnsupportedOperation;
            Backend.removeComponent(data, selector, self.logger) catch return error.UnsupportedOperation;
        }

        /// Return true if the schematic has wires/pins with no net connection.
        pub fn checkDangling(self: *@This(), data: *Backend) BackendError!bool {
            if (comptime !@hasDecl(Backend, "checkDangling")) return error.UnsupportedOperation;
            return Backend.checkDangling(data, self.logger) catch error.UnsupportedOperation;
        }
    };
}

pub const XSchemIO = FileIO(@import("XSchem.zig").XSchem);
pub const SchemifyIO = FileIO(@import("Schemify.zig").Schemify);

test "Expose struct size for FileIO" {
    const print = std.debug.print;
    print("XSchemIO:            {d}B\n", .{@sizeOf(XSchemIO)});
    print("SchemifyIO:          {d}B\n", .{@sizeOf(SchemifyIO)});
}
