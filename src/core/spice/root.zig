//! SPICE sub-package root.
//!
//! Re-exports key types so consumers can write:
//!
//!   const spice = @import("spice");
//!   var nl = spice.Netlist.init(allocator);
//!   const be = spice.Backend.ngspice;

pub const universal = @import("universal.zig");
pub const bridge = @import("bridge.zig");

pub const Backend = universal.Backend;
pub const Netlist = universal.Netlist;
pub const RunResult = bridge.RunResult;
