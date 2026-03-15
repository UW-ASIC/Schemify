// src/core/netlist.zig — thin re-export shim for backward compatibility.
//
// The full implementation lives in netlist/root.zig.
// All callers that import @import("netlist.zig") continue to work unchanged.

const root = @import("netlist/root.zig");

pub const DeviceProp          = root.DeviceProp;
pub const DeviceNet           = root.DeviceNet;
pub const Netlister           = root.Netlister;
pub const UniversalNetlistForm = root.UniversalNetlistForm;
pub const GenerateNetlist     = root.GenerateNetlist;
pub const isPortSymbol        = root.isPortSymbol;
