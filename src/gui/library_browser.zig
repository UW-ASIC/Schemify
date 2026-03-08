//! Library browser — browse and place symbols from the symbol library.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
const actions = @import("actions.zig");

// ── Local state ───────────────────────────────────────────────────────────── //

pub const State = struct {
    open: bool = false,
    search_buf: [128]u8 = [_]u8{0} ** 128,
    search_len: usize = 0,
    entries: [256][256]u8 = [_][256]u8{[_]u8{0} ** 256} ** 256,
    entry_count: usize = 0,
    selected: i32 = -1,
    win_rect: dvui.Rect = .{ .x = 100, .y = 80, .w = 420, .h = 460 },
};

pub var state: State = .{};

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    var fwin = dvui.floatingWindow(@src(), .{
        .modal     = true,
        .open_flag = &state.open,
        .rect      = &state.win_rect,
    }, .{
        .min_size_content = .{ .w = 320, .h = 360 },
    });
    defer fwin.deinit();

    fwin.dragAreaSet(dvui.windowHeader("Library Browser", "", &state.open));

    {
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand  = .both,
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
        });
        defer body.deinit();

        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            dvui.labelNoFmt(@src(), "Search:", .{}, .{ .gravity_y = 0.5 });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 } });
            var te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = state.search_buf[0..127] },
            }, .{ .expand = .horizontal });
            defer te.deinit();
            state.search_len = std.mem.indexOfScalar(u8, &state.search_buf, 0) orelse 0;
        }

        _ = dvui.separator(@src(), .{ .id_extra = 1 });

        if (state.entry_count == 0) {
            dvui.labelNoFmt(@src(), "No .chn_sym files found in symbols/", .{}, .{ .style = .control });
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        const search_text = state.search_buf[0..state.search_len];

        for (0..state.entry_count) |i| {
            const entry_name = std.mem.sliceTo(&state.entries[i], 0);

            if (search_text.len > 0) {
                var found = false;
                if (entry_name.len >= search_text.len) {
                    var si: usize = 0;
                    while (si + search_text.len <= entry_name.len) : (si += 1) {
                        var match = true;
                        for (search_text, 0..) |sc, j| {
                            if (std.ascii.toLower(entry_name[si + j]) != std.ascii.toLower(sc)) {
                                match = false;
                                break;
                            }
                        }
                        if (match) { found = true; break; }
                    }
                }
                if (!found) continue;
            }

            const is_selected = state.selected == @as(i32, @intCast(i));

            var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra   = i,
                .expand     = .horizontal,
                .background = true,
                .border     = .{ .x = 1, .y = 1, .w = 1, .h = 1 },
                .padding    = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
                .margin     = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
                .color_fill = if (is_selected)
                    .{ .r = 38, .g = 52, .b = 90, .a = 255 }
                else
                    .{ .r = 36, .g = 36, .b = 42, .a = 0 },
            });
            defer card.deinit();

            dvui.labelNoFmt(@src(), entry_name, .{}, .{
                .id_extra  = i * 10 + 1,
                .expand    = .horizontal,
                .gravity_y = 0.5,
            });

            if (dvui.button(@src(), "Select", .{}, .{ .id_extra = i * 10 + 2 })) {
                state.selected = @intCast(i);
            }
        }

        _ = dvui.separator(@src(), .{ .id_extra = 20 });

        {
            var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
            });
            defer btn_row.deinit();

            _ = dvui.spacer(@src(), .{ .expand = .horizontal });

            if (dvui.button(@src(), "Place", .{}, .{ .id_extra = 200, .style = .highlight })) {
                if (state.selected >= 0 and @as(usize, @intCast(state.selected)) < state.entry_count) {
                    const sel_idx: usize = @intCast(state.selected);
                    const sym_name = std.mem.sliceTo(&state.entries[sel_idx], 0);
                    app.queue.push(.{ .place_device = .{
                        .sym_path = sym_name,
                        .name     = sym_name,
                        .x        = 0,
                        .y        = 0,
                    } }) catch {};
                    app.setStatus("Symbol placed");
                    state.open = false;
                } else {
                    app.setStatus("No symbol selected");
                }
            }

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });

            if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = 201 })) {
                state.open = false;
                app.setStatus("Library browser closed");
            }
        }
    }
}
