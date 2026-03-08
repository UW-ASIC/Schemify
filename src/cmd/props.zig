//! Properties command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const cmd = @import("../command.zig");
const Command = cmd.Command;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .edit_properties => {
            state.setStatus("Edit properties (stub)");
        },
        .view_properties => {
            state.setStatus("View properties (stub)");
        },
        .edit_schematic_metadata => state.setStatus("(stub — use CLI :rename)"),
        else => unreachable,
    }
}
