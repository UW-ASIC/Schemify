//! Toolbar + TabBar + CommandBar — all three bars in one file.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const actions = @import("actions.zig");
const command = @import("commands");
const tc = @import("theme_config");

// ── Theme constants ──────────────────────────────────────────────────────────

const bar_bg = dvui.Color{ .r = 24, .g = 26, .b = 34, .a = 255 };
const sep_color = dvui.Color{ .r = 42, .g = 44, .b = 54, .a = 255 };
const muted = dvui.Color{ .r = 136, .g = 144, .b = 160, .a = 255 };
const hint_color = dvui.Color{ .r = 88, .g = 94, .b = 112, .a = 255 };
const err_color = dvui.Color{ .r = 232, .g = 120, .b = 136, .a = 255 };
const cmd_color = dvui.Color{ .r = 180, .g = 190, .b = 254, .a = 255 };

const menu_item_opts: dvui.Options = .{ .expand = .horizontal };

// ══════════════════════════════════════════════════════════════════════════════
//  TOOLBAR (menu bar with hover-reveal dropdowns)
// ══════════════════════════════════════════════════════════════════════════════

pub fn drawToolbar(app: *AppState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal, .min_size_content = .{ .h = 28 },
        .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
        .background = true, .color_fill = bar_bg,
    });
    defer bar.deinit();

    {
        var m = dvui.menu(@src(), .horizontal, .{});
        defer m.deinit();

        drawFileMenu(app);
        drawEditMenu(app);
        drawViewMenu(app);
        drawPlaceMenu(app);
        drawHierarchyMenu(app);
        drawSimulateMenu(app);
        drawPluginsMenu(app);
        drawHelpMenu(app);
    }
}

// ── File ──────────────────────────────────────────────────────────────────

fn drawFileMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "New Schematic", .{}, menu_item_opts) != null) {
            fw.close();
            actions.runGuiCommand(app, .file_new);
        }
        if (dvui.menuItemLabel(@src(), "New Primitive...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_new_prim_dialog }, "New Primitive");
        }
        if (dvui.menuItemLabel(@src(), "Open...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.runGuiCommand(app, .file_open);
        }
        if (dvui.menuItemLabel(@src(), "Reload from Disk", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .reload_from_disk }, "Reloading");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 100 });
        if (dvui.menuItemLabel(@src(), "Save", .{}, menu_item_opts) != null) {
            fw.close();
            actions.runGuiCommand(app, .file_save);
        }
        if (dvui.menuItemLabel(@src(), "Save As...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .file_save_as }, "Save as");
        }
        if (dvui.menuItemLabel(@src(), "Save All", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .file_save_all }, "Saved all");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 101 });
        if (dvui.menuItemLabel(@src(), "Export PDF", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .export_pdf }, "Export PDF");
        }
        if (dvui.menuItemLabel(@src(), "Export PNG", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .export_png }, "Export PNG");
        }
        if (dvui.menuItemLabel(@src(), "Export SVG", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .export_svg }, "Export SVG");
        }
        if (dvui.menuItemLabel(@src(), "Export Netlist", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .export_netlist }, "Export netlist");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 102 });
        if (dvui.menuItemLabel(@src(), "Print...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .print_schematic }, "Print");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 103 });
        if (dvui.menuItemLabel(@src(), "New Tab", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .new_tab }, "New tab");
        }
        if (dvui.menuItemLabel(@src(), "Close Tab", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .close_tab }, "Close tab");
        }
        if (dvui.menuItemLabel(@src(), "Reopen Closed Tab", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .reopen_closed_tab }, "Reopened tab");
        }
    }
}

// ── Edit ──────────────────────────────────────────────────────────────────

