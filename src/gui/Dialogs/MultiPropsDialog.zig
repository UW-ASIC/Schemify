//! Multi-instance properties dialog — batch-edit properties across
//! all selected instances.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const actions = @import("../Actions.zig");

const AppState = st.AppState;
const components = @import("../Components/lib.zig");

pub fn draw(app: *AppState) void {
    const mpd = &app.gui.cold.multi_props_dialog;
    if (!mpd.is_open) return;

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &mpd.is_open,
        .rect = components.winRectPtr(&mpd.win_rect),
    }, .{
        .min_size_content = .{ .w = 520, .h = 360 },
    });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader("Batch Edit Properties", "", &mpd.is_open));

    drawContents(app);
}

fn drawContents(app: *AppState) void {
    const fio = app.active() orelse return;

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
    });
    defer body.deinit();

    if (fio.selection.instances.bit_length == 0) {
        dvui.labelNoFmt(@src(), "No instances selected", .{}, .{ .id_extra = 0 });
        return;
    }

    var sel_count: usize = 0;
    var it = fio.selection.instances.iterator(.{});
    while (it.next()) |_| sel_count += 1;

    {
        var hdr_buf: [64]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "{d} instances selected", .{sel_count}) catch "Selected";
        dvui.labelNoFmt(@src(), hdr, .{}, .{ .id_extra = 1, .style = .control });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 2 });

    var it2 = fio.selection.instances.iterator(.{});
    var id_ctr: u16 = 10;
    while (it2.next()) |idx| {
        if (idx >= fio.sch.instances.len) continue;
        const inst = fio.sch.instances.get(idx);

        {
            var name_buf: [128]u8 = undefined;
            const name_str = std.fmt.bufPrint(&name_buf, "{s} ({s})", .{
                inst.name, inst.symbol,
            }) catch "(instance)";
            dvui.labelNoFmt(@src(), name_str, .{}, .{
                .id_extra = id_ctr,
                .style = .control,
            });
            id_ctr +%= 1;
        }

        const prop_start: usize = inst.prop_start;
        const prop_end: usize = prop_start + inst.prop_count;
        const props = fio.sch.props.items;
        var pi: usize = prop_start;
        while (pi < prop_end and pi < props.len) : (pi += 1) {
            var row_buf: [256]u8 = undefined;
            const row = std.fmt.bufPrint(&row_buf, "    {s} = {s}", .{
                props[pi].key, props[pi].val,
            }) catch "(prop)";
            dvui.labelNoFmt(@src(), row, .{}, .{ .id_extra = id_ctr });
            id_ctr +%= 1;
        }

        _ = dvui.separator(@src(), .{ .id_extra = id_ctr });
        id_ctr +%= 1;

        if (id_ctr > 500) {
            dvui.labelNoFmt(@src(), "... (truncated)", .{}, .{ .id_extra = id_ctr });
            break;
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical });
    _ = dvui.separator(@src(), .{ .id_extra = 900 });

    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 901,
        });
        defer btns.deinit();

        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 902 })) {
            app.gui.cold.multi_props_dialog.is_open = false;
        }
    }
}
