//! Netlist generation handlers.

const core = @import("core");
const h = @import("helpers.zig");
const Error = h.Error;
const Immediate = h.Immediate;

const NetlistMode = core.Schemify.NetlistMode;

pub fn handleNetlist(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .netlist_hierarchical => {
            state.setStatus("Generating hierarchical netlist...");
            generateNetlist(state, .hierarchical, "Netlist written") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        .netlist_top_only => {
            state.setStatus("Generating top-level netlist...");
            generateNetlist(state, .top_only, "Top-level netlist written") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        .netlist_flat => {
            state.setStatus("Generating flat netlist...");
            generateNetlist(state, .flat, "Flat netlist written") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        else => {},
    }
}

fn generateNetlist(state: anytype, mode: NetlistMode, ok_msg: []const u8) !void {
    const fio = state.active() orelse return;
    const alloc = state.allocator();

    const spice = try fio.createNetlistWithMode(.ngspice, mode);
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
