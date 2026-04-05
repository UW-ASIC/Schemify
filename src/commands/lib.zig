//! commands — every schematic mutation is expressed as a Command.
//! Re-exports the public API for external consumers.

const types = @import("types.zig");

// ── Public types ──────────────────────────────────────────────────────────────

pub const Command = types.Command;
pub const Immediate = types.Immediate;
pub const Undoable = types.Undoable;
pub const PlaceDevice = types.PlaceDevice;
pub const DeleteDevice = types.DeleteDevice;
pub const MoveDevice = types.MoveDevice;
pub const SetProp = types.SetProp;
pub const AddWire = types.AddWire;
pub const DeleteWire = types.DeleteWire;
pub const LoadSchematic = types.LoadSchematic;
pub const SaveSchematic = types.SaveSchematic;
pub const RunSim = types.RunSim;
pub const CommandQueue = @import("CommandQueue.zig").CommandQueue;

// ── Dispatch ──────────────────────────────────────────────────────────────────

pub const dispatch = @import("Dispatch.zig").dispatch;

// ── History (undo/redo) ──────────────────────────────────────────────────────

pub const History = @import("Undo.zig").History;
pub const CommandInverse = @import("Undo.zig").CommandInverse;

// ── Tests ─────────────────────────────────────────────────────────────────────

test {
    @import("std").testing.refAllDecls(@This());
}

test "Expose struct size for Command" {
    const print = @import("std").debug.print;
    print("Command:      {d}B\n", .{@sizeOf(Command)});
    print("PlaceDevice:  {d}B\n", .{@sizeOf(PlaceDevice)});
    print("MoveDevice:   {d}B\n", .{@sizeOf(MoveDevice)});
    print("AddWire:      {d}B\n", .{@sizeOf(AddWire)});
}