fn drawEditMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Undo", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .undo }, "Undo");
        }
        if (dvui.menuItemLabel(@src(), "Redo", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .redo }, "Redo");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 200 });
        if (dvui.menuItemLabel(@src(), "Cut", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .clipboard_cut }, "Cut");
        }
        if (dvui.menuItemLabel(@src(), "Copy", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .clipboard_copy }, "Copied");
        }
        if (dvui.menuItemLabel(@src(), "Paste", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .clipboard_paste }, "Pasted");
        }
        if (dvui.menuItemLabel(@src(), "Delete", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .delete_selected }, "Deleted");
        }
        if (dvui.menuItemLabel(@src(), "Duplicate", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .duplicate_selected }, "Duplicated");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 201 });
        if (dvui.menuItemLabel(@src(), "Select All", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .select_all }, "Select all");
        }
        if (dvui.menuItemLabel(@src(), "Select None", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .select_none }, "Select none");
        }
        if (dvui.menuItemLabel(@src(), "Invert Selection", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .invert_selection }, "Inverted");
        }
        if (dvui.menuItemLabel(@src(), "Find...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .find_select_dialog }, "Find");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 202 });
        if (dvui.menuItemLabel(@src(), "Rotate CW", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .rotate_cw }, "Rotate CW");
        }
        if (dvui.menuItemLabel(@src(), "Rotate CCW", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .rotate_ccw }, "Rotate CCW");
        }
        if (dvui.menuItemLabel(@src(), "Flip Horizontal", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .flip_horizontal }, "Flip H");
        }
        if (dvui.menuItemLabel(@src(), "Flip Vertical", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .flip_vertical }, "Flip V");
        }
        if (dvui.menuItemLabel(@src(), "Align to Grid", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .align_to_grid }, "Aligned");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 203 });
        if (dvui.menuItemLabel(@src(), "Properties...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .edit_properties }, "Properties");
        }
        if (dvui.menuItemLabel(@src(), "Spice Code...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_spice_code_dialog }, "Spice code");
        }
    }
}

// ── View ──────────────────────────────────────────────────────────────────

fn drawViewMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Zoom In", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .zoom_in }, "Zoom in");
        }
        if (dvui.menuItemLabel(@src(), "Zoom Out", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .zoom_out }, "Zoom out");
        }
        if (dvui.menuItemLabel(@src(), "Zoom to Fit", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .zoom_fit }, "Zoom fit");
        }
        if (dvui.menuItemLabel(@src(), "Zoom Reset", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .zoom_reset }, "Zoom reset");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 300 });
        if (dvui.menuItemLabel(@src(), if (app.show_grid) "Hide Grid" else "Show Grid", .{}, menu_item_opts) != null) {
            fw.close();
            app.show_grid = !app.show_grid;
            app.status_msg = if (app.show_grid) "Grid on" else "Grid off";
        }
        if (dvui.menuItemLabel(@src(), if (app.cmd_flags.crosshair) "Hide Crosshair" else "Show Crosshair", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .toggle_crosshair }, "Crosshair");
        }
        if (dvui.menuItemLabel(@src(), if (app.cmd_flags.show_netlist) "Hide Netlist" else "Show Netlist", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .toggle_show_netlist }, "Netlist view");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 301 });
        if (dvui.menuItemLabel(@src(), if (app.cmd_flags.fullscreen) "Exit Fullscreen" else "Fullscreen", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .toggle_fullscreen }, "Fullscreen");
        }
        if (dvui.menuItemLabel(@src(), "Toggle Color Scheme", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .toggle_colorscheme }, "Color scheme");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 302 });
        if (dvui.menuItemLabel(@src(), "Library Browser", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .insert_from_library }, "Library");
        }
        if (dvui.menuItemLabel(@src(), "File Explorer", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_file_explorer }, "Files");
        }
    }
}

// ── Place ─────────────────────────────────────────────────────────────────

fn drawPlaceMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "Place", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Wire", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .start_wire }, "Wire mode");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 400 });
        if (dvui.menuItemLabel(@src(), "Line", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_line }, "Line tool");
        }
        if (dvui.menuItemLabel(@src(), "Rectangle", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_rect }, "Rect tool");
        }
        if (dvui.menuItemLabel(@src(), "Arc", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_arc }, "Arc tool");
        }
        if (dvui.menuItemLabel(@src(), "Circle", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_circle }, "Circle tool");
        }
        if (dvui.menuItemLabel(@src(), "Polygon", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_polygon }, "Polygon tool");
        }
        if (dvui.menuItemLabel(@src(), "Text", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_text }, "Text tool");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 401 });
        if (dvui.menuItemLabel(@src(), "Insert from Library...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .insert_from_library }, "Library");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 402 });

        // Primitives
        const PK = command.PrimitiveKind;
        const prims = .{
            .{ "NMOS", PK.nmos },       .{ "PMOS", PK.pmos },
            .{ "Resistor", PK.resistor }, .{ "Capacitor", PK.capacitor },
            .{ "Inductor", PK.inductor }, .{ "Diode", PK.diode },
            .{ "NPN", PK.npn },           .{ "PNP", PK.pnp },
            .{ "VSource", PK.vsource },   .{ "ISource", PK.isource },
            .{ "GND", PK.gnd },           .{ "VDD", PK.vdd },
        };
        inline for (prims, 0..) |p, pi| {
            if (dvui.menuItemLabel(@src(), p[0], .{}, menu_item_opts.override(.{ .id_extra = 450 + pi })) != null) {
                fw.close();
                actions.enqueue(app, .{ .immediate = .{ .insert_primitive = p[1] } }, p[0]);
            }
        }
    }
}

