//! Netlist command handlers.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const utility = @import("utility");
const Vfs = utility.Vfs;
const Immediate = @import("../utils/command.zig").Immediate;

pub const Error = error{
    NoActiveDocument,
    OutOfMemory,
    Overflow,
    NoSpaceLeft,
    UnsupportedFeature,
    YosysNotFound,
    InvalidCharacter,
    InvalidAnalysis,
};

/// Module-level buffer so the status string outlives the stack frame
/// (state.setStatus borrows the slice rather than copying).
var netlist_status_buf: [256]u8 = undefined;

const NetlistInfo = struct { prefix: []const u8, err_msg: []const u8 };

/// Check whether `yosys` is available in PATH.
fn yosysAvailable() bool {
    if (comptime builtin.target.cpu.arch == .wasm32) return false;
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{"yosys", "--version"},
    }) catch return false;
    std.heap.page_allocator.free(result.stdout);
    std.heap.page_allocator.free(result.stderr);
    return true;
}

/// Shared netlist write + status update logic.
fn writeNetlist(
    s: *core.Schemify,
    spice: []u8,
    mode: core.NetlistMode,
    info: NetlistInfo,
    state: anytype,
) void {
    const alloc = state.allocator();
    const suffix: []const u8 = if (mode == .layout) "_layout" else "";

    var sp_path_buf: [1024]u8 = undefined;
    const sp_path = std.fmt.bufPrint(&sp_path_buf, "{s}/{s}{s}.sp", .{
        state.project_dir, s.name, suffix,
    }) catch s.name;
    Vfs.writeAll(sp_path, spice) catch |err|
        state.log.err("CMD", "failed to write netlist to {s}: {}", .{ sp_path, err });

    if (spice.len > state.last_netlist.len) {
        if (state.last_netlist.len > 0) alloc.free(state.last_netlist);
        state.last_netlist = alloc.alloc(u8, spice.len) catch blk: {
            state.last_netlist_len = 0;
            break :blk &.{};
        };
    }
    if (state.last_netlist.len >= spice.len) {
        @memcpy(state.last_netlist[0..spice.len], spice);
        state.last_netlist_len = spice.len;
    }

    const status = std.fmt.bufPrint(&netlist_status_buf, "{s}{s}{s}.sp", .{
        info.prefix, s.name, suffix,
    }) catch info.err_msg;
    state.setStatus(status);
}

/// Build a Schemify from the active document's instances and wires.
fn buildSchemify(state: anytype) !struct { s: core.Schemify } {
    const fio = state.active() orelse return error.NoActiveDocument;
    const sch_ct = fio.sch;
    const alloc = state.allocator();

    var s = core.Schemify.init(alloc);
    errdefer s.deinit();
    s.name = sch_ct.name;

    for (0..sch_ct.instances.len) |idx| {
        const inst = sch_ct.instances.get(idx);
        const prop_start: u32 = @intCast(s.props.items.len);
        const src_props = sch_ct.props.items[inst.prop_start..][0..inst.prop_count];
        for (src_props) |p| {
            s.props.append(s.alloc(), .{
                .key = s.alloc().dupe(u8, p.key) catch p.key,
                .val = s.alloc().dupe(u8, p.val) catch p.val,
            }) catch {};
        }
        s.instances.append(s.alloc(), .{
            .name       = s.alloc().dupe(u8, inst.name)   catch inst.name,
            .symbol     = s.alloc().dupe(u8, inst.symbol) catch inst.symbol,
            .x          = inst.x, .y = inst.y,
            .rot        = inst.rot, .flip = inst.flip,
            .kind       = .unknown,
            .prop_start = prop_start,
            .prop_count = @intCast(s.props.items.len - prop_start),
            .conn_start = 0, .conn_count = 0,
        }) catch {};
    }
    for (0..sch_ct.wires.len) |idx| {
        const wire = sch_ct.wires.get(idx);
        s.wires.append(s.alloc(), .{
            .x0 = wire.x0, .y0 = wire.y0,
            .x1 = wire.x1, .y1 = wire.y1,
            .net_name = if (wire.net_name) |n| s.alloc().dupe(u8, n) catch null else null,
        }) catch {};
    }

    s.resolveNets();
    return .{ .s = s };
}

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .netlist_hierarchical,
        .netlist_flat,
        .netlist_top_only,
        => {
            const info = NetlistInfo{
                .prefix = switch (imm) {
                    .netlist_hierarchical => "Netlist written to ",
                    .netlist_flat         => "Flat netlist written to ",
                    .netlist_top_only     => "Top-level netlist written to ",
                    else => unreachable,
                },
                .err_msg = "Netlist generation failed",
            };

            var result = try buildSchemify(state);
            defer result.s.deinit();
            const spice = try result.s.emitSpice(state.allocator(), .ngspice, core.pdk, .sim);
            defer state.allocator().free(spice);
            writeNetlist(&result.s, spice, .sim, info, state);
        },

        .netlist_hierarchical_layout,
        .netlist_flat_layout,
        .netlist_top_only_layout,
        => {
            if (!yosysAvailable()) {
                state.setStatus("TODO: Yosys not found in PATH — install Yosys for layout netlists");
                return error.YosysNotFound;
            }

            const info = NetlistInfo{
                .prefix = switch (imm) {
                    .netlist_hierarchical_layout => "Layout netlist written to ",
                    .netlist_flat_layout         => "Flat layout netlist written to ",
                    .netlist_top_only_layout     => "Top-level layout netlist written to ",
                    else => unreachable,
                },
                .err_msg = "Layout netlist failed — run Yosys synthesis first",
            };

            var result = try buildSchemify(state);
            defer result.s.deinit();

            const spice = try result.s.emitSpice(state.allocator(), .ngspice, core.pdk, .layout);
            defer state.allocator().free(spice);
            writeNetlist(&result.s, spice, .layout, info, state);
        },

        .toggle_flat_netlist => {
            state.cmd_flags.flat_netlist = !state.cmd_flags.flat_netlist;
            state.setStatus(if (state.cmd_flags.flat_netlist) "Flat netlist on" else "Flat netlist off");
        },
        else => unreachable,
    }
}
