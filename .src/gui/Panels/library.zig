//! Library browser — browse and place built-in devices.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const core = @import("core");
const theme = @import("theme_config");
const actions = @import("../actions.zig");

const AppState = st.AppState;
const primitives = core.devices.primitives;

pub fn draw(app: *AppState) void {
    if (!app.open_library_browser) return;
    const lb = &app.gui.cold.library_browser;

    if (app.rescan_library_browser) { lb.selected_prim = -1; app.rescan_library_browser = false; }

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = false, .open_flag = &app.open_library_browser, .rect = @ptrCast(&lb.win_rect),
    }, .{ .min_size_content = .{ .w = 380, .h = 300 } });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader("Library Browser", "", &app.open_library_browser));

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 } });
    defer body.deinit();

    dvui.labelNoFmt(@src(), "Built-in Devices", .{}, .{ .id_extra = 100, .style = .control, .color_text = theme.chromeTextSecondary() });
    _ = dvui.separator(@src(), .{ .id_extra = 101 });

    // Entry list
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 102 });
        defer scroll.deinit();

        for (&primitives.parsed_prims, 0..) |*prim, pi| {
            const is_sel = lb.selected_prim == @as(i32, @intCast(pi));
            var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = pi * 2, .expand = .horizontal, .background = true,
                .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
                .color_fill = if (is_sel) blk: { const a = theme.chromeAccent(); break :blk dvui.Color{ .r = a.r / 4, .g = a.g / 4, .b = a.b / 2, .a = 255 }; } else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_fill_hover = theme.chromeHoverBg(),
            });
            defer card.deinit();

            const badge = categorizePrim(prim);
            dvui.labelNoFmt(@src(), badge.label, .{}, .{ .id_extra = pi * 10 + 1, .gravity_y = 0.5, .color_text = badge.color, .min_size_content = .{ .w = 28 } });
            _ = dvui.spacer(@src(), .{ .id_extra = pi * 10 + 2, .min_size_content = .{ .w = 4 } });
            dvui.labelNoFmt(@src(), prim.kind_name, .{}, .{ .id_extra = pi * 10 + 3, .expand = .horizontal, .gravity_y = 0.5 });

            var ib: [16]u8 = undefined;
            const info = if (prim.prefix != 0)
                std.fmt.bufPrint(&ib, "{c} {d}p", .{ prim.prefix, prim.pin_count }) catch ""
            else
                std.fmt.bufPrint(&ib, "  {d}p", .{prim.pin_count}) catch "";
            dvui.labelNoFmt(@src(), info, .{}, .{ .id_extra = pi * 10 + 4, .gravity_y = 0.5, .color_text = theme.chromeTextSecondary() });

            if (dvui.clicked(&card.wd, .{})) {
                if (is_sel) placeSelected(app) else lb.selected_prim = @intCast(pi);
            }
        }
    }

    _ = dvui.separator(@src(), .{ .id_extra = 104 });

    // Buttons
    var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 105 });
    defer btns.deinit();
    if (dvui.button(@src(), "Place Selected", .{}, .{ .id_extra = 106 })) placeSelected(app);
    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 107 });
    if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 108 })) app.open_library_browser = false;
}

fn placeSelected(app: *AppState) void {
    const lb = &app.gui.cold.library_browser;
    if (lb.selected_prim < 0 or @as(usize, @intCast(lb.selected_prim)) >= primitives.prim_count) {
        app.status_msg = "Select a device first";
        return;
    }
    const prim = &primitives.parsed_prims[@intCast(lb.selected_prim)];
    const pos = app.gui.hot.canvas.cursor_world;

    actions.enqueue(app, .{ .undoable = .{ .place_device = .{
        .sym_path = prim.kind_name, .name = prim.kind_name, .x = pos[0], .y = pos[1],
    } } }, "Placed device");
}

const BadgeInfo = struct { label: []const u8, color: dvui.Color };

fn categorizePrim(prim: *const primitives.PrimEntry) BadgeInfo {
    const green = dvui.Color{ .r = 125, .g = 196, .b = 160, .a = 255 };
    const blue = dvui.Color{ .r = 122, .g = 162, .b = 247, .a = 255 };
    const yellow = dvui.Color{ .r = 212, .g = 184, .b = 106, .a = 255 };
    const red = dvui.Color{ .r = 212, .g = 112, .b = 112, .a = 255 };
    const gray = dvui.Color{ .r = 122, .g = 126, .b = 140, .a = 255 };

    if (prim.non_electrical) return .{ .label = "PWR", .color = red };
    return switch (prim.prefix) {
        'R', 'C', 'L' => .{ .label = "PAS", .color = green },
        'M', 'Q', 'J' => .{ .label = "SEM", .color = blue },
        'D' => .{ .label = "DIO", .color = blue },
        'V', 'I', 'B' => .{ .label = "SRC", .color = yellow },
        'E', 'G', 'H', 'F' => .{ .label = "CTL", .color = yellow },
        'S', 'W' => .{ .label = "SW ", .color = gray },
        'O', 'K' => .{ .label = "TLN", .color = gray },
        else => .{ .label = "---", .color = gray },
    };
}