// ── Hierarchy ─────────────────────────────────────────────────────────────

fn drawHierarchyMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "Hierarchy", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Descend into Schematic", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .descend_schematic }, "Descend");
        }
        if (dvui.menuItemLabel(@src(), "Descend into Symbol", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .descend_symbol }, "Descend symbol");
        }
        if (dvui.menuItemLabel(@src(), "Go Up / Ascend", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .ascend }, "Ascend");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 500 });
        if (dvui.menuItemLabel(@src(), "Edit in New Tab", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .edit_in_new_tab }, "Edit in new tab");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 501 });
        if (dvui.menuItemLabel(@src(), "Make Symbol from Schematic", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .make_symbol_from_schematic }, "Make symbol");
        }
        if (dvui.menuItemLabel(@src(), "Make Schematic from Symbol", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .make_schematic_from_symbol }, "Make schematic");
        }
    }
}

// ── Simulate ──────────────────────────────────────────────────────────────

fn drawSimulateMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "Simulate", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "\xe2\x96\xb6 Run (ngspice)", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .{ .run_sim = .{ .sim = .ngspice } } }, "Sim queued (ngspice)");
        }
        if (dvui.menuItemLabel(@src(), "\xe2\x96\xb6 Run (Xyce)", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .{ .run_sim = .{ .sim = .xyce } } }, "Sim queued (Xyce)");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 600 });
        if (dvui.menuItemLabel(@src(), "Generate Netlist (Hierarchical)", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .netlist_hierarchical }, "Netlist (hierarchical)");
        }
        if (dvui.menuItemLabel(@src(), "Generate Netlist (Flat)", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .netlist_flat }, "Netlist (flat)");
        }
        if (dvui.menuItemLabel(@src(), "Generate Netlist (Top Only)", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .netlist_top_only }, "Netlist (top only)");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 601 });
        if (dvui.menuItemLabel(@src(), "Edit Spice Code...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_spice_code_dialog }, "Spice code");
        }
        if (dvui.menuItemLabel(@src(), "Highlight Selected Nets", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .highlight_selected_nets }, "Nets highlighted");
        }
        if (dvui.menuItemLabel(@src(), "Unhighlight All Nets", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .unhighlight_all }, "Nets cleared");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 602 });
        if (dvui.menuItemLabel(@src(), "Waveform Viewer...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_waveform_viewer }, "Waveform viewer");
        }
    }
}

// ── Plugins ───────────────────────────────────────────────────────────────

fn drawPluginsMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "Plugins", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        const metas = app.gui.cold.plugin_panels_meta.items;
        const states = app.gui.cold.plugin_panels_state.items;
        if (metas.len == 0) {
            dvui.labelNoFmt(@src(), "(no plugins loaded)", .{}, .{ .id_extra = 8000, .color_text = muted, .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 } });
        } else {
            for (metas, 0..) |meta, i| {
                const title = if (meta.title.len > 0) meta.title else meta.id;
                const vis = i < states.len and states[i].visible;
                var buf: [80]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{s}{s}", .{ if (vis) "\xe2\x9c\x93 " else "  ", title }) catch title;
                if (dvui.menuItemLabel(@src(), label, .{}, menu_item_opts.override(.{ .id_extra = 8100 + i })) != null) {
                    if (i < states.len) {
                        app.gui.cold.plugin_panels_state.items[i].visible = !vis;
                    }
                }
            }
        }

        // Plugin commands (non-panel)
        const cmds = app.gui.cold.plugin_commands.items;
        if (cmds.len > 0) {
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 8200 });
            for (cmds, 0..) |cmd, ci| {
                const label = if (cmd.display_name.len > 0) cmd.display_name else cmd.id;
                if (dvui.menuItemLabel(@src(), label, .{}, menu_item_opts.override(.{ .id_extra = 8300 + ci })) != null) {
                    fw.close();
                    actions.enqueue(app, .{ .immediate = .{ .plugin_command = .{ .tag = cmd.id, .payload = null } } }, cmd.display_name);
                }
            }
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 8400 });
        if (dvui.menuItemLabel(@src(), "Reload Plugins", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .plugins_refresh }, "Plugins refreshed");
        }
        if (dvui.menuItemLabel(@src(), "Marketplace...", .{}, menu_item_opts) != null) {
            fw.close();
            app.gui.cold.marketplace.visible = true;
        }
    }
}

