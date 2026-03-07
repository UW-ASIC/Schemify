//! Toolbar — horizontal menu bar at the top of the window.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
const actions = @import("actions.zig");

// ── Layout constants ──────────────────────────────────────────────────────── //

const TOOLBAR_HEIGHT: f32 = 28;

// ── Public API ────────────────────────────────────────────────────────────── //

/// Draw the main toolbar with all menu items.
pub fn draw(app: *AppState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .min_size_content = .{ .h = TOOLBAR_HEIGHT },
    });
    defer bar.deinit();

    var menus = dvui.menu(@src(), .horizontal, .{});
    defer menus.deinit();

    drawFileMenu(app, 1);
    drawEditMenu(app, 2);
    drawViewMenu(app, 3);
    drawWireDrawMenu(app, 4);
    drawHierarchyMenu(app, 5);
    drawNetlistMenu(app, 6);
    drawSimMenu(app, 7);
    drawExportMenu(app, 8);
    drawTransformMenu(app, 9);
    drawPluginsMenu(app, 10);

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
}

fn drawFileMenu(app: *AppState, id_extra: usize) void {
    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .id_extra = id_extra })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id_extra });
        defer fw.deinit();
        if (menuAction("New File [Ctrl+N]", 100)) {
            actions.runGuiCommand(app, .file_new);
            fw.close();
        }
        if (menuAction("Open File [Ctrl+O]", 101)) {
            actions.runGuiCommand(app, .file_open);
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 110 });
        if (menuAction("Save [Ctrl+S]", 102)) {
            actions.runGuiCommand(app, .file_save);
            fw.close();
        }
        if (menuAction("Save As [Ctrl+Shift+S]", 103)) {
            actions.runGuiCommand(app, .file_save_as);
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 111 });
        if (menuAction("Reload from Disk [Alt+S]", 104)) {
            actions.runGuiCommand(app, .file_reload);
            fw.close();
        }
        if (menuAction("Clear Schematic [Ctrl+N]", 105)) {
            actions.runGuiCommand(app, .file_clear);
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 112 });
        if (menuAction("New Tab [Ctrl+T]", 106)) {
            actions.enqueue(app, .{ .new_tab = {} }, "Queued new tab");
            fw.close();
        }
        if (menuAction("Close Tab [Ctrl+W]", 107)) {
            actions.enqueue(app, .{ .close_tab = {} }, "Queued close tab");
            fw.close();
        }
        if (menuAction("Next Tab [Ctrl+→]", 108)) {
            actions.enqueue(app, .{ .next_tab = {} }, "Queued next tab");
            fw.close();
        }
        if (menuAction("Prev Tab [Ctrl+←]", 109)) {
            actions.enqueue(app, .{ .prev_tab = {} }, "Queued prev tab");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 113 });
        if (menuAction("Start New Process [Ctrl+Shift+N]", 114)) {
            actions.runGuiCommand(app, .file_start_process);
            fw.close();
        }
        if (menuAction("View Logs [Ctrl+L]", 115)) {
            actions.runGuiCommand(app, .file_view_logs);
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 116 });
        if (menuAction("Exit [Ctrl+Q]", 117)) {
            fw.close();
            actions.runGuiCommand(app, .file_exit);
        }
    }
}

