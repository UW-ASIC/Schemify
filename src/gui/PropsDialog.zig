//! Instance properties dialog — view and edit component properties.

const std = @import("std");
const dvui = @import("dvui");
const state_mod = @import("state");
const AppState = state_mod.AppState;
const CT = state_mod.CT;
// ── Property row ──────────────────────────────────────────────────────────── //

const PropBuf = struct {
    buf: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,
    dirty: bool = false,
};

// ── Dialog state ──────────────────────────────────────────────────────────── //

pub const PropsDialog = struct {
    open:      bool = false,
    view_only: bool = false,
    inst_idx:  usize = 0,
    /// Heap-allocated per-property edit buffers; grown as needed.
    bufs: std.ArrayListUnmanaged(PropBuf) = .{},
    win_rect: dvui.Rect = .{ .x = 120, .y = 100, .w = 480, .h = 380 },

    pub fn deinit(self: *PropsDialog, alloc: std.mem.Allocator) void {
        self.bufs.deinit(alloc);
    }
};

pub var state: PropsDialog = .{};

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    if (!state.open) return;
    const title = if (state.view_only)
        "Instance Properties (read-only)"
    else
        "Instance Properties";
    // Use floatingWindow directly so we can customise title per view_only flag.
    var fwin = dvui.floatingWindow(@src(), .{
        .modal     = true,
        .open_flag = &state.open,
        .rect      = &state.win_rect,
    }, .{
        .min_size_content = .{ .w = 380, .h = 260 },
    });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader(title, "", &state.open));
    drawContents(app);
}

fn drawContents(app: *AppState) void {
    const fio = app.active();
    const inst_opt: ?CT.Instance = if (fio) |f| blk: {
        const sch = f.schematic();
        if (state.inst_idx < sch.instances.items.len)
            break :blk sch.instances.items[state.inst_idx]
        else
            break :blk null;
    } else null;

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

    const prop_count: usize = if (inst_opt) |inst| inst.props.items.len else 0;

    // Ensure bufs list is large enough.
    const alloc = app.allocator();
    if (state.bufs.items.len < prop_count) {
        state.bufs.resize(alloc, prop_count) catch {};
    }

    if (prop_count == 0) {
        dvui.labelNoFmt(@src(), "(no properties)", .{}, .{ .style = .control });
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    for (0..prop_count) |i| {
        const inst = inst_opt.?;
        const key  = inst.props.items[i].key;

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand   = .horizontal,
            .margin   = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
        });
        defer row.deinit();

        var key_buf: [64]u8 = undefined;
        const key_label = std.fmt.bufPrint(&key_buf, "{s}:", .{key}) catch key;
        dvui.labelNoFmt(@src(), key_label, .{}, .{
            .id_extra         = i * 10 + 1,
            .gravity_y        = 0.5,
            .min_size_content = .{ .w = 130 },
        });

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 }, .id_extra = i * 10 + 2 });

        if (state.view_only) {
            const pb = &state.bufs.items[i];
            const val_slice = pb.buf[0..pb.len];
            dvui.labelNoFmt(@src(), val_slice, .{}, .{
                .id_extra  = i * 10 + 3,
                .expand    = .horizontal,
                .gravity_y = 0.5,
            });
        } else {
            const pb = &state.bufs.items[i];
            var te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = pb.buf[0..127] },
            }, .{
                .id_extra = i * 10 + 3,
                .expand   = .horizontal,
            });
            defer te.deinit();
            pb.len   = std.mem.indexOfScalar(u8, &pb.buf, 0) orelse 127;
            pb.dirty = true;
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
                if (fio) |f| if (inst_opt) |inst| {
                    const pc = @min(inst.props.items.len, state.bufs.items.len);
                    for (0..pc) |i| {
                        const key = inst.props.items[i].key;
                        const pb  = &state.bufs.items[i];
                        const buf_len = std.mem.indexOfScalar(u8, &pb.buf, 0) orelse pb.len;
                        f.setProp(state.inst_idx, key, pb.buf[0..buf_len]) catch {};
                    }
                };
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

// ── Tests ─────────────────────────────────────────────────────────────────── //

test "Expose struct size for props_dialog" {
    const print = @import("std").debug.print;
    print("PropsDialog: {d}B\n", .{@sizeOf(PropsDialog)});
}
