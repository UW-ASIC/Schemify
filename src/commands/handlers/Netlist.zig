const std = @import("std");
const types = @import("../types.zig");
const Immediate = types.Immediate;

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
            state.setStatus("Generating hierarchical netlist...");
            generateNetlist(state, "Netlist written") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        .netlist_top_only => {
            state.setStatus("Generating top-level netlist...");
            generateNetlist(state, "Top-level netlist written") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        .netlist_flat => {
            state.setStatus("Generating flat netlist...");
            generateNetlist(state, "Flat netlist written") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        else => {},
    }
}

fn generateNetlist(state: anytype, ok_msg: []const u8) !void {
    const fio = state.active() orelse return;
    const alloc = state.allocator();

    const spice = try fio.createNetlist();
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