fn drawEditMenu(app: *AppState, id_extra: usize) void {
    if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{ .id_extra = id_extra })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id_extra });
        defer fw.deinit();
        if (menuAction("Undo [Ctrl+Z]", 201)) {
            actions.enqueue(app, .{ .undo = {} }, "Queued undo");
            fw.close();
        }
        if (menuAction("Redo [Ctrl+Y]", 202)) {
            actions.enqueue(app, .{ .redo = {} }, "Queued redo");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 220 });
        if (menuAction("Cut [Ctrl+X]", 203)) {
            actions.enqueue(app, .{ .clipboard_cut = {} }, "Cut to clipboard");
            fw.close();
        }
        if (menuAction("Copy [Ctrl+C]", 204)) {
            actions.enqueue(app, .{ .clipboard_copy = {} }, "Copied to clipboard");
            fw.close();
        }
        if (menuAction("Paste [Ctrl+V]", 205)) {
            actions.enqueue(app, .{ .clipboard_paste = {} }, "Pasted from clipboard");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 221 });
        if (menuAction("Select All [Ctrl+A]", 206)) {
            actions.enqueue(app, .{ .select_all = {} }, "Queued select all");
            fw.close();
        }
        if (menuAction("Select None [Ctrl+Shift+A]", 207)) {
            actions.enqueue(app, .{ .select_none = {} }, "Queued select none");
            fw.close();
        }
        if (menuAction("Find/Select [Ctrl+F]", 208)) {
            actions.enqueue(app, .{ .find_select_dialog = {} }, "Find/select");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 222 });
        if (menuAction("Move [M]", 209)) {
            actions.enqueue(app, .{ .move_interactive = {} }, "Move mode");
            fw.close();
        }
        if (menuAction("Copy Selected [C]", 210)) {
            actions.enqueue(app, .{ .copy_selected = {} }, "Copy mode");
            fw.close();
        }
        if (menuAction("Duplicate [D]", 211)) {
            actions.enqueue(app, .{ .duplicate_selected = {} }, "Queued duplicate");
            fw.close();
        }
        if (menuAction("Delete [Del]", 212)) {
            actions.enqueue(app, .{ .delete_selected = {} }, "Queued delete");
            fw.close();
        }
        if (menuAction("Align to Grid [Alt+U]", 213)) {
            actions.enqueue(app, .{ .align_to_grid = {} }, "Aligned to grid");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 223 });
        if (menuAction("Edit Properties [Q]", 214)) {
            actions.enqueue(app, .{ .edit_properties = {} }, "Edit properties");
            fw.close();
        }
        if (menuAction("View Properties", 215)) {
            actions.enqueue(app, .{ .view_properties = {} }, "View properties");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 224 });
        if (menuAction("Highlight Dup Refs [#]", 216)) {
            actions.enqueue(app, .{ .highlight_dup_refdes = {} }, "Highlighting duplicates");
            fw.close();
        }
        if (menuAction("Fix Dup Refs", 217)) {
            actions.enqueue(app, .{ .rename_dup_refdes = {} }, "Renaming duplicates");
            fw.close();
        }
    }
}

fn drawViewMenu(app: *AppState, id_extra: usize) void {
    if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{ .id_extra = id_extra })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id_extra });
        defer fw.deinit();
        if (menuAction("Zoom In [Ctrl+=]", 301)) {
            actions.enqueue(app, .{ .zoom_in = {} }, "Queued zoom in");
            fw.close();
        }
        if (menuAction("Zoom Out [Ctrl+-]", 302)) {
            actions.enqueue(app, .{ .zoom_out = {} }, "Queued zoom out");
            fw.close();
        }
        if (menuAction("Zoom Fit [F]", 303)) {
            actions.enqueue(app, .{ .zoom_fit = {} }, "Queued zoom fit");
            fw.close();
        }
        if (menuAction("Zoom 100% [Ctrl+0]", 304)) {
            actions.enqueue(app, .{ .zoom_reset = {} }, "Queued zoom reset");
            fw.close();
        }
        if (menuAction("Zoom Fit Selection", 305)) {
            actions.enqueue(app, .{ .zoom_fit_selected = {} }, "Queued zoom fit selected");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 320 });
        {
            var grid_buf: [32]u8 = undefined;
            const grid_label = std.fmt.bufPrint(&grid_buf, "{s} Grid [G]", .{if (app.show_grid) "Hide" else "Show"}) catch "Toggle Grid";
            if (menuAction(grid_label, 306)) {
                app.show_grid = !app.show_grid;
                fw.close();
            }
        }
        if (menuAction("Toggle Crosshair", 307)) {
            actions.enqueue(app, .{ .toggle_crosshair = {} }, "Toggle crosshair");
            fw.close();
        }
        if (menuAction("Toggle Fullscreen [\\]", 308)) {
            actions.enqueue(app, .{ .toggle_fullscreen = {} }, "Toggle fullscreen");
            fw.close();
        }
        if (menuAction("Toggle Colorscheme [Shift+O]", 309)) {
            actions.enqueue(app, .{ .toggle_colorscheme = {} }, "Toggle colorscheme");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 321 });
        if (menuAction("Show Netlist Overlay", 310)) {
            actions.enqueue(app, .{ .toggle_show_netlist = {} }, "Toggle netlist display");
            fw.close();
        }
        if (menuAction("Toggle Text in Symbols", 311)) {
            actions.enqueue(app, .{ .toggle_text_in_symbols = {} }, "Toggle text in symbols");
            fw.close();
        }
        if (menuAction("Toggle Symbol Details", 312)) {
            actions.enqueue(app, .{ .toggle_symbol_details = {} }, "Toggle symbol details");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 322 });
        if (menuAction("Increase Line Width", 313)) {
            actions.enqueue(app, .{ .increase_line_width = {} }, "Line width increased");
            fw.close();
        }
        if (menuAction("Decrease Line Width", 314)) {
            actions.enqueue(app, .{ .decrease_line_width = {} }, "Line width decreased");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 323 });
        if (menuAction("Snap Double [Shift+G]", 315)) {
            actions.enqueue(app, .{ .snap_double = {} }, "Snap doubled");
            fw.close();
        }
        if (menuAction("Snap Halve", 316)) {
            actions.enqueue(app, .{ .snap_halve = {} }, "Snap halved");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 324 });
        if (menuAction("Schematic View [S]", 317)) {
            actions.runGuiCommand(app, .view_schematic);
            fw.close();
        }
        if (menuAction("Symbol View [W]", 318)) {
            actions.runGuiCommand(app, .view_symbol);
            fw.close();
        }
    }
}

