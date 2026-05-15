//! Devices submodule — device catalog and primitive symbol definitions.

pub const Devices = @import("Devices.zig");
pub const primitives = @import("primitives.zig");

comptime {
    _ = Devices;
    _ = primitives;
}
