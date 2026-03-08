//! Simulation command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const cmd = @import("../command.zig");
const Command = cmd.Command;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .run_sim => |p| {
            const fio = state.active() orelse return;
            const path = fio.createNetlist(p.sim) catch {
                state.setStatusErr("Netlist generation failed");
                return;
            };
            defer state.allocator().free(path);
            fio.runSpiceSim(p.sim, path);
            state.setStatus("Simulation started");
        },
        .open_waveform_viewer => state.setStatus("Open waveform viewer (stub)"),
        else => unreachable,
    }
}
