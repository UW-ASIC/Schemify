//! Netlist command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const core = @import("core");
const cmd = @import("../command.zig");
const Command = cmd.Command;

var netlist_status_buf: [256]u8 = undefined;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .netlist_hierarchical => {
            const alloc = state.allocator();
            generateNetlistAndStore(state, alloc, "Netlist written to ") catch |err| {
                state.log.err("CMD", "netlist_hierarchical failed: {}", .{err});
                state.setStatusErr("Netlist generation failed");
            };
        },
        .netlist_flat => {
            const alloc = state.allocator();
            generateNetlistAndStore(state, alloc, "Flat netlist written to ") catch |err| {
                state.log.err("CMD", "netlist_flat failed: {}", .{err});
                state.setStatusErr("Flat netlist generation failed");
            };
        },
        .netlist_top_only => {
            const alloc = state.allocator();
            generateNetlistAndStore(state, alloc, "Top-level netlist written to ") catch |err| {
                state.log.err("CMD", "netlist_top_only failed: {}", .{err});
                state.setStatusErr("Top-level netlist generation failed");
            };
        },
        .toggle_flat_netlist => {
            state.cmd_flags.flat_netlist = !state.cmd_flags.flat_netlist;
            state.setStatus(if (state.cmd_flags.flat_netlist) "Flat netlist on (stub)" else "Flat netlist off (stub)");
        },
        else => unreachable,
    }
}

fn generateNetlistAndStore(state: *AppState, alloc: std.mem.Allocator, status_prefix: []const u8) !void {
    const fio = state.active() orelse return error.NoActiveDocument;
    const sch_ct = fio.schematic();

    var s = core.Schemify.init(alloc);
    defer s.deinit();
    s.name = sch_ct.name;

    for (sch_ct.instances.items) |inst| {
        const prop_start: u32 = @intCast(s.props.items.len);
        for (inst.props.items) |p| {
            s.props.append(s.alloc(), .{
                .key = s.alloc().dupe(u8, p.key) catch p.key,
                .val = s.alloc().dupe(u8, p.val) catch p.val,
            }) catch {};
        }
        s.instances.append(s.alloc(), .{
            .name       = s.alloc().dupe(u8, inst.name)   catch inst.name,
            .symbol     = s.alloc().dupe(u8, inst.symbol) catch inst.symbol,
            .x          = inst.pos.x,
            .y          = inst.pos.y,
            .rot        = inst.xform.rot,
            .flip       = inst.xform.flip,
            .kind       = .unknown,
            .prop_start = prop_start,
            .prop_count = @intCast(s.props.items.len - prop_start),
            .conn_start = 0,
            .conn_count = 0,
        }) catch {};
    }
    for (sch_ct.wires.items) |wire| {
        s.wires.append(s.alloc(), .{
            .x0       = wire.start.x,
            .y0       = wire.start.y,
            .x1       = wire.end.x,
            .y1       = wire.end.y,
            .net_name = if (wire.net_name) |n| s.alloc().dupe(u8, n) catch null else null,
        }) catch {};
    }

    var unf = try core.netlist.UniversalNetlistForm.fromSchemify(alloc, &s);
    defer unf.deinit();
    const spice = try unf.generateSpice(alloc, core.pdk_registry);
    defer alloc.free(spice);

    var sp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sp_path = std.fmt.bufPrint(&sp_path_buf, "{s}/{s}.sp", .{ state.project_dir, sch_ct.name }) catch sch_ct.name;
    std.fs.cwd().writeFile(.{ .sub_path = sp_path, .data = spice }) catch |err| {
        state.log.err("CMD", "failed to write netlist to {s}: {}", .{ sp_path, err });
    };

    const copy_len = @min(spice.len, state.last_netlist.len);
    @memcpy(state.last_netlist[0..copy_len], spice[0..copy_len]);
    state.last_netlist_len = copy_len;

    const status = std.fmt.bufPrint(&netlist_status_buf, "{s}{s}.sp", .{ status_prefix, sch_ct.name }) catch "Netlist written";
    state.setStatus(status);
}
