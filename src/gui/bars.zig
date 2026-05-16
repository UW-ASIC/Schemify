const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const st = @import("state");
const simulation = @import("simulation");
const AppState = st.AppState;
const actions = @import("actions.zig");
const command = @import("commands");
const tc = @import("theme_config");
const helpers = @import("helpers.zig");

const is_wasm = builtin.cpu.arch == .wasm32;

// ── Theme color accessors ────────────────────────────────────────────────────

fn bar_bg() dvui.Color {
    return tc.chromeToolbarBg();
}
fn sep_col() dvui.Color {
    return tc.chromeSeparator();
}
fn text_muted() dvui.Color {
    return tc.chromeTextSecondary();
}
fn accent_col() dvui.Color {
    return tc.chromeAccent();
}

const hint_color = dvui.Color{ .r = 88, .g = 94, .b = 112, .a = 255 };
const err_color = dvui.Color{ .r = 232, .g = 120, .b = 136, .a = 255 };

const menu_item_opts: dvui.Options = .{ .expand = .horizontal };

// ── Menu item with shortcut hint ─────────────────────────────────────────────

fn menuItemSC(src: std.builtin.SourceLocation, label: []const u8, shortcut: []const u8) bool {
    var mi = dvui.menuItem(src, .{}, .{ .expand = .horizontal });
    const labelopts = mi.style().strip().override(.{ .label = .{ .for_id = mi.data().id } });
    const activated = mi.activeRect() != null;

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    dvui.labelNoFmt(@src(), label, .{}, labelopts);

    if (shortcut.len > 0) {
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        dvui.labelNoFmt(@src(), shortcut, .{}, .{
            .color_text = text_muted(),
            .padding = .{ .x = 16, .y = 0, .w = 0, .h = 0 },
        });
    }
    hbox.deinit();

    mi.deinit();
    return activated;
}

// ── Menu item with toggle checkmark ──────────────────────────────────────────

fn menuItemToggle(src: std.builtin.SourceLocation, label: []const u8, shortcut: []const u8, active: bool) bool {
    var mi = dvui.menuItem(src, .{}, .{ .expand = .horizontal });
    const labelopts = mi.style().strip().override(.{ .label = .{ .for_id = mi.data().id } });
    const activated = mi.activeRect() != null;

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    const prefix: []const u8 = if (active) " * " else "   ";
    dvui.labelNoFmt(@src(), prefix, .{}, labelopts);
    dvui.labelNoFmt(@src(), label, .{}, labelopts);

    if (shortcut.len > 0) {
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        dvui.labelNoFmt(@src(), shortcut, .{}, .{
            .color_text = text_muted(),
            .padding = .{ .x = 16, .y = 0, .w = 0, .h = 0 },
        });
    }
    hbox.deinit();

    mi.deinit();
    return activated;
}

// ══════════════════════════════════════════════════════════════════════════════
//  TOOLBAR (menu bar with hover-reveal dropdowns)
// ══════════════════════════════════════════════════════════════════════════════

pub fn drawToolbar(app: *AppState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 28 },
        .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
        .background = true,
        .color_fill = bar_bg(),
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

    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 1100 });
    if (dvui.button(@src(), "Chat", .{}, .{
        .id_extra = 1101,
        .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .corner_radius = dvui.Rect.all(3),
        .style = if (app.gui.cold.chat_panel.visible) .highlight else .control,
    })) {
        app.gui.cold.chat_panel.visible = !app.gui.cold.chat_panel.visible;
    }
}

// ── File ──────────────────────────────────────────────────────────────────

fn drawFileMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (menuItemSC(@src(), "New Schematic", "Ctrl+N")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .file_new }, "New file");
        }
        if (menuItemSC(@src(), "New Primitive...", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_new_prim_dialog }, "New Primitive");
        }
        if (menuItemSC(@src(), "Open...", "Ctrl+O")) {
            fw.close();
            actions.runGuiCommand(app, .file_open);
        }
        if (menuItemSC(@src(), "Import Project...", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_import_project }, "Import");
        }
        if (menuItemSC(@src(), "Reload from Disk", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .reload_from_disk }, "Reloading");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 100 });
        if (menuItemSC(@src(), "Save", "Ctrl+S")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .file_save }, "Saving...");
        }
        if (menuItemSC(@src(), "Save As...", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .file_save_as }, "Save as");
        }
        if (menuItemSC(@src(), "Save All", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .file_save_all }, "Saved all");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 101 });
        if (menuItemSC(@src(), "Export SVG", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .export_svg }, "Export SVG");
        }
        if (menuItemSC(@src(), "Export Netlist", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .export_netlist }, "Export netlist");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 103 });
        if (menuItemSC(@src(), "New Tab", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .new_tab }, "New tab");
        }
        if (menuItemSC(@src(), "Close Tab", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .close_tab }, "Close tab");
        }
        if (menuItemSC(@src(), "Reopen Closed Tab", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .reopen_closed_tab }, "Reopened tab");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 104 });
        if (menuItemSC(@src(), "Quit", "")) {
            fw.close();
            actions.runVimCommand(app, "quit");
        }
    }
}

