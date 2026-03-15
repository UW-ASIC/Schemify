//! Find / select dialog — search instances by name or symbol.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("state").AppState;
const components = @import("components/root.zig");

const FindWindow = components.FloatingWindow(.{
    .title = "Find / Select",
    .min_w = 320,
    .min_h = 200,
    .modal = false,
});

// ── Dialog state ───────────────────────────────────────────────────────────── //

const FindState = struct {
    open:    bool = false,
    query:   std.BoundedArray(u8, 128) = .{},
    results: std.ArrayListUnmanaged(usize) = .{},
};

var state: FindState = .{};
var win_rect = dvui.Rect{ .x = 80, .y = 80, .w = 340, .h = 220 };

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn open(app: *AppState) void {
    state.open      = true;
    state.query.len = 0;
    state.results.clearRetainingCapacity();
    _ = app; // future: could pre-search here
}

pub fn deinit(alloc: std.mem.Allocator) void {
    state.results.deinit(alloc);
}

pub fn draw(app: *AppState) void {
    FindWindow.draw(&win_rect, &state.open, drawContents, app);
}

fn drawContents(app: *AppState) void {
    // ── Search input — rerun filter on change ────────────────────────────── //
    {
        const prev_len = state.query.len;
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = state.query.buffer[0..127] },
        }, .{ .expand = .horizontal });
        defer te.deinit();
        state.query.len = @intCast(std.mem.indexOfScalar(u8, &state.query.buffer, 0) orelse 127);

        if (state.query.len != prev_len) {
            if (app.active()) |fio| {
                const sch   = fio.schematic();
                const query = state.query.slice();
                state.results.clearRetainingCapacity();
                for (sch.instances.items, 0..) |inst, i| {
                    if (std.ascii.indexOfIgnoreCase(inst.name,   query) != null or
                        std.ascii.indexOfIgnoreCase(inst.symbol, query) != null)
                    {
                        state.results.append(app.allocator(), i) catch {};
                    }
                }
                app.setStatus("Find: results updated");
            }
        }
    }

    // ── Match count ───────────────────────────────────────────────────────── //
    {
        var count_buf: [64]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d} match(es)", .{state.results.items.len})
            catch "?";
        dvui.labelNoFmt(@src(), count_text, .{}, .{ .id_extra = 1 });
    }

    // ── Result list ───────────────────────────────────────────────────────── //
    if (state.results.items.len > 0) {
        const fio = app.active() orelse { state.open = false; return; };
        const sch = fio.schematic();
        for (state.results.items, 0..) |idx, i| {
            if (idx >= sch.instances.items.len) continue;
            const inst = sch.instances.items[idx];
            var row_buf: [128]u8 = undefined;
            const row_text = std.fmt.bufPrint(&row_buf, "{s} ({s})", .{ inst.name, inst.symbol })
                catch inst.name;
            dvui.labelNoFmt(@src(), row_text, .{}, .{ .id_extra = @intCast(i + 10) });
        }
    }

    // ── Buttons ───────────────────────────────────────────────────────────── //
    if (dvui.button(@src(), "Select All Matches", .{}, .{})) {
        const fio = app.active() orelse { state.open = false; return; };
        const sch   = fio.schematic();
        const alloc = app.allocator();
        const query = state.query.slice();
        app.selection.clear();
        for (sch.instances.items, 0..) |inst, i| {
            const matches =
                std.ascii.indexOfIgnoreCase(inst.name,   query) != null or
                std.ascii.indexOfIgnoreCase(inst.symbol, query) != null;
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