fn drawWireDrawMenu(app: *AppState, id_extra: usize) void {
    if (dvui.menuItemLabel(@src(), "Wire/Draw", .{ .submenu = true }, .{ .id_extra = id_extra })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id_extra });
        defer fw.deinit();
        if (menuAction("Start Wire [W]", 401)) {
            actions.enqueue(app, .{ .start_wire = {} }, "Wire mode");
            fw.close();
        }
        if (menuAction("Start Wire (Snap) [Shift+W]", 402)) {
            actions.enqueue(app, .{ .start_wire_snap = {} }, "Wire mode (snap)");
            fw.close();
        }
        if (menuAction("Cancel Wire [Escape]", 403)) {
            actions.enqueue(app, .{ .cancel_wire = {} }, "Wire canceled");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 420 });
        if (menuAction("Toggle Wire Routing [Space]", 404)) {
            actions.enqueue(app, .{ .toggle_wire_routing = {} }, "Toggle routing");
            fw.close();
        }
        if (menuAction("Toggle Ortho Routing [Shift+L]", 405)) {
            actions.enqueue(app, .{ .toggle_orthogonal_routing = {} }, "Toggle ortho routing");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 421 });
        if (menuAction("Break Wires at Connections [!]", 406)) {
            actions.enqueue(app, .{ .break_wires_at_connections = {} }, "Break wires");
            fw.close();
        }
        if (menuAction("Join/Collapse Wires [&]", 407)) {
            actions.enqueue(app, .{ .join_collapse_wires = {} }, "Join wires");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 422 });
        if (menuAction("Draw Line [L]", 408)) {
            actions.enqueue(app, .{ .start_line = {} }, "Line draw mode");
            fw.close();
        }
        if (menuAction("Draw Rectangle [Shift+R]", 409)) {
            actions.enqueue(app, .{ .start_rect = {} }, "Rect draw mode");
            fw.close();
        }
        if (menuAction("Draw Polygon [P]", 410)) {
            actions.enqueue(app, .{ .start_polygon = {} }, "Polygon draw mode");
            fw.close();
        }
        if (menuAction("Draw Arc [Shift+C]", 411)) {
            actions.enqueue(app, .{ .start_arc = {} }, "Arc draw mode");
            fw.close();
        }
        if (menuAction("Draw Circle [Ctrl+Shift+C]", 412)) {
            actions.enqueue(app, .{ .start_circle = {} }, "Circle draw mode");
            fw.close();
        }
        if (menuAction("Place Text [T]", 413)) {
            actions.enqueue(app, .{ .place_text = {} }, "Place text");
            fw.close();
        }
    }
}