// ── Edit ──────────────────────────────────────────────────────────────────

fn drawEditMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (menuItemSC(@src(), "Undo", "Ctrl+Z")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .undo }, "Undo");
        }
        if (menuItemSC(@src(), "Redo", "Ctrl+Y")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .redo }, "Redo");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 200 });
        if (menuItemSC(@src(), "Cut", "Ctrl+X")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .clipboard_cut }, "Cut");
        }
        if (menuItemSC(@src(), "Copy", "Ctrl+C")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .clipboard_copy }, "Copied");
        }
        if (menuItemSC(@src(), "Paste", "Ctrl+V")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .clipboard_paste }, "Pasted");
        }
        if (menuItemSC(@src(), "Delete", "Del")) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .delete_selected }, "Deleted");
        }
        if (menuItemSC(@src(), "Duplicate", "")) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .duplicate_selected }, "Duplicated");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 201 });
        if (menuItemSC(@src(), "Select All", "Ctrl+A")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .select_all }, "Select all");
        }
        if (menuItemSC(@src(), "Select None", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .select_none }, "Select none");
        }
        if (menuItemSC(@src(), "Invert Selection", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .invert_selection }, "Inverted");
        }
        if (menuItemSC(@src(), "Find...", "Ctrl+F")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .find_select_dialog }, "Find");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 202 });
        if (menuItemSC(@src(), "Rotate CW", "R")) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .rotate_cw }, "Rotate CW");
        }
        if (menuItemSC(@src(), "Rotate CCW", "Shift+R")) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .rotate_ccw }, "Rotate CCW");
        }
        if (menuItemSC(@src(), "Flip Horizontal", "X")) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .flip_horizontal }, "Flip H");
        }
        if (menuItemSC(@src(), "Flip Vertical", "Shift+X")) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .flip_vertical }, "Flip V");
        }
        if (menuItemSC(@src(), "Align to Grid", "")) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .align_to_grid }, "Aligned");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 203 });
        if (menuItemSC(@src(), "Properties...", "Q")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .edit_properties }, "Properties");
        }
        if (menuItemSC(@src(), "Spice Code...", "")) {
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

        if (menuItemSC(@src(), "Zoom In", "Ctrl+=")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .zoom_in }, "Zoom in");
        }
        if (menuItemSC(@src(), "Zoom Out", "Ctrl+-")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .zoom_out }, "Zoom out");
        }
        if (menuItemSC(@src(), "Zoom to Fit", "F")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .zoom_fit }, "Zoom fit");
        }
        if (menuItemSC(@src(), "Zoom Reset", "Ctrl+0")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .zoom_reset }, "Zoom reset");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 300 });
        if (menuItemToggle(@src(), "Grid", "G", app.show_grid)) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .toggle_grid }, "Grid");
        }
        if (menuItemToggle(@src(), "Crosshair", "", app.cmd_flags.crosshair)) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .toggle_crosshair }, "Crosshair");
        }
        if (menuItemToggle(@src(), "Netlist View", "", app.cmd_flags.show_netlist)) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .toggle_show_netlist }, "Netlist view");
        }
        if (menuItemToggle(@src(), "Fill Shapes", "", app.cmd_flags.fill_rects)) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .toggle_fill_rects }, "Fill shapes");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 301 });
        if (menuItemSC(@src(), "Library Browser", "Ins")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .insert_from_library }, "Library");
        }
        if (menuItemSC(@src(), "File Explorer", "")) {
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

        if (menuItemSC(@src(), "Wire", "W")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .start_wire }, "Wire mode");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 400 });
        if (menuItemSC(@src(), "Line", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_line }, "Line tool");
        }
        if (menuItemSC(@src(), "Rectangle", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_rect }, "Rect tool");
        }
        if (menuItemSC(@src(), "Arc", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_arc }, "Arc tool");
        }
        if (menuItemSC(@src(), "Circle", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_circle }, "Circle tool");
        }
        if (menuItemSC(@src(), "Polygon", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_polygon }, "Polygon tool");
        }
        if (menuItemSC(@src(), "Text", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .tool_text }, "Text tool");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 401 });
        if (menuItemSC(@src(), "Insert from Library...", "Ins")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .insert_from_library }, "Library");
        }
    }
}

