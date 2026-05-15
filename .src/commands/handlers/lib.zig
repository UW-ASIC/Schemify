//! handlers — re-exports all command handler functions as top-level names.
//! Dispatch.zig imports this as `h` and calls e.g. `h.handleView(imm, state)`.

const view_mod = @import("View.zig");
const selection_mod = @import("Selection.zig");
const clipboard_mod = @import("Clipboard.zig");
const edit_mod = @import("Edit.zig");
const wire_mod = @import("Wire.zig");
const file_mod = @import("File.zig");
const hierarchy_mod = @import("Hierarchy.zig");
const netlist_mod = @import("Netlist.zig");
const sim_mod = @import("Sim.zig");
const undo_mod = @import("Undo.zig");
const dialog_mod = @import("Dialog.zig");
const config_mod = @import("Config.zig");
const primitive_mod = @import("Primitive.zig");
const import_mod = @import("Import.zig");
const optimize_mod = @import("Optimize.zig");

// ── Error type (union of all handler errors) ─────────────────────────────────

pub const Error = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    Unexpected,
    Full,
};

// ── Re-exported types ────────────────────────────────────────────────────────

pub const History = undo_mod.History;

// ── Re-exported handler functions ────────────────────────────────────────────

// View
pub const handleView = view_mod.handleView;

// Selection
pub const handleSelection = selection_mod.handleSelection;

// Clipboard
pub const handleClipboard = clipboard_mod.handleClipboard;

// Edit (undoable mutations)
pub const handleEdit = edit_mod.handleEdit;

// Wire / Tool / Mode
pub const handleStartWire = wire_mod.handleStartWire;
pub const handleEscapeMode = wire_mod.handleEscapeMode;
pub const handleToolSwitch = wire_mod.handleToolSwitch;

// File / Tab
pub const handleFile = file_mod.handleFile;

// Dialogs
pub const handleDialog = dialog_mod.handleDialog;

// Config
pub const handleConfig = config_mod.handleConfig;

// Hierarchy
pub const handleHierarchy = hierarchy_mod.handleHierarchy;

// Netlist
pub const handleNetlist = netlist_mod.handleNetlist;

// Insert primitive
pub const handleInsertPrimitive = primitive_mod.handleInsertPrimitive;

// Simulation
pub const handleRunSim = sim_mod.handleRunSim;
pub const handleOpenWaveformViewer = sim_mod.handleOpenWaveformViewer;

// Undo / Redo
pub const handleUndo = undo_mod.handleUndo;
pub const handleRedo = undo_mod.handleRedo;
pub const invertCommand = undo_mod.invertCommand;

// Import
pub const handleRunImport = import_mod.handleRunImport;

// Optimize
pub const handleOptimize = optimize_mod.handleOptimize;

test {
    @import("std").testing.refAllDecls(@This());
}
