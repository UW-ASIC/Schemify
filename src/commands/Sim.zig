//! Simulation command handlers.

const cmd     = @import("command.zig");
const Immediate = cmd.Immediate;
const RunSim    = cmd.RunSim;

pub const Error = error{};

pub fn handleImmediate(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .open_waveform_viewer => state.setStatus("Open waveform viewer (stub)"),
        else => unreachable,
    }
}

pub fn handleRun(p: RunSim, state: anytype) Error!void {
    const fio  = state.active() orelse return;
    const path = fio.createNetlist(p.sim) catch {
        state.setStatusErr("Netlist generation failed");
        return;
    };
    defer state.allocator().free(path);
    fio.runSpiceSim(p.sim, path);
    state.setStatus("Simulation started");
}