fn drawHierarchyMenu(app: *AppState, id_extra: usize) void {
    if (dvui.menuItemLabel(@src(), "Hierarchy", .{ .submenu = true }, .{ .id_extra = id_extra })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id_extra });
        defer fw.deinit();
        if (menuAction("Descend Schematic [E]", 501)) {
            actions.enqueue(app, .{ .descend_schematic = {} }, "Descend into schematic");
            fw.close();
        }
        if (menuAction("Descend Symbol [I]", 502)) {
            actions.enqueue(app, .{ .descend_symbol = {} }, "Descend into symbol");
            fw.close();
        }
        if (menuAction("Ascend [Ctrl+E / Backspace]", 503)) {
            actions.enqueue(app, .{ .ascend = {} }, "Ascend to parent");
            fw.close();
        }
        if (menuAction("Edit in New Tab [Alt+E]", 504)) {
            actions.enqueue(app, .{ .edit_in_new_tab = {} }, "Edit in new tab");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 520 });
        if (menuAction("Make Symbol from Schematic [A]", 505)) {
            actions.enqueue(app, .{ .make_symbol_from_schematic = {} }, "Making symbol");
            fw.close();
        }
        if (menuAction("Make Schematic from Symbol [Ctrl+L]", 506)) {
            actions.enqueue(app, .{ .make_schematic_from_symbol = {} }, "Making schematic");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 521 });
        if (menuAction("Insert from Library [Insert]", 507)) {
            actions.enqueue(app, .{ .insert_from_library = {} }, "Opening library");
            fw.close();
        }
    }
}

fn drawNetlistMenu(app: *AppState, id_extra: usize) void {
    if (dvui.menuItemLabel(@src(), "Netlist", .{ .submenu = true }, .{ .id_extra = id_extra })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id_extra });
        defer fw.deinit();
        if (menuAction("Generate Hierarchical [N]", 601)) {
            actions.enqueue(app, .{ .netlist_hierarchical = {} }, "Generating netlist");
            fw.close();
        }
        if (menuAction("Generate Flat", 602)) {
            actions.enqueue(app, .{ .netlist_flat = {} }, "Generating flat netlist");
            fw.close();
        }
        if (menuAction("Generate Top-Only [Shift+N]", 603)) {
            actions.enqueue(app, .{ .netlist_top_only = {} }, "Generating top netlist");
            fw.close();
        }
        if (menuAction("Toggle Flat/Hierarchical", 604)) {
            actions.enqueue(app, .{ .toggle_flat_netlist = {} }, "Toggled flat netlist");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 620 });
        if (menuAction("Highlight Selected Nets [K]", 605)) {
            actions.enqueue(app, .{ .highlight_selected_nets = {} }, "Highlighting nets");
            fw.close();
        }
        if (menuAction("Unhighlight Selected [Ctrl+K]", 606)) {
            actions.enqueue(app, .{ .unhighlight_selected_nets = {} }, "Unhighlighting nets");
            fw.close();
        }
        if (menuAction("Unhighlight All [Shift+K]", 607)) {
            actions.enqueue(app, .{ .unhighlight_all = {} }, "Unhighlighting all");
            fw.close();
        }
        if (menuAction("Select Attached Nets [Alt+K]", 608)) {
            actions.enqueue(app, .{ .select_attached_nets = {} }, "Selecting nets");
            fw.close();
        }
    }
}

fn drawSimMenu(app: *AppState, id_extra: usize) void {
    if (dvui.menuItemLabel(@src(), "Sim", .{ .submenu = true }, .{ .id_extra = id_extra })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id_extra });
        defer fw.deinit();
        if (menuAction("Run NGSpice [F5]", 701)) {
            actions.enqueue(app, .{ .run_sim = .{ .sim = .ngspice } }, "Queued simulation");
            fw.close();
        }
        if (menuAction("Run Xyce", 702)) {
            actions.enqueue(app, .{ .run_sim = .{ .sim = .xyce } }, "Queued Xyce simulation");
            fw.close();
        }
        if (menuAction("Open Waveform Viewer", 703)) {
            actions.enqueue(app, .{ .open_waveform_viewer = {} }, "Opening waveform viewer");
            fw.close();
        }
    }
}

