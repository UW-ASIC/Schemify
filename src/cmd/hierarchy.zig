//! Hierarchy command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const cmd = @import("../command.zig");
const Command = cmd.Command;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .descend_schematic => state.setStatus("Descend into schematic (stub)"),
        .descend_symbol => state.setStatus("Descend into symbol (stub)"),
        .ascend => state.setStatus("Ascend to parent (stub)"),
        .edit_in_new_tab => state.setStatus("Edit in new tab (stub)"),
        .make_symbol_from_schematic => state.setStatus("Make symbol from schematic (stub)"),
        .make_schematic_from_symbol => state.setStatus("Make schematic from symbol (stub)"),
        .make_schem_and_sym => state.setStatus("Make both schematic and symbol (stub)"),
        .insert_from_library => state.setStatus("Insert from library (stub)"),
        else => unreachable,
    }
}
