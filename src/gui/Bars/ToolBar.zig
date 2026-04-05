//! Toolbar — horizontal menu bar at the top of the window.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("state").AppState;
const actions = @import("../Actions.zig");
const command = @import("commands");
const components = @import("../Components/lib.zig");

const ToolbarBar = components.HorizontalBar(.{ .height = 28 });

// ── Menu item descriptors ─────────────────────────────────────────────────── //

const MenuItem = union(enum) {
    action: struct { label: []const u8, cmd: command.Command, msg: []const u8 },
    gui_cmd: struct { label: []const u8, cmd: actions.GuiCommand },
    separator,
};

// ── Comptime menu tables ──────────────────────────────────────────────────── //

const file_items = [_]MenuItem{
    .{ .gui_cmd = .{ .label = "New File [Ctrl+N]", .cmd = .file_new } },
    .{ .gui_cmd = .{ .label = "Open File [Ctrl+O]", .cmd = .file_open } },
    .separator,
    .{ .gui_cmd = .{ .label = "Save [Ctrl+S]", .cmd = .file_save } },
    .{ .gui_cmd = .{ .label = "Save As [Ctrl+Shift+S]", .cmd = .file_save_as } },
    .separator,
    .{ .gui_cmd = .{ .label = "Reload from Disk [Alt+S]", .cmd = .file_reload } },
    .{ .gui_cmd = .{ .label = "Clear Schematic [Ctrl+N]", .cmd = .file_clear } },
    .separator,
    .{ .action = .{ .label = "New Tab [Ctrl+T]", .cmd = .{ .immediate = .new_tab }, .msg = "Queued new tab" } },
    .{ .action = .{ .label = "Close Tab [Ctrl+W]", .cmd = .{ .immediate = .close_tab }, .msg = "Queued close tab" } },
    .{ .action = .{ .label = "Next Tab [Ctrl+\xe2\x86\x92]", .cmd = .{ .immediate = .next_tab }, .msg = "Queued next tab" } },
    .{ .action = .{ .label = "Prev Tab [Ctrl+\xe2\x86\x90]", .cmd = .{ .immediate = .prev_tab }, .msg = "Queued prev tab" } },
    .separator,
    .{ .gui_cmd = .{ .label = "Start New Process [Ctrl+Shift+N]", .cmd = .file_start_process } },
    .{ .gui_cmd = .{ .label = "View Logs [Ctrl+L]", .cmd = .file_view_logs } },
    .separator,
    .{ .gui_cmd = .{ .label = "Exit [Ctrl+Q]", .cmd = .file_exit } },
};

const edit_items = [_]MenuItem{
    .{ .action = .{ .label = "Undo [Ctrl+Z]", .cmd = .{ .immediate = .undo }, .msg = "Queued undo" } },
    .{ .action = .{ .label = "Redo [Ctrl+Y]", .cmd = .{ .immediate = .redo }, .msg = "Queued redo" } },
    .separator,
    .{ .action = .{ .label = "Cut [Ctrl+X]", .cmd = .{ .immediate = .clipboard_cut }, .msg = "Cut to clipboard" } },
    .{ .action = .{ .label = "Copy [Ctrl+C]", .cmd = .{ .immediate = .clipboard_copy }, .msg = "Copied to clipboard" } },
    .{ .action = .{ .label = "Paste [Ctrl+V]", .cmd = .{ .immediate = .clipboard_paste }, .msg = "Pasted from clipboard" } },
    .separator,
    .{ .action = .{ .label = "Select All [Ctrl+A]", .cmd = .{ .immediate = .select_all }, .msg = "Queued select all" } },
    .{ .action = .{ .label = "Select None [Ctrl+Shift+A]", .cmd = .{ .immediate = .select_none }, .msg = "Queued select none" } },
    .{ .action = .{ .label = "Find/Select [Ctrl+F]", .cmd = .{ .immediate = .find_select_dialog }, .msg = "Find/select" } },
    .separator,
    .{ .action = .{ .label = "Move [M]", .cmd = .{ .immediate = .move_interactive }, .msg = "Move mode" } },
    .{ .action = .{ .label = "Copy Selected [C]", .cmd = .{ .immediate = .copy_selected }, .msg = "Copy mode" } },
    .{ .action = .{ .label = "Duplicate [D]", .cmd = .{ .undoable = .duplicate_selected }, .msg = "Queued duplicate" } },
    .{ .action = .{ .label = "Delete [Del]", .cmd = .{ .undoable = .delete_selected }, .msg = "Queued delete" } },
    .{ .action = .{ .label = "Align to Grid [Alt+U]", .cmd = .{ .immediate = .align_to_grid }, .msg = "Aligned to grid" } },
    .separator,
    .{ .action = .{ .label = "Edit Properties [Q]", .cmd = .{ .immediate = .edit_properties }, .msg = "Edit properties" } },
    .{ .action = .{ .label = "View Properties", .cmd = .{ .immediate = .view_properties }, .msg = "View properties" } },
};

