//! commands — every schematic mutation is expressed as a Command.
//! Re-exports the public API for external consumers.

const utils = @import("utils/lib.zig");
const handlers = @import("handlers/lib.zig");

// ── Public types ──────────────────────────────────────────────────────────────

pub const Command       = utils.Command;
pub const Immediate     = utils.Immediate;
pub const Undoable      = utils.Undoable;
pub const PlaceDevice   = utils.PlaceDevice;
pub const DeleteDevice  = utils.DeleteDevice;
pub const MoveDevice    = utils.MoveDevice;
pub const SetProp       = utils.SetProp;
pub const AddWire       = utils.AddWire;
pub const DeleteWire    = utils.DeleteWire;
pub const LoadSchematic = utils.LoadSchematic;
pub const SaveSchematic = utils.SaveSchematic;
pub const RunSim        = utils.RunSim;
pub const PrimitiveKind = utils.PrimitiveKind;

// ── Dispatch ──────────────────────────────────────────────────────────────────

pub const dispatch = @import("Dispatch.zig").dispatch;

// ── History (undo/redo) ──────────────────────────────────────────────────────

pub const History        = handlers.undo.History;
pub const CommandInverse = handlers.undo.CommandInverse;

// ── CommandQueue ─────────────────────────────────────────────────────────────

pub const CommandQueue = @import("CommandQueue.zig").CommandQueue;

// ── Tests ─────────────────────────────────────────────────────────────────────

test {
    @import("std").testing.refAllDecls(@This());
}
