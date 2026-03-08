//! Find / select dialog — search instances by name or symbol.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
const actions = @import("actions.zig");

// ── Local state ───────────────────────────────────────────────────────────── //

pub const State = struct {
    open: bool = false,
    query: [128]u8 = [_]u8{0} ** 128,
    query_len: usize = 0,
    results: [64]usize = [_]usize{0} ** 64,
    result_count: usize = 0,
};

pub var state: State = .{};

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    if (!state.open) return;

    var fw = dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{ .w = 320, .h = 200 } });
    defer fw.deinit();

    dvui.labelNoFmt(@src(), "Find / Select", .{}, .{ .style = .highlight });

    {
        var query_buf: [130]u8 = undefined;
        const query_text = std.fmt.bufPrint(&query_buf, "{s}", .{state.query[0..state.query_len]}) catch "";
        dvui.labelNoFmt(@src(), query_text, .{}, .{});
    }

    {
        var count_buf: [64]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d} match(es)", .{state.result_count}) catch "?";
        dvui.labelNoFmt(@src(), count_text, .{}, .{ .id_extra = 1 });
    }

    if (dvui.button(@src(), "Select All Matches", .{}, .{})) {
        const fio = app.active() orelse { state.open = false; return; };
        const sch = fio.schematic();
        const alloc = app.allocator();
        app.selection.clear();
        for (sch.instances.items, 0..) |inst, i| {
            const matches = std.mem.indexOf(u8, inst.name, state.query[0..state.query_len]) != null or
                std.mem.indexOf(u8, inst.symbol, state.query[0..state.query_len]) != null;
            if (matches) {
                app.selection.instances.resize(alloc, i + 1, false) catch continue;
                app.selection.instances.set(i);
            }
        }
        state.open = false;
    }

    if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 1 })) {
        state.open = false;
    }
}

// ── Private helpers ───────────────────────────────────────────────────────── //

pub fn runFindQuery(app: *AppState) void {
    const fio = app.active() orelse return;
    const sch = fio.schematic();
    const query = state.query[0..state.query_len];
    state.result_count = 0;
    for (sch.instances.items, 0..) |inst, i| {
        if (std.mem.indexOf(u8, inst.name, query) != null or
            std.mem.indexOf(u8, inst.symbol, query) != null)
        {
            if (state.result_count < state.results.len) {
                state.results[state.result_count] = i;
                state.result_count += 1;
            }
        }
    }
    app.setStatus("Find: results updated");
}
