//! Simulation submodule — SPICE IR, netlist generation, PySpice bridge.

pub const SpiceIF = @import("SpiceIF.zig");
pub const Netlist = @import("Netlist.zig");
pub const RawFile = @import("RawFile.zig");
pub const VerilogNetlist = @import("VerilogNetlist.zig");
pub const results = @import("results.zig");

comptime {
    _ = SpiceIF;
    _ = Netlist;
    _ = results;
}
