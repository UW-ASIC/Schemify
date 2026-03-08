//! Plugin command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const cmd = @import("../command.zig");
const Command = cmd.Command;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .plugins_refresh => state.plugin_refresh_requested = true,
        .plugin_command => |p| {
            state.log.info("CMD", "plugin command: {s}", .{p.tag});
        },
        else => unreachable,
    }
}