const view_items = [_]MenuItem{
    .{ .action = .{ .label = "Zoom In [Ctrl+=]", .cmd = .{ .immediate = .zoom_in }, .msg = "Queued zoom in" } },
    .{ .action = .{ .label = "Zoom Out [Ctrl+-]", .cmd = .{ .immediate = .zoom_out }, .msg = "Queued zoom out" } },
    .{ .action = .{ .label = "Zoom Fit [F]", .cmd = .{ .immediate = .zoom_fit }, .msg = "Queued zoom fit" } },
    .{ .action = .{ .label = "Zoom 100% [Ctrl+0]", .cmd = .{ .immediate = .zoom_reset }, .msg = "Queued zoom reset" } },
    .{ .action = .{ .label = "Zoom Fit Selection", .cmd = .{ .immediate = .zoom_fit_selected }, .msg = "Queued zoom fit selected" } },
    .separator,
    // Grid toggle handled inline in draw() — dynamic label based on app.show_grid.
};

const view_items_after_grid = [_]MenuItem{
    .{ .action = .{ .label = "Toggle Crosshair", .cmd = .{ .immediate = .toggle_crosshair }, .msg = "Toggle crosshair" } },
    .{ .action = .{ .label = "Toggle Fullscreen [\\]", .cmd = .{ .immediate = .toggle_fullscreen }, .msg = "Toggle fullscreen" } },
    .{ .action = .{ .label = "Toggle Colorscheme [Shift+O]", .cmd = .{ .immediate = .toggle_colorscheme }, .msg = "Toggle colorscheme" } },
    .separator,
    .{ .action = .{ .label = "Show Netlist Overlay", .cmd = .{ .immediate = .toggle_show_netlist }, .msg = "Toggle netlist display" } },
    .{ .action = .{ .label = "Toggle Text in Symbols", .cmd = .{ .immediate = .toggle_text_in_symbols }, .msg = "Toggle text in symbols" } },
    .{ .action = .{ .label = "Toggle Symbol Details", .cmd = .{ .immediate = .toggle_symbol_details }, .msg = "Toggle symbol details" } },
    .separator,
    .{ .action = .{ .label = "Increase Line Width", .cmd = .{ .immediate = .increase_line_width }, .msg = "Line width increased" } },
    .{ .action = .{ .label = "Decrease Line Width", .cmd = .{ .immediate = .decrease_line_width }, .msg = "Line width decreased" } },
    .separator,
    .{ .action = .{ .label = "Snap Double [Shift+G]", .cmd = .{ .immediate = .snap_double }, .msg = "Snap doubled" } },
    .{ .action = .{ .label = "Snap Halve", .cmd = .{ .immediate = .snap_halve }, .msg = "Snap halved" } },
    .separator,
    .{ .gui_cmd = .{ .label = "Schematic View [S]", .cmd = .view_schematic } },
    .{ .gui_cmd = .{ .label = "Symbol View [W]", .cmd = .view_symbol } },
};

// ── Public API ────────────────────────────────────────────────────────────── //

/// Draw the main toolbar with all menu items.
pub fn draw(app: *AppState) void {
    ToolbarBar.draw(@src(), drawMenus, app, 0);
}

// ── Private rendering ─────────────────────────────────────────────────────── //

/// Comptime table of simple menus: label + item list.
const SimpleMenu = struct { label: []const u8, items: []const MenuItem };
const simple_menus = [_]SimpleMenu{
    .{ .label = "File", .items = &file_items },
    .{ .label = "Edit", .items = &edit_items },
};

fn drawMenus(app: *AppState) void {
    var menu_ctx = dvui.menu(@src(), .horizontal, .{});
    defer menu_ctx.deinit();

    // File, Edit menus.
    inline for (simple_menus, 0..) |sm, idx| {
        drawSimpleMenu(app, sm.label, sm.items, idx + 1);
    }

    // View menu — special: dynamic grid toggle between two item lists.
    if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{ .id_extra = 3 })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = 3 });
        defer fw.deinit();
        renderItems(app, fw, &view_items, 0);
        var grid_buf: [32]u8 = undefined;
        const grid_label = std.fmt.bufPrint(&grid_buf, "{s} Grid [G]", .{
            if (app.show_grid) "Hide" else "Show",
        }) catch "Toggle Grid";
        if (menuAction(grid_label, 9900)) {
            app.show_grid = !app.show_grid;
            fw.close();
        }
        renderItems(app, fw, &view_items_after_grid, 1000);
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
}

fn drawSimpleMenu(app: *AppState, comptime label: []const u8, comptime items: []const MenuItem, comptime id: usize) void {
    if (dvui.menuItemLabel(@src(), label, .{ .submenu = true }, .{ .id_extra = id })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id });
        defer fw.deinit();
        renderItems(app, fw, items, 0);
    }
}

fn renderItems(app: *AppState, fw: *dvui.FloatingMenuWidget, comptime items: []const MenuItem, id_base: usize) void {
    inline for (items, 0..) |entry, idx| {
        const id = id_base + idx;
        switch (entry) {
            .action => |a| {
                if (menuAction(a.label, id)) {
                    actions.enqueue(app, a.cmd, a.msg);
                    fw.close();
                }
            },
            .gui_cmd => |g| {
                if (menuAction(g.label, id)) {
                    actions.runGuiCommand(app, g.cmd);
                    fw.close();
                }
            },
            .separator => {
                _ = dvui.separator(@src(), .{ .id_extra = id });
            },
        }
    }
}

fn menuAction(label: []const u8, id_extra: usize) bool {
    return dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = id_extra }) != null;
}