fn drawExportMenu(app: *AppState, id_extra: usize) void {
    if (dvui.menuItemLabel(@src(), "Export", .{ .submenu = true }, .{ .id_extra = id_extra })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id_extra });
        defer fw.deinit();
        if (menuAction("Export PDF", 801)) {
            actions.enqueue(app, .{ .export_pdf = {} }, "Export PDF (stub)");
            fw.close();
        }
        if (menuAction("Export PNG", 802)) {
            actions.enqueue(app, .{ .export_png = {} }, "Export PNG (stub)");
            fw.close();
        }
        if (menuAction("Export SVG", 803)) {
            actions.enqueue(app, .{ .export_svg = {} }, "Export SVG (stub)");
            fw.close();
        }
        if (menuAction("Screenshot", 804)) {
            actions.enqueue(app, .{ .screenshot_area = {} }, "Screenshot (stub)");
            fw.close();
        }
    }
}

fn drawTransformMenu(app: *AppState, id_extra: usize) void {
    if (dvui.menuItemLabel(@src(), "Transform", .{ .submenu = true }, .{ .id_extra = id_extra })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id_extra });
        defer fw.deinit();
        if (menuAction("Rotate CW [R]", 901)) {
            actions.enqueue(app, .{ .rotate_cw = {} }, "Queued rotate CW");
            fw.close();
        }
        if (menuAction("Rotate CCW [Shift+R]", 902)) {
            actions.enqueue(app, .{ .rotate_ccw = {} }, "Queued rotate CCW");
            fw.close();
        }
        if (menuAction("Flip Horizontal [X]", 903)) {
            actions.enqueue(app, .{ .flip_horizontal = {} }, "Queued flip horizontal");
            fw.close();
        }
        if (menuAction("Flip Vertical [Shift+X]", 904)) {
            actions.enqueue(app, .{ .flip_vertical = {} }, "Queued flip vertical");
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 920 });
        if (menuAction("Nudge Left [:left]", 905)) {
            actions.enqueue(app, .{ .nudge_left = {} }, "Queued nudge left");
            fw.close();
        }
        if (menuAction("Nudge Right [:right]", 906)) {
            actions.enqueue(app, .{ .nudge_right = {} }, "Queued nudge right");
            fw.close();
        }
        if (menuAction("Nudge Up [:up]", 907)) {
            actions.enqueue(app, .{ .nudge_up = {} }, "Queued nudge up");
            fw.close();
        }
        if (menuAction("Nudge Down [:down]", 908)) {
            actions.enqueue(app, .{ .nudge_down = {} }, "Queued nudge down");
            fw.close();
        }
    }
}

fn drawPluginsMenu(app: *AppState, id_extra: usize) void {
    if (dvui.menuItemLabel(@src(), "Plugins", .{ .submenu = true }, .{ .id_extra = id_extra })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id_extra });
        defer fw.deinit();
        if (menuAction("Plugin Marketplace…", 1000)) {
            app.gui.marketplace.visible = true;
            fw.close();
        }
        _ = dvui.separator(@src(), .{ .id_extra = 1003 });
        if (menuAction("Reload All Plugins [F6]", 1001)) {
            actions.enqueue(app, .{ .plugins_refresh = {} }, "Queued plugin refresh signal");
            fw.close();
        }

        if (app.gui.plugin_panels.items.len > 0) {
            _ = dvui.separator(@src(), .{ .id_extra = 1002 });
            for (app.gui.plugin_panels.items, 0..) |panel, i| {
                var label_buf: [80]u8 = undefined;
                const vis = if (panel.visible) "\xe2\x9c\x93 " else "  ";
                const key_hint = if (panel.keybind != 0)
                    std.fmt.bufPrint(&label_buf, "{s}{s}  [{c}]", .{ vis, panel.title, panel.keybind }) catch panel.title
                else
                    std.fmt.bufPrint(&label_buf, "{s}{s}", .{ vis, panel.title }) catch panel.title;
                if (menuAction(key_hint, 1010 + i)) {
                    app.gui.plugin_panels.items[i].visible = !app.gui.plugin_panels.items[i].visible;
                    fw.close();
                }
            }
        }
    }
}

fn menuAction(label: []const u8, id_extra: usize) bool {
    return dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = id_extra }) != null;
}
