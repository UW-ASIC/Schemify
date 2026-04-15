//! handlers — re-exports all command handler modules.

pub const view      = @import("View.zig");
pub const selection = @import("Selection.zig");
pub const clipboard = @import("Clipboard.zig");
pub const edit      = @import("Edit.zig");
pub const wire      = @import("Wire.zig");
pub const file      = @import("File.zig");
pub const hierarchy = @import("Hierarchy.zig");
pub const netlist   = @import("Netlist.zig");
pub const sim       = @import("Sim.zig");
pub const undo      = @import("Undo.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
