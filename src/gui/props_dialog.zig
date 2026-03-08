//! Instance properties dialog — view and edit component properties.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
const actions = @import("actions.zig");

// ── Local state ───────────────────────────────────────────────────────────── //

pub const State = struct {
    open: bool = false,
    view_only: bool = false,
    inst_idx: usize = 0,
    bufs: [16][128]u8 = [_][128]u8{[_]u8{0} ** 128} ** 16,
    lens: [16]usize = [_]usize{0} ** 16,
    dirty: [16]bool = [_]bool{false} ** 16,
    win_rect: dvui.Rect = .{ .x = 120, .y = 100, .w = 480, .h = 380 },
};

pub var state: State = .{};

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    var fwin = dvui.floatingWindow(@src(), .{
        .modal     = true,
        .open_flag = &state.open,
        .rect      = &state.win_rect,
    }, .{
        .min_size_content = .{ .w = 380, .h = 260 },
    });
    defer fwin.deinit();

    const title = if (state.view_only) "Instance Properties (read-only)" else "Instance Properties";
    fwin.dragAreaSet(dvui.windowHeader(title, "", &state.open));

    const fio = app.active();
    const CT = @import("../state.zig").CT;
    const inst_opt: ?CT.Instance = if (fio) |f| blk: {
        const sch = f.schematic();
        if (state.inst_idx < sch.instances.items.len)
            break :blk sch.instances.items[state.inst_idx]
        else
            break :blk null;
    } else null;

    {
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand  = .both,
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
        });
        defer body.deinit();

        if (inst_opt) |inst| {
            var hdr_buf: [256]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "Symbol: {s}  Name: {s}", .{ inst.symbol, inst.name })
                catch inst.name;
            dvui.labelNoFmt(@src(), hdr, .{}, .{ .style = .control });
            _ = dvui.separator(@src(), .{ .id_extra = 1 });
        }

        const prop_count: usize = if (inst_opt) |inst|
            @min(inst.props.items.len, 16)
        else
            0;

        if (prop_count == 0) {
            dvui.labelNoFmt(@src(), "(no properties)", .{}, .{ .style = .control });
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        for (0..prop_count) |i| {
            const inst = inst_opt.?;
            const key = inst.props.items[i].key;

            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i,
                .expand   = .horizontal,
                .margin   = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
            });
            defer row.deinit();

            var key_buf: [64]u8 = undefined;
            const key_label = std.fmt.bufPrint(&key_buf, "{s}:", .{key}) catch key;
            dvui.labelNoFmt(@src(), key_label, .{}, .{
                .id_extra          = i * 10 + 1,
                .gravity_y         = 0.5,
                .min_size_content  = .{ .w = 130 },
            });

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 }, .id_extra = i * 10 + 2 });

            if (state.view_only) {
                const val_slice = state.bufs[i][0..state.lens[i]];
                dvui.labelNoFmt(@src(), val_slice, .{}, .{
                    .id_extra  = i * 10 + 3,
                    .expand    = .horizontal,
                    .gravity_y = 0.5,
                });
            } else {
                var te = dvui.textEntry(@src(), .{
                    .text = .{ .buffer = state.bufs[i][0..127] },
                }, .{
                    .id_extra = i * 10 + 3,
                    .expand   = .horizontal,
                });
                defer te.deinit();
                state.lens[i] = std.mem.indexOfScalar(u8, &state.bufs[i], 0) orelse 127;
                state.dirty[i] = true;
            }
        }

        _ = dvui.separator(@src(), .{ .id_extra = 50 });
        {
            var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
            });
            defer btn_row.deinit();

            _ = dvui.spacer(@src(), .{ .expand = .horizontal });

            if (!state.view_only) {
                if (dvui.button(@src(), "OK", .{}, .{ .id_extra = 100, .style = .highlight })) {
                    if (fio) |f| {
                        if (inst_opt) |inst| {
                            const pc = @min(inst.props.items.len, 16);
                            for (0..pc) |i| {
                                const key = inst.props.items[i].key;
                                const buf_len = std.mem.indexOfScalar(u8, &state.bufs[i], 0) orelse state.lens[i];
                                const val = state.bufs[i][0..buf_len];
                                f.setProp(state.inst_idx, key, val) catch {};
                            }
                        }
                    }
                    app.setStatus("Properties updated");
                    state.open = false;
                }
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });
            }

            if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = 101 })) {
                state.open = false;
                app.setStatus("Properties canceled");
            }
        }
    }
}
