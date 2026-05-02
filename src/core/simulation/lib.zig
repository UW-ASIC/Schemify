//! Simulation submodule — SPICE IR, netlist generation, backend dispatch.

pub const SpiceIF = @import("SpiceIF.zig");
pub const Netlist = @import("Netlist.zig");
pub const backend = @import("backend/lib.zig");

comptime {
    _ = SpiceIF;
    _ = Netlist;
    _ = backend;
}
