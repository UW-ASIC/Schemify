//! gui/Keybinds -- static keybind table and O(log n) binary-search lookup.

pub const Keybind = @import("Keybinds.zig").Keybind;
pub const KeybindAction = @import("Keybinds.zig").KeybindAction;
pub const static_keybinds = @import("Keybinds.zig").static_keybinds;
pub const lookup = @import("Keybinds.zig").lookup;
