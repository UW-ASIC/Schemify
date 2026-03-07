// ==============================================================================
//! Unified FileIO — comptime backend wrapper for schematic I/O.
//!
//! Architecture goal:
//! - one generic `FileIO(Backend)` wrapper
//! - backends are swappable via type parameter (XSchem, Schemify, others)
//! - no separate parallel architecture per backend
//!
//! Required backend surface:
//!   - `readFile(data, alloc, logger) Backend`
//!   - `writeFile(self, alloc, logger) ?[]u8`
//!
//! Optional backend surface:
//!   - `transformComponent(self, req, logger) !void`
//!   - `addComponent(self, comp, pos, logger) !void`
//!   - `removeComponent(self, selector, logger) !void`
//!   - `checkDangling(self, logger) bool`
//!
//! ── Plugin Surface ─────────────────────────────────────────────────────────
//!
//! This is the top-level import for plugin authors. Everything needed to
//! build a PDK loader, custom format backend, or device registry extension
//! is re-exported here:
//!
//!   const FileIO = @import("core/FileIO.zig");
//!
//!   // File operations
//!   const Vfs = FileIO.Vfs;
//!
//!   // Device registry (populate in your loader)
//!   const Registry = FileIO.PdkDeviceRegistry;
//!   const PrimEntry = FileIO.PrimEntry;
//!   const CompEntry = FileIO.CompEntry;
//!
//!   // Device types (for building SpiceDevice templates)
//!   const DeviceKind = FileIO.DeviceKind;
//!   const SpiceDevice = FileIO.SpiceDevice;
//!   const SpiceFormat = FileIO.SpiceFormat;
//!   const LibInclude = FileIO.LibInclude;
//!
//!   // Lookup results
//!   const CellRef = FileIO.CellRef;
//!   const CellTier = FileIO.CellTier;
// ==============================================================================

const std = @import("std");
const log = @import("logger.zig");

// ── Re-exports: filesystem ──────────────────────────────────────────────── //

pub const Vfs = @import("Vfs.zig");

// ── Re-exports: schematic formats ───────────────────────────────────────── //

pub const Logger = log.Logger;
pub const XSchem = @import("xschem.zig").XSchem;
pub const XSchemType = @import("xschem.zig").XSchemType;
pub const sch = @import("schemify.zig");
pub const Schemify = sch.Schemify;

pub const netlist = @import("netlist.zig");
pub const dev = @import("device.zig");
pub const pdk_registry = &dev.global_registry;
pub const PdkDeviceRegistry = dev.PdkDeviceRegistry;
pub const SpiceDevice = dev.SpiceDevice;

// ==============================================================================
// Main Interface
// ==============================================================================

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

pub const ComponentPlacement = struct {
    x: i32,
    y: i32,
};

/// Comptime interface factory. Validates that `Backend` satisfies the required
/// FileIO contract and returns a wrapper around it.
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
        logger: log.Logger,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, path: []const u8, aux_path: ?[]const u8) Self {
            return .{
                .alloc = alloc,
                .path = path,
                .aux_path = aux_path,
                .logger = log.Logger.init(alloc, .info),
            };
        }

        pub fn deinit(self: *Self) void {
            self.logger.deinit();
        }

        pub fn readFile(self: *Self) !Backend {
            const data = try Vfs.readAlloc(self.alloc, self.path);
            defer self.alloc.free(data);
            return Backend.readFile(data, self.alloc, &self.logger);
        }

        pub fn writeFile(self: *Self, data: *Backend) ![]u8 {
            return data.writeFile(self.alloc, &self.logger) orelse error.WriteFailed;
        }

        pub fn transform(self: *Self, data: *Backend, req: TransformRequest) !void {
            if (comptime @hasDecl(Backend, "transformComponent")) {
                try Backend.transformComponent(data, req, &self.logger);
                return;
            }
            return error.UnsupportedOperation;
        }

        pub fn addComponent(self: *Self, data: *Backend, comp: anytype, pos: ComponentPlacement) !void {
            if (comptime @hasDecl(Backend, "addComponent")) {
                try Backend.addComponent(data, comp, pos, &self.logger);
                return;
            }
            return error.UnsupportedOperation;
        }

        pub fn removeComponent(self: *Self, data: *Backend, selector: anytype) !void {
            if (comptime @hasDecl(Backend, "removeComponent")) {
                try Backend.removeComponent(data, selector, &self.logger);
                return;
            }
            return error.UnsupportedOperation;
        }

        pub fn checkDangling(self: *Self, data: *Backend) !bool {
            if (comptime @hasDecl(Backend, "checkDangling")) {
                return Backend.checkDangling(data, &self.logger);
            }
            _ = .{ self, data };
            return error.UnsupportedOperation;
        }
    };
}

// =======================================================
// Usable Interface, allow conversions must be allowed!
// Plugins, are allowed to extend the backward support to other programs and convert them to Schemify
// =======================================================

// Backward-compatible aliases. These are type aliases over the same generic
// architecture (not separate backend-specific implementations).
pub const XSchemIO = FileIO(XSchem);
pub const SchemifyIO = FileIO(Schemify);
