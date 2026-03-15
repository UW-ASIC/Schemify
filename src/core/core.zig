//! Core module — public re-export surface for the `core` package.
//!
//! Only names consumed by external importers are listed here.
//! Internal modules not in this list remain package-private.

// ── Filesystem & platform ─────────────────────────────────────────────────── //

pub const Vfs      = @import("Vfs.zig").Vfs;
pub const Platform = @import("Platform.zig");

// ── Logging ──────────────────────────────────────────────────────────────── //

pub const Logger = @import("Logger.zig").Logger;

// ── Schematic model types ─────────────────────────────────────────────────── //

pub const CT           = @import("Types.zig").CT;
pub const Sim          = CT.Sim;
pub const FileType     = CT.FileType;
pub const Tool         = CT.Tool;
pub const CommandFlags = CT.CommandFlags;
pub const ToolState    = CT.ToolState;

// ── Schematic format backends ─────────────────────────────────────────────── //

pub const XSchem     = @import("XSchem.zig").XSchem;
pub const XSchemType = @import("XSchem.zig").XSchemType;
pub const XSchemIO   = @import("FileIO.zig").XSchemIO;

pub const sch      = @import("Schemify.zig");
pub const Schemify = sch.Schemify;

// ── Device registry & netlist ─────────────────────────────────────────────── //

pub const netlist     = @import("Netlist.zig");
pub const dev         = @import("Device.zig");
pub const pdk = &dev.global_pdk;
