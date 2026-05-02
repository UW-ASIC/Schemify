//! commands — every schematic mutation is expressed as a Command.
//! Re-exports the public API for external consumers.

const types = @import("types.zig");

pub const Command = types.Command;
pub const Immediate = types.Immediate;
pub const Undoable = types.Undoable;
pub const GuiCommand = types.GuiCommand;
pub const PrimitiveKind = types.PrimitiveKind;
pub const SimBackend = types.SimBackend;
pub const PlaceDevice = types.PlaceDevice;
pub const AddWire = types.AddWire;
pub const SetInstanceProp = types.SetInstanceProp;
pub const PluginMutation = types.PluginMutation;
pub const CommandQueue = @import("Queue.zig").CommandQueue;
pub const dispatch = @import("Dispatch.zig").dispatch;
pub const handlers = @import("handlers.zig");
pub const parser = @import("parser.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
