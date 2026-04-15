//! utils — shared helpers and command types.

pub const helpers = @import("helpers.zig");
pub const command = @import("command.zig");
pub const types  = @import("types.zig");

// Re-export commonly used helpers directly
pub const selInst    = helpers.selInst;
pub const selWire    = helpers.selWire;
pub const ptEq       = helpers.ptEq;
pub const setBit     = helpers.setBit;
pub const toggleFlag = helpers.toggleFlag;

// Re-export command types
pub const Command      = command.Command;
pub const Immediate    = command.Immediate;
pub const Undoable     = command.Undoable;
pub const PlaceDevice  = command.PlaceDevice;
pub const DeleteDevice = command.DeleteDevice;
pub const MoveDevice   = command.MoveDevice;
pub const SetProp      = command.SetProp;
pub const AddWire      = command.AddWire;
pub const DeleteWire   = command.DeleteWire;
pub const LoadSchematic = command.LoadSchematic;
pub const SaveSchematic = command.SaveSchematic;
pub const RunSim       = command.RunSim;
pub const PrimitiveKind = command.PrimitiveKind;

test {
    @import("std").testing.refAllDecls(@This());
}
