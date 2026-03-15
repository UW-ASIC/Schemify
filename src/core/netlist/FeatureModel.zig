//! FeatureModel — data types, public structs, and private supporting structs
//! for the Netlister subsystem.
//!
//! This file owns all shared types that cross module boundaries within the
//! netlist/ package.  It has no non-trivial logic; it is a pure data layer.

const std = @import("std");
const sch = @import("../Schemify.zig");

// ── Wire / device geometry ────────────────────────────────────────────────── //

pub const WireSeg = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    net_name: ?[]const u8,
    bus: bool = false,
};

pub const DeviceRef = struct {
    name: []const u8,
    symbol: []const u8,
    kind: sch.DeviceKind = .unknown,
    x: i32,
    y: i32,
    rot: u2,
    flip: bool,
    prop_start: u32,
    prop_count: u16,
    format: ?[]const u8 = null,
    sym_template: ?[]const u8 = null,
};

pub const DeviceProp = struct {
    key: []const u8,
    value: []const u8,
};

pub const PinRef = struct {
    name: []const u8,
    dir: sch.PinDir,
};

pub const DeviceNet = struct {
    device_idx: u32,
    pin_name: []const u8,
    net_id: u32,
};

// ── Symbol type classification maps ──────────────────────────────────────── //

/// Symbol types that produce X-subcircuit SPICE lines.
pub const subckt_type_map = std.StaticStringMap(void).initComptime(.{
    .{ "subcircuit", {} }, .{ "primitive", {} }, .{ "opamp", {} },
    .{ "ic", {} },         .{ "gate", {} },      .{ "generic", {} },
    .{ "regulator", {} },  .{ "esd", {} },       .{ "crystal", {} },
    .{ "uc", {} },         .{ "transmission_line", {} }, .{ "missing", {} },
    .{ "i2c_eprom", {} },
});

/// Symbol types that are explicitly NOT subcircuits (wires, ports, code blocks…).
pub const non_subckt_type_map = std.StaticStringMap(void).initComptime(.{
    .{ "netlist_commands", {} }, .{ "label", {} },          .{ "use", {} },
    .{ "package", {} },          .{ "port_attributes", {} }, .{ "arch_declarations", {} },
    .{ "attributes", {} },       .{ "spice_parameters", {} }, .{ "lcc_iopin", {} },
    .{ "lcc_ipin", {} },         .{ "lcc_opin", {} },         .{ "switch", {} },
    .{ "delay", {} },            .{ "nmos", {} },             .{ "pmos", {} },
    .{ "npn", {} },              .{ "pnp", {} },              .{ "diode", {} },
    .{ "noconn", {} },           .{ "and", {} },              .{ "inv", {} },
    .{ "nand", {} },             .{ "nand3", {} },            .{ "buff", {} },
    .{ "notif0", {} },           .{ "ao21", {} },             .{ "or", {} },
    .{ "xor", {} },              .{ "xnor", {} },             .{ "not", {} },
    .{ "coupler", {} },          .{ "ipin", {} },             .{ "opin", {} },
    .{ "iopin", {} },
});

/// XSchem-internal prop keys skipped when building subcircuit instance parameters.
pub const xschem_skip_map = std.StaticStringMap(void).initComptime(.{
    .{ "name", {} },            .{ "lab", {} },              .{ "pinnumber", {} },
    .{ "pintype", {} },         .{ "pinnamesvisible", {} },  .{ "savecurrent", {} },
    .{ "spice_ignore", {} },    .{ "program", {} },          .{ "tclcommand", {} },
    .{ "device_model", {} },    .{ "verilog_ignore", {} },   .{ "vhdl_ignore", {} },
    .{ "xvalue", {} },          .{ "current", {} },          .{ "conduct", {} },
    .{ "val", {} },             .{ "only_toplevel", {} },    .{ "format", {} },
    .{ "template", {} },        .{ "schematic", {} },        .{ "sig_type", {} },
    .{ "comm", {} },            .{ "verilog_type", {} },     .{ "xschematic", {} },
    .{ "xspice_sym_def", {} },  .{ "spice_sym_def", {} },    .{ "xdefault_schematic", {} },
});

// ── Bus range ─────────────────────────────────────────────────────────────── //

pub const BusRange = struct {
    prefix: []const u8,
    hi: i32,
    lo: i32,
    suffix: []const u8,
};