// ── Hierarchy ─────────────────────────────────────────────────────────────

fn drawHierarchyMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "Hierarchy", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (menuItemSC(@src(), "Descend into Schematic", "E")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .descend_schematic }, "Descend");
        }
        if (menuItemSC(@src(), "Descend into Symbol", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .descend_symbol }, "Descend symbol");
        }
        if (menuItemSC(@src(), "Go Up / Ascend", "Backspace")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .ascend }, "Ascend");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 500 });
        if (menuItemSC(@src(), "Edit in New Tab", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .edit_in_new_tab }, "Edit in new tab");
        }
    }
}

// ── Backend probing ──────────────────────────────────────────────────────

fn probeBackend(bin: []const u8) bool {
    var child = std.process.Child.init(&.{ bin, "--version" }, std.heap.page_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    _ = child.wait() catch return false;
    return true;
}

fn probeAllBackends() st.BackendAvailability {
    return .{
        .ngspice = probeBackend("ngspice"),
        .xyce = probeBackend("Xyce"),
        .ltspice = false, // Windows-only, not probeable on Linux
        .spectre = probeBackend("spectre"),
        .vacask = false, // Not yet publicly available
        .probed = true,
    };
}

// ── Simulate ──────────────────────────────────────────────────────────────

fn drawSimulateMenu(app: *AppState) void {
    if (dvui.menuItemLabel(@src(), "Simulate", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (menuItemSC(@src(), "> Run Simulation", "F5")) {
            fw.close();
            actions.enqueue(app, .{ .undoable = .{ .run_sim = .{} } }, "Simulation queued");
        }

        // Backend selector submenu
        if (dvui.menuItemLabel(@src(), "Backend", .{ .submenu = true }, menu_item_opts.override(.{ .id_extra = 605 }))) |br| {
            var bfw = dvui.floatingMenu(@src(), .{ .from = br }, .{});
            defer bfw.deinit();

            // Lazily probe for installed backends on first open
            if (comptime !is_wasm) {
                if (!app.backend_avail.probed) {
                    app.backend_avail = probeAllBackends();
                }
            }

            const backends = [_]simulation.SpiceIF.Backend{ .ngspice, .xyce, .ltspice, .spectre, .vacask };
            for (backends, 0..) |be, bi| {
                const active = app.sim_backend == be;
                const avail = app.backend_avail.isAvailable(be);
                var lbl_buf: [48]u8 = undefined;
                const prefix: []const u8 = if (active) "* " else "  ";
                const suffix: []const u8 = if (!avail) " (n/a)" else "";
                const lbl = std.fmt.bufPrint(&lbl_buf, "{s}{s}{s}", .{ prefix, be.displayName(), suffix }) catch be.displayName();
                if (dvui.menuItemLabel(@src(), lbl, .{}, menu_item_opts.override(.{ .id_extra = 610 + bi })) != null) {
                    if (avail) {
                        bfw.close();
                        app.sim_backend = be;
                    }
                }
            }
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 600 });
        if (menuItemSC(@src(), "Generate Netlist (Hierarchical)", "N")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .netlist_hierarchical }, "Netlist (hierarchical)");
        }
        if (menuItemSC(@src(), "Generate Netlist (Flat)", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .netlist_flat }, "Netlist (flat)");
        }
        if (menuItemSC(@src(), "Generate Netlist (Top Only)", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .netlist_top_only }, "Netlist (top only)");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 601 });
        if (menuItemSC(@src(), "Edit Spice Code...", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_spice_code_dialog }, "Spice code");
        }
        if (menuItemSC(@src(), "Highlight Selected Nets", "K")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .highlight_selected_nets }, "Nets highlighted");
        }
        if (menuItemSC(@src(), "Unhighlight All Nets", "Ctrl+K")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .unhighlight_all }, "Nets cleared");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 602 });
        if (menuItemSC(@src(), "Waveform Viewer...", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_waveform_viewer }, "Waveform viewer");
        }
        if (menuItemSC(@src(), "Optimize Sizing...", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .run_optimize }, "Optimize");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 603 });
        if (menuItemSC(@src(), "Clear Simulation Cache", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .clear_sim_cache }, "Clear cache");
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
            dvui.labelNoFmt(@src(), "(no plugins loaded)", .{}, .{ .id_extra = 8000, .color_text = text_muted(), .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 } });
        } else {
            for (metas, 0..) |meta, i| {
                const title = if (meta.title.len > 0) meta.title else meta.id;
                const vis = i < states.len and states[i].visible;
                var buf: [80]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{s}{s}", .{ if (vis) "* " else "  ", title }) catch title;
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
        if (menuItemSC(@src(), "Reload Plugins", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .plugins_refresh }, "Plugins refreshed");
        }
        if (menuItemSC(@src(), "Marketplace...", "")) {
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

        if (menuItemSC(@src(), "Keyboard Shortcuts...", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .show_keybinds }, "Keybinds");
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 700 });
        if (menuItemSC(@src(), "Preferences...", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .open_preferences }, "Preferences");
        }
        if (menuItemSC(@src(), "Reload Config", "")) {
            fw.close();
            actions.enqueue(app, .{ .immediate = .reload_config }, "Config reloaded");
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
//  TAB BAR
// ══════════════════════════════════════════════════════════════════════════════

fn tabbar_bg() dvui.Color {
    return tc.chromeTabbarBg();
}
fn tab_active() dvui.Color {
    return tc.chromeTabActiveBg();
}
fn tab_hover() dvui.Color {
    return tc.chromeHoverBg();
}
fn tab_text_col() dvui.Color {
    return tc.chromeTextSecondary();
}
fn tab_text_active_col() dvui.Color {
    return tc.chromeTextPrimary();
}
fn tab_dirty_col() dvui.Color {
    return tc.chromeAccent();
}

const tab_close_hover = dvui.Color{ .r = 200, .g = 80, .b = 90, .a = 255 };
const tab_cr = dvui.Rect{ .x = 4, .y = 4, .w = 0, .h = 0 };

pub fn drawTabBar(app: *AppState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 32 },
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 0 },
        .background = true,
        .color_fill = bar_bg(),
    });
    defer bar.deinit();

    // Tabs area — expands to fill, compresses tabs when many are open
    {
        var tabs_area = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 9400,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });
        defer tabs_area.deinit();

        // Cap each tab width so they compress like Chrome
        const tab_count = app.documents.items.len;
        const max_tab_w: f32 = if (tab_count <= 1) 200 else @min(200, @max(60, 600.0 / @as(f32, @floatFromInt(tab_count))));

        for (app.documents.items, 0..) |*doc, idx| {
            const active = idx == @as(usize, app.active_idx);

            var tab = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = 9300 + idx,
                .gravity_y = 0.5,
                .max_size_content = dvui.Options.MaxSize.width(max_tab_w),
                .padding = .{ .x = 10, .y = 0, .w = if (tab_count > 1) @as(f32, 4) else @as(f32, 10), .h = 0 },
                .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
                .corner_radius = tab_cr,
                .background = true,
                .color_fill = if (active) tab_active() else tabbar_bg(),
                .border = if (active) .{ .x = 0, .y = 0, .w = 0, .h = 2 } else .{ .x = 0, .y = 0, .w = 0, .h = 0 },
                .color_border = tab_dirty_col(),
            });
            defer tab.deinit();

            // Dirty prefix — show basename with extension, not full path
            var buf: [80]u8 = undefined;
            const display_name = helpers.baseName(doc.name);
            const label = if (doc.dirty)
                std.fmt.bufPrint(&buf, "* {s}", .{display_name}) catch display_name
            else
                display_name;

            if (dvui.button(@src(), label, .{}, .{
                .id_extra = 9200 + idx,
                .gravity_y = 0.5,
                .padding = .{ .x = 0, .y = 5, .w = 0, .h = 5 },
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
                .corner_radius = tab_cr,
                .color_fill = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_fill_hover = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = if (active) tab_text_active_col() else tab_text_col(),
            })) {
                if (!active) {
                    app.active_idx = @intCast(idx);
                    app.status_msg = "Switched tab";
                }
            }

            if (tab_count > 1) {
                if (dvui.button(@src(), "x", .{}, .{
                    .id_extra = 9100 + idx,
                    .gravity_y = 0.5,
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
            .id_extra = 9000,
            .gravity_y = 0.5,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .corner_radius = dvui.Rect.all(3),
            .color_fill = tabbar_bg(),
            .color_fill_hover = tab_hover(),
        }))
            actions.enqueue(app, .{ .immediate = .new_tab }, "New tab");
    }

    // SCH / SYM view-mode toggle
    const sch_active = app.gui.hot.view_mode == .schematic;
    if (dvui.button(@src(), "SCH", .{}, .{
        .id_extra = 9001,
        .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .corner_radius = dvui.Rect.all(3),
        .style = if (sch_active) .highlight else .control,
    })) actions.runGuiCommand(app, .view_schematic);
    _ = dvui.spacer(@src(), .{ .id_extra = 9003, .min_size_content = .{ .w = 2 } });
    if (dvui.button(@src(), "SYM", .{}, .{
        .id_extra = 9002,
        .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .corner_radius = dvui.Rect.all(3),
        .style = if (app.gui.hot.view_mode == .symbol) .highlight else .control,
    })) actions.runGuiCommand(app, .view_symbol);
    _ = dvui.spacer(@src(), .{ .id_extra = 9004, .min_size_content = .{ .w = 2 } });
    const doc_active = app.gui.hot.view_mode == .doc;
    if (dvui.button(@src(), "DOC", .{}, .{
        .id_extra = 9005,
        .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .corner_radius = dvui.Rect.all(3),
        .style = if (doc_active) .highlight else .control,
    })) actions.runGuiCommand(app, .view_doc);
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
        .expand = .horizontal,
        .min_size_content = .{ .h = 22 },
        .padding = .{ .x = 10, .y = 2, .w = 10, .h = 2 },
        .background = true,
        .color_fill = bar_bg(),
    });
    defer bar.deinit();

    if (app.gui.hot.command_mode) {
        var buf: [260]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, ":{s}_", .{
            app.gui.cold.command_buf[0..app.gui.hot.command_len],
        }) catch ":";
        dvui.labelNoFmt(@src(), cmd, .{}, .{ .id_extra = 5001, .gravity_y = 0.5, .color_text = accent_col() });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 5002 });
        dvui.labelNoFmt(@src(), "Enter to run \xc2\xb7 Esc to cancel", .{}, .{ .id_extra = 5003, .gravity_y = 0.5, .color_text = hint_color });
    } else {
        const msg = app.status_msg;
        const status_col: dvui.Color = if (isErrorStatus(msg)) err_color else tc.chromeTextPrimary();
        dvui.labelNoFmt(@src(), msg, .{}, .{ .id_extra = 5010, .expand = .horizontal, .gravity_y = 0.5, .color_text = status_col });

        // Cursor coordinates and zoom
        if (app.active()) |doc| {
            var coord_buf: [64]u8 = undefined;
            const cursor = app.gui.hot.canvas.cursor_world;
            const coord_text = std.fmt.bufPrint(&coord_buf, "({d},{d})  {d:.1}x", .{
                cursor[0], cursor[1], doc.view.zoom,
            }) catch "???";
            dvui.labelNoFmt(@src(), coord_text, .{}, .{ .id_extra = 5018, .gravity_y = 0.5, .color_text = text_muted() });
            dvui.labelNoFmt(@src(), "\xc2\xb7", .{}, .{ .id_extra = 5019, .gravity_y = 0.5, .color_text = sep_col() });
        }

        var snap_buf: [32]u8 = undefined;
        const snap_str = std.fmt.bufPrint(&snap_buf, "snap:{d:.0}", .{app.tool.snap_size}) catch "snap:10";
        dvui.labelNoFmt(@src(), snap_str, .{}, .{ .id_extra = 5011, .gravity_y = 0.5, .color_text = text_muted() });
        dvui.labelNoFmt(@src(), "\xc2\xb7", .{}, .{ .id_extra = 5012, .gravity_y = 0.5, .color_text = sep_col() });
        dvui.labelNoFmt(@src(), app.tool.active.label(), .{}, .{ .id_extra = 5013, .gravity_y = 0.5, .color_text = text_muted() });
        dvui.labelNoFmt(@src(), "\xc2\xb7", .{}, .{ .id_extra = 5014, .gravity_y = 0.5, .color_text = sep_col() });
        var vbuf: [24]u8 = undefined;
        const view_str = std.fmt.bufPrint(&vbuf, "{s}", .{@tagName(app.gui.hot.view_mode)}) catch "sch";
        dvui.labelNoFmt(@src(), view_str, .{}, .{ .id_extra = 5015, .gravity_y = 0.5, .color_text = text_muted() });
        dvui.labelNoFmt(@src(), "\xc2\xb7", .{}, .{ .id_extra = 5016, .gravity_y = 0.5, .color_text = sep_col() });
        dvui.labelNoFmt(@src(), "[ : for commands ]", .{}, .{ .id_extra = 5017, .gravity_y = 0.5, .color_text = hint_color });
    }
}
