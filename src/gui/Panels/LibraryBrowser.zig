//! Library browser — browse and place built-in devices and cells.
//!
//! Layout (floating window):
//!   +-------------------------------------------+
//!   | Library Browser                       [x] |
//!   +-------------------------------------------+
//!   | Built-in Devices                          |
//!   |-------------------------------------------|
//!   | [PAS] resistor           R  2p            |
//!   | [PAS] capacitor          C  2p            |
//!   | [SEM] nmos4              M  4p            |
//!   | ...                                       |
//!   |-------------------------------------------|
//!   | [Place Selected]                  [Close] |
//!   +-------------------------------------------+

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const core = @import("core");
const actions = @import("../Actions.zig");
const components = @import("../Components/lib.zig");

const AppState = st.AppState;
const primitives = core.primitives;

// ── Public API ───────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    if (!app.open_library_browser) return;

    const lb_state = &app.gui.cold.library_browser;

    if (app.rescan_library_browser) {
        lb_state.selected_prim = -1;
        app.rescan_library_browser = false;
    }

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = false,
        .open_flag = &app.open_library_browser,
        .rect = components.winRectPtr(&lb_state.win_rect),
    }, .{
        .min_size_content = .{ .w = 380, .h = 300 },
    });
    defer fwin.deinit();

    fwin.dragAreaSet(dvui.windowHeader("Library Browser", "", &app.open_library_browser));

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
    });
    defer body.deinit();

    // Header.
    dvui.labelNoFmt(@src(), "Built-in Devices", .{}, .{
        .id_extra = 100,
        .style = .control,
        .color_text = .{ .r = 140, .g = 140, .b = 160, .a = 255 },
    });

    _ = dvui.separator(@src(), .{ .id_extra = 101 });

    // Entry list area.
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 102 });
        defer scroll.deinit();

        for (&primitives.parsed_prims, 0..) |*prim, pi| {
            const is_sel = lb_state.selected_prim == @as(i32, @intCast(pi));

            var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = pi * 2,
                .expand = .horizontal,
                .background = true,
                .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
                .color_fill = if (is_sel)
                    dvui.Color{ .r = 45, .g = 95, .b = 175, .a = 255 }
                else
                    dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_fill_hover = .{ .r = 50, .g = 55, .b = 75, .a = 180 },
            });
            defer card.deinit();

            // Category badge.
            const badge = categorizePrim(prim);
            dvui.labelNoFmt(@src(), badge.label, .{}, .{
                .id_extra = pi * 10 + 1,
                .gravity_y = 0.5,
                .color_text = badge.color,
                .min_size_content = .{ .w = 28 },
            });
            _ = dvui.spacer(@src(), .{ .id_extra = pi * 10 + 2, .min_size_content = .{ .w = 4 } });

            // Device name.
            dvui.labelNoFmt(@src(), prim.kind_name, .{}, .{
                .id_extra = pi * 10 + 3,
                .expand = .horizontal,
                .gravity_y = 0.5,
            });

            // Pin count + prefix info.
            var info_buf: [16]u8 = undefined;
            const info = if (prim.prefix != 0)
                std.fmt.bufPrint(&info_buf, "{c} {d}p", .{ prim.prefix, prim.pin_count }) catch ""
            else
                std.fmt.bufPrint(&info_buf, "  {d}p", .{prim.pin_count}) catch "";
            dvui.labelNoFmt(@src(), info, .{}, .{
                .id_extra = pi * 10 + 4,
                .gravity_y = 0.5,
                .color_text = .{ .r = 140, .g = 140, .b = 160, .a = 255 },
            });

            if (dvui.clicked(&card.wd, .{})) {
                if (is_sel) {
                    // Double-click: place immediately.
                    placeSelected(app);
                } else {
                    lb_state.selected_prim = @intCast(pi);
                }
            }
        }
    }

    _ = dvui.separator(@src(), .{ .id_extra = 104 });

    // Bottom buttons.
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 105,
        });
        defer btns.deinit();

        if (dvui.button(@src(), "Place Selected", .{}, .{ .id_extra = 106 })) {
            placeSelected(app);
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 107 });
        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 108 })) {
            app.open_library_browser = false;
        }
    }
}

fn placeSelected(app: *AppState) void {
    const lb_state = &app.gui.cold.library_browser;
    if (lb_state.selected_prim < 0 or @as(usize, @intCast(lb_state.selected_prim)) >= primitives.prim_count) {
        app.status_msg = "Select a device first";
        return;
    }
    const idx = @as(usize, @intCast(lb_state.selected_prim));
    const prim = &primitives.parsed_prims[idx];
    actions.enqueue(app, .{ .undoable = .{ .place_device = .{
        .sym_path = prim.kind_name,
        .name = prim.kind_name,
        .pos = .{ 0, 0 },
    } } }, "Placed device");
}

// ── Badge helpers ────────────────────────────────────────────────────────── //

const BadgeInfo = struct { label: []const u8, color: dvui.Color };

fn categorizePrim(prim: *const primitives.PrimEntry) BadgeInfo {
    const green = dvui.Color{ .r = 120, .g = 210, .b = 120, .a = 255 };
    const blue = dvui.Color{ .r = 120, .g = 160, .b = 230, .a = 255 };
    const yellow = dvui.Color{ .r = 220, .g = 200, .b = 100, .a = 255 };
    const red = dvui.Color{ .r = 220, .g = 120, .b = 120, .a = 255 };
    const gray = dvui.Color{ .r = 160, .g = 160, .b = 180, .a = 255 };

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