// ── Help ──────────────────────────────────────────────────────────────────

fn drawHelpMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "Help", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Keyboard Shortcuts...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .show_keybinds }, "Keybinds");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 700 });
        if (dvui.menuItemLabel(@src(), "Preferences...", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_preferences }, "Preferences");
        }
        if (dvui.menuItemLabel(@src(), "Reload Config", .{}, menu_item_opts) != null) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .reload_config }, "Config reloaded");
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
//  TAB BAR
// ══════════════════════════════════════════════════════════════════════════════

const tab_bg = dvui.Color{ .r = 30, .g = 32, .b = 42, .a = 255 };
const tab_active_bg = dvui.Color{ .r = 45, .g = 48, .b = 62, .a = 255 };
const tab_hover_bg = dvui.Color{ .r = 38, .g = 40, .b = 52, .a = 200 };
const tab_border = dvui.Color{ .r = 55, .g = 58, .b = 72, .a = 255 };
const tab_text = dvui.Color{ .r = 160, .g = 166, .b = 180, .a = 255 };
const tab_text_active = dvui.Color{ .r = 220, .g = 224, .b = 232, .a = 255 };
const tab_dirty = dvui.Color{ .r = 180, .g = 190, .b = 254, .a = 255 };
const tab_close_hover = dvui.Color{ .r = 200, .g = 80, .b = 90, .a = 255 };
const tab_cr = dvui.Rect{ .x = 4, .y = 4, .w = 0, .h = 0 };

pub fn drawTabBar(app: *AppState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal, .min_size_content = .{ .h = 32 },
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 0 },
        .background = true, .color_fill = bar_bg,
    });
    defer bar.deinit();

    for (app.documents.items, 0..) |*doc, idx| {
        const active = idx == @as(usize, app.active_idx);

        // Tab container (name + close grouped together)
        var tab = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 9300 + idx, .gravity_y = 0.5,
            .padding = .{ .x = 10, .y = 0, .w = if (app.documents.items.len > 1) @as(f32, 4) else @as(f32, 10), .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
            .corner_radius = tab_cr,
            .background = true,
            .color_fill = if (active) tab_active_bg else tab_bg,
            .border = if (active) .{ .x = 0, .y = 0, .w = 0, .h = 2 } else .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .color_border = tab_dirty,
        });
        defer tab.deinit();

        // Dirty prefix
        var buf: [80]u8 = undefined;
        const label = if (doc.dirty)
            std.fmt.bufPrint(&buf, "* {s}", .{doc.name}) catch doc.name
        else
            doc.name;

        // Tab name as a button (transparent, no border)
        if (dvui.button(@src(), label, .{}, .{
            .id_extra = 9200 + idx, .gravity_y = 0.5,
            .padding = .{ .x = 0, .y = 5, .w = 0, .h = 5 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .corner_radius = tab_cr,
            .color_fill = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_fill_hover = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (active) tab_text_active else tab_text,
        })) {
            if (!active) {
                app.active_idx = @intCast(idx);
                app.status_msg = "Switched tab";
            }
        }

        // Close button (inside the tab container)
        if (app.documents.items.len > 1) {
            if (dvui.button(@src(), "x", .{}, .{
                .id_extra = 9100 + idx, .gravity_y = 0.5,
                .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
                .corner_radius = dvui.Rect.all(3),
                .color_fill = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_fill_hover = tab_close_hover,
            })) {
                app.active_idx = @intCast(idx);
                actions.enqueue(app, .{ .immediate = .close_tab }, "Close tab");
            }
        }
    }

    // New tab button
    _ = dvui.spacer(@src(), .{ .id_extra = 9050, .min_size_content = .{ .w = 4 } });
    if (dvui.button(@src(), "+", .{}, .{
        .id_extra = 9000, .gravity_y = 0.5,
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        .corner_radius = dvui.Rect.all(3),
        .color_fill = tab_bg, .color_fill_hover = tab_hover_bg,
    }))
        actions.enqueue(app, .{ .immediate = .new_tab }, "New tab");

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // SCH / SYM view-mode toggle
    const sch_active = app.gui.hot.view_mode == .schematic;
    if (dvui.button(@src(), "SCH", .{}, .{
        .id_extra = 9001, .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .corner_radius = dvui.Rect.all(3),
        .style = if (sch_active) .highlight else .control,
    })) actions.runGuiCommand(app, .view_schematic);
    _ = dvui.spacer(@src(), .{ .id_extra = 9003, .min_size_content = .{ .w = 2 } });
    if (dvui.button(@src(), "SYM", .{}, .{
        .id_extra = 9002, .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .corner_radius = dvui.Rect.all(3),
        .style = if (!sch_active) .highlight else .control,
    })) actions.runGuiCommand(app, .view_symbol);
}

