const std = @import("std");
const types = @import("../types.zig");
const Immediate = types.Immediate;
const simulation = @import("simulation");

pub const Error = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    Unexpected,
    Full,
};

pub fn handleNetlist(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .netlist_hierarchical => {
            generateNetlist(state, .hierarchical, "Hierarchical netlist generated") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        .netlist_top_only => {
            generateNetlist(state, .top_only, "Top-level netlist generated") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        .netlist_flat => {
            generateNetlist(state, .flat, "Flat netlist generated") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        else => {},
    }
}

fn generateNetlist(state: anytype, mode: simulation.Netlist.Mode, ok_msg: []const u8) !void {
    const fio = state.active() orelse return;
    const alloc = state.allocator();

    const spice = try simulation.Netlist.emitPySpiceMode(&fio.sch, alloc, null, state.sim_backend, mode);
    defer alloc.free(spice);

    if (spice.len > state.last_netlist.len) {
        if (state.last_netlist.len > 0) alloc.free(state.last_netlist);
        state.last_netlist = alloc.alloc(u8, spice.len) catch &.{};
    }
    if (state.last_netlist.len >= spice.len) {
        @memcpy(state.last_netlist[0..spice.len], spice);
        state.last_netlist_len = spice.len;
    }
    state.setStatus(ok_msg);
}