// ══════════════════════════════════════════════════════════════════════════════
//  COMMAND BAR
// ══════════════════════════════════════════════════════════════════════════════

const error_prefixes = [_][]const u8{ "Error", "Failed", "No active", "Cannot", "Unknown", "Usage:" };

fn isErrorStatus(msg: []const u8) bool {
    if (std.mem.endsWith(u8, msg, "failed")) return true;
    inline for (error_prefixes) |pfx| {
        if (std.mem.startsWith(u8, msg, pfx)) return true;
    }
    return false;
}

pub fn drawCommandBar(app: *AppState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal, .min_size_content = .{ .h = 22 },
        .padding = .{ .x = 10, .y = 2, .w = 10, .h = 2 },
        .background = true, .color_fill = bar_bg,
    });
    defer bar.deinit();

    if (app.gui.hot.command_mode) {
        var buf: [260]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, ":{s}\xe2\x96\x8c", .{
            app.gui.cold.command_buf[0..app.gui.hot.command_len],
        }) catch ":";
        dvui.labelNoFmt(@src(), cmd, .{}, .{ .id_extra = 5001, .gravity_y = 0.5, .color_text = cmd_color });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 5002 });
        dvui.labelNoFmt(@src(), "Enter to run \xc2\xb7 Esc to cancel", .{}, .{ .id_extra = 5003, .gravity_y = 0.5, .color_text = hint_color });
    } else {
        const msg = app.status_msg;
        const status_col: dvui.Color = if (isErrorStatus(msg)) err_color else dvui.Color{ .r = 220, .g = 224, .b = 232, .a = 255 };
        dvui.labelNoFmt(@src(), msg, .{}, .{ .id_extra = 5010, .expand = .horizontal, .gravity_y = 0.5, .color_text = status_col });

        var snap_buf: [32]u8 = undefined;
        const snap_str = std.fmt.bufPrint(&snap_buf, "snap:{d:.0}", .{app.tool.snap_size}) catch "snap:10";
        dvui.labelNoFmt(@src(), snap_str, .{}, .{ .id_extra = 5011, .gravity_y = 0.5, .color_text = muted });
        dvui.labelNoFmt(@src(), "\xc2\xb7", .{}, .{ .id_extra = 5012, .gravity_y = 0.5, .color_text = sep_color });
        dvui.labelNoFmt(@src(), app.tool.active.label(), .{}, .{ .id_extra = 5013, .gravity_y = 0.5, .color_text = muted });
        dvui.labelNoFmt(@src(), "\xc2\xb7", .{}, .{ .id_extra = 5014, .gravity_y = 0.5, .color_text = sep_color });
        var vbuf: [24]u8 = undefined;
        const view_str = std.fmt.bufPrint(&vbuf, "{s}", .{@tagName(app.gui.hot.view_mode)}) catch "sch";
        dvui.labelNoFmt(@src(), view_str, .{}, .{ .id_extra = 5015, .gravity_y = 0.5, .color_text = muted });
        dvui.labelNoFmt(@src(), "\xc2\xb7", .{}, .{ .id_extra = 5016, .gravity_y = 0.5, .color_text = sep_color });
        dvui.labelNoFmt(@src(), "[ : for commands ]", .{}, .{ .id_extra = 5017, .gravity_y = 0.5, .color_text = hint_color });
    }
}
