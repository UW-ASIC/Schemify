//! Toolbar — horizontal menu bar at the top of the window.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const actions = @import("../Actions.zig");
const command = @import("commands");
const components = @import("../Components/lib.zig");
const keybinds = @import("../Keybinds.zig");

const ToolbarBar = components.HorizontalBar(.{ .height = 28 });

// ── Comptime keybind hint generation ─────────────────────────────────────── //

/// Format a key name as a short string (comptime).
fn keyName(comptime key: dvui.enums.Key) []const u8 {
    return switch (key) {
        .a => "A", .b => "B", .c => "C", .d => "D", .e => "E",
        .f => "F", .g => "G", .h => "H", .i => "I", .j => "J",
        .k => "K", .l => "L", .m => "M", .n => "N", .o => "O",
        .p => "P", .q => "Q", .r => "R", .s => "S", .t => "T",
        .u => "U", .v => "V", .w => "W", .x => "X", .y => "Y",
        .z => "Z",
        .zero => "0", .one => "1", .two => "2", .three => "3",
        .four => "4", .five => "5", .six => "6", .seven => "7",
        .eight => "8", .nine => "9",
        .f1 => "F1", .f2 => "F2", .f3 => "F3", .f4 => "F4",
        .f5 => "F5", .f6 => "F6", .f7 => "F7", .f8 => "F8",
        .f9 => "F9", .f10 => "F10", .f11 => "F11", .f12 => "F12",
        .equal => "=", .minus => "-", .backslash => "\\",
        .left => "\xe2\x86\x90", .right => "\xe2\x86\x92",
        .up => "\xe2\x86\x91", .down => "\xe2\x86\x93",
        .insert => "Ins", .delete => "Del",
        .backspace => "Bksp", .tab => "Tab", .enter => "Enter",
        .space => "Space", .escape => "Esc",
        else => "?",
    };
}

/// Build a modifier prefix string like "Ctrl+Shift+" at comptime.
fn modPrefix(comptime ctrl: bool, comptime shift: bool, comptime alt: bool) []const u8 {
    return (if (ctrl) "Ctrl+" else "") ++
           (if (shift) "Shift+" else "") ++
           (if (alt) "Alt+" else "");
}

/// Look up the keybind for a Command and return a hint like " [Ctrl+S]".
/// Returns "" if the command has no registered keybind.
fn cmdHint(comptime cmd: command.Command) []const u8 {
    for (keybinds.static_keybinds) |kb| {
        switch (kb.action) {
            .queue => |q| {
                if (std.meta.eql(q.cmd, cmd)) {
                    return " [" ++ modPrefix(kb.ctrl, kb.shift, kb.alt) ++ keyName(kb.key) ++ "]";
                }
            },
            .gui => {},
        }
    }
    return "";
}

/// Look up the keybind for a GuiCommand and return a hint like " [Ctrl+S]".
/// Returns "" if the command has no registered keybind.
fn guiHint(comptime gui_cmd: actions.GuiCommand) []const u8 {
    for (keybinds.static_keybinds) |kb| {
        switch (kb.action) {
            .queue => {},
            .gui => |g| {
                if (g == gui_cmd) {
                    return " [" ++ modPrefix(kb.ctrl, kb.shift, kb.alt) ++ keyName(kb.key) ++ "]";
                }
            },
        }
    }
    return "";
}

// ── Menu item descriptors ─────────────────────────────────────────────────── //

const MenuItem = union(enum) {
    action: struct { label: []const u8, cmd: command.Command, msg: []const u8 },
    gui_cmd: struct { label: []const u8, cmd: actions.GuiCommand },
    separator,
};

// ── Comptime menu tables ──────────────────────────────────────────────────── //

const file_items = [_]MenuItem{
    .{ .gui_cmd = .{ .label = "New File" ++ guiHint(.file_new), .cmd = .file_new } },
    .{ .gui_cmd = .{ .label = "Open File" ++ guiHint(.file_open), .cmd = .file_open } },
    .separator,
    .{ .gui_cmd = .{ .label = "Save" ++ guiHint(.file_save), .cmd = .file_save } },
    .{ .gui_cmd = .{ .label = "Save As" ++ guiHint(.file_save_as), .cmd = .file_save_as } },
    .separator,
    .{ .gui_cmd = .{ .label = "Reload from Disk" ++ guiHint(.file_reload), .cmd = .file_reload } },
    .{ .gui_cmd = .{ .label = "Clear Schematic [Ctrl+N]", .cmd = .file_clear } },
    .separator,
    .{ .action = .{ .label = "New Tab" ++ cmdHint(.{ .immediate = .new_tab }), .cmd = .{ .immediate = .new_tab }, .msg = "Queued new tab" } },
    .{ .action = .{ .label = "Close Tab" ++ cmdHint(.{ .immediate = .close_tab }), .cmd = .{ .immediate = .close_tab }, .msg = "Queued close tab" } },
    .{ .action = .{ .label = "Next Tab" ++ cmdHint(.{ .immediate = .next_tab }), .cmd = .{ .immediate = .next_tab }, .msg = "Queued next tab" } },
    .{ .action = .{ .label = "Prev Tab" ++ cmdHint(.{ .immediate = .prev_tab }), .cmd = .{ .immediate = .prev_tab }, .msg = "Queued prev tab" } },
    .separator,
    .{ .gui_cmd = .{ .label = "Start New Process" ++ guiHint(.file_start_process), .cmd = .file_start_process } },
    .{ .gui_cmd = .{ .label = "View Logs" ++ guiHint(.file_view_logs), .cmd = .file_view_logs } },
    .separator,
    .{ .gui_cmd = .{ .label = "Exit" ++ guiHint(.file_exit), .cmd = .file_exit } },
};

const edit_items = [_]MenuItem{
    .{ .action = .{ .label = "Undo" ++ cmdHint(.{ .immediate = .undo }), .cmd = .{ .immediate = .undo }, .msg = "Queued undo" } },
    .{ .action = .{ .label = "Redo" ++ cmdHint(.{ .immediate = .redo }), .cmd = .{ .immediate = .redo }, .msg = "Queued redo" } },
    .separator,
    .{ .action = .{ .label = "Cut" ++ cmdHint(.{ .immediate = .clipboard_cut }), .cmd = .{ .immediate = .clipboard_cut }, .msg = "Cut to clipboard" } },
    .{ .action = .{ .label = "Copy" ++ cmdHint(.{ .immediate = .clipboard_copy }), .cmd = .{ .immediate = .clipboard_copy }, .msg = "Copied to clipboard" } },
    .{ .action = .{ .label = "Paste" ++ cmdHint(.{ .immediate = .clipboard_paste }), .cmd = .{ .immediate = .clipboard_paste }, .msg = "Pasted from clipboard" } },
    .separator,
    .{ .action = .{ .label = "Select All" ++ cmdHint(.{ .immediate = .select_all }), .cmd = .{ .immediate = .select_all }, .msg = "Queued select all" } },
    .{ .action = .{ .label = "Select None" ++ cmdHint(.{ .immediate = .select_none }), .cmd = .{ .immediate = .select_none }, .msg = "Queued select none" } },
    .{ .action = .{ .label = "Find/Select" ++ cmdHint(.{ .immediate = .find_select_dialog }), .cmd = .{ .immediate = .find_select_dialog }, .msg = "Find/select" } },
    .separator,
    .{ .action = .{ .label = "Move" ++ cmdHint(.{ .immediate = .move_interactive }), .cmd = .{ .immediate = .move_interactive }, .msg = "Move mode" } },
    .{ .action = .{ .label = "Copy Selected" ++ cmdHint(.{ .immediate = .copy_selected }), .cmd = .{ .immediate = .copy_selected }, .msg = "Copy mode" } },
    .{ .action = .{ .label = "Duplicate" ++ cmdHint(.{ .undoable = .duplicate_selected }), .cmd = .{ .undoable = .duplicate_selected }, .msg = "Queued duplicate" } },
    .{ .action = .{ .label = "Delete" ++ cmdHint(.{ .undoable = .delete_selected }), .cmd = .{ .undoable = .delete_selected }, .msg = "Queued delete" } },
    .{ .action = .{ .label = "Align to Grid [Alt+U]", .cmd = .{ .immediate = .align_to_grid }, .msg = "Aligned to grid" } },
    .separator,
    .{ .action = .{ .label = "Edit Properties" ++ cmdHint(.{ .immediate = .edit_properties }), .cmd = .{ .immediate = .edit_properties }, .msg = "Edit properties" } },
    .{ .action = .{ .label = "View Properties", .cmd = .{ .immediate = .view_properties }, .msg = "View properties" } },
};

const insert_primitives_items = [_]MenuItem{
    .{ .action = .{ .label = "NMOS", .cmd = .{ .immediate = .{ .insert_primitive = .nmos } }, .msg = "Inserted NMOS" } },
    .{ .action = .{ .label = "PMOS", .cmd = .{ .immediate = .{ .insert_primitive = .pmos } }, .msg = "Inserted PMOS" } },
    .{ .action = .{ .label = "Resistor", .cmd = .{ .immediate = .{ .insert_primitive = .resistor } }, .msg = "Inserted Resistor" } },
    .{ .action = .{ .label = "Capacitor", .cmd = .{ .immediate = .{ .insert_primitive = .capacitor } }, .msg = "Inserted Capacitor" } },
    .{ .action = .{ .label = "Inductor", .cmd = .{ .immediate = .{ .insert_primitive = .inductor } }, .msg = "Inserted Inductor" } },
    .{ .action = .{ .label = "Diode", .cmd = .{ .immediate = .{ .insert_primitive = .diode } }, .msg = "Inserted Diode" } },
    .{ .action = .{ .label = "Voltage Source", .cmd = .{ .immediate = .{ .insert_primitive = .vsource } }, .msg = "Inserted Voltage Source" } },
    .{ .action = .{ .label = "Current Source", .cmd = .{ .immediate = .{ .insert_primitive = .isource } }, .msg = "Inserted Current Source" } },
    .{ .action = .{ .label = "Ground", .cmd = .{ .immediate = .{ .insert_primitive = .gnd } }, .msg = "Inserted Ground" } },
    .{ .action = .{ .label = "VDD", .cmd = .{ .immediate = .{ .insert_primitive = .vdd } }, .msg = "Inserted VDD" } },
    .separator,
    .{ .action = .{ .label = "Input Pin", .cmd = .{ .immediate = .{ .insert_primitive = .input_pin } }, .msg = "Inserted Input Pin" } },
    .{ .action = .{ .label = "Output Pin", .cmd = .{ .immediate = .{ .insert_primitive = .output_pin } }, .msg = "Inserted Output Pin" } },
    .{ .action = .{ .label = "Inout Pin", .cmd = .{ .immediate = .{ .insert_primitive = .inout_pin } }, .msg = "Inserted Inout Pin" } },
};

const insert_items_tail = [_]MenuItem{
    .separator,
    .{ .action = .{ .label = "Browse Library\xe2\x80\xa6 [Ctrl+Insert]", .cmd = .{ .immediate = .insert_from_library }, .msg = "Opening library" } },
    .{ .action = .{ .label = "From File\xe2\x80\xa6", .cmd = .{ .immediate = .open_file_explorer }, .msg = "File explorer" } },
};

const view_items = [_]MenuItem{
    .{ .action = .{ .label = "Zoom In" ++ cmdHint(.{ .immediate = .zoom_in }), .cmd = .{ .immediate = .zoom_in }, .msg = "Queued zoom in" } },
    .{ .action = .{ .label = "Zoom Out" ++ cmdHint(.{ .immediate = .zoom_out }), .cmd = .{ .immediate = .zoom_out }, .msg = "Queued zoom out" } },
    .{ .action = .{ .label = "Zoom Fit" ++ cmdHint(.{ .immediate = .zoom_fit }), .cmd = .{ .immediate = .zoom_fit }, .msg = "Queued zoom fit" } },
    .{ .action = .{ .label = "Zoom 100%" ++ cmdHint(.{ .immediate = .zoom_reset }), .cmd = .{ .immediate = .zoom_reset }, .msg = "Queued zoom reset" } },
    .{ .action = .{ .label = "Zoom Fit Selection", .cmd = .{ .immediate = .zoom_fit_selected }, .msg = "Queued zoom fit selected" } },
    .separator,
    // Grid toggle handled inline in draw() — dynamic label based on app.show_grid.
};

const simulate_items = [_]MenuItem{
    .{ .action = .{ .label = "Run Simulation (ngspice)" ++ cmdHint(.{ .undoable = .{ .run_sim = .{ .sim = .ngspice } } }), .cmd = .{ .undoable = .{ .run_sim = .{ .sim = .ngspice } } }, .msg = "Queued simulation" } },
    .{ .action = .{ .label = "Run Simulation (Xyce)", .cmd = .{ .undoable = .{ .run_sim = .{ .sim = .xyce } } }, .msg = "Queued Xyce simulation" } },
    .{ .action = .{ .label = "Open Waveform Viewer", .cmd = .{ .immediate = .open_waveform_viewer }, .msg = "Opening waveform viewer" } },
    .separator,
    .{ .action = .{ .label = "Generate Netlist (Hierarchical)" ++ cmdHint(.{ .immediate = .netlist_hierarchical }), .cmd = .{ .immediate = .netlist_hierarchical }, .msg = "Generating hierarchical netlist" } },
    .{ .action = .{ .label = "Generate Netlist (Flat)", .cmd = .{ .immediate = .netlist_flat }, .msg = "Generating flat netlist" } },
    .{ .action = .{ .label = "Generate Netlist (Top-only)" ++ cmdHint(.{ .immediate = .netlist_top_only }), .cmd = .{ .immediate = .netlist_top_only }, .msg = "Generating top-only netlist" } },
    .separator,
    .{ .action = .{ .label = "Toggle Flat Netlist Mode", .cmd = .{ .immediate = .toggle_flat_netlist }, .msg = "Toggled flat netlist mode" } },
};

const view_items_after_grid = [_]MenuItem{
    .{ .action = .{ .label = "Toggle Crosshair", .cmd = .{ .immediate = .toggle_crosshair }, .msg = "Toggle crosshair" } },
    .{ .action = .{ .label = "Toggle Fullscreen" ++ cmdHint(.{ .immediate = .toggle_fullscreen }), .cmd = .{ .immediate = .toggle_fullscreen }, .msg = "Toggle fullscreen" } },
    .{ .action = .{ .label = "Toggle Colorscheme" ++ cmdHint(.{ .immediate = .toggle_colorscheme }), .cmd = .{ .immediate = .toggle_colorscheme }, .msg = "Toggle colorscheme" } },
    .separator,
    .{ .action = .{ .label = "Show Netlist Overlay", .cmd = .{ .immediate = .toggle_show_netlist }, .msg = "Toggle netlist display" } },
    .{ .action = .{ .label = "Toggle Text in Symbols", .cmd = .{ .immediate = .toggle_text_in_symbols }, .msg = "Toggle text in symbols" } },
    .{ .action = .{ .label = "Toggle Symbol Details", .cmd = .{ .immediate = .toggle_symbol_details }, .msg = "Toggle symbol details" } },
    .separator,
    .{ .action = .{ .label = "Increase Line Width", .cmd = .{ .immediate = .increase_line_width }, .msg = "Line width increased" } },
    .{ .action = .{ .label = "Decrease Line Width", .cmd = .{ .immediate = .decrease_line_width }, .msg = "Line width decreased" } },
    .separator,
    .{ .action = .{ .label = "Snap Double" ++ cmdHint(.{ .immediate = .snap_double }), .cmd = .{ .immediate = .snap_double }, .msg = "Snap doubled" } },
    .{ .action = .{ .label = "Snap Halve", .cmd = .{ .immediate = .snap_halve }, .msg = "Snap halved" } },
    .separator,
    .{ .gui_cmd = .{ .label = "Schematic View" ++ guiHint(.view_schematic), .cmd = .view_schematic } },
    .{ .gui_cmd = .{ .label = "Symbol View" ++ guiHint(.view_symbol), .cmd = .view_symbol } },
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

    // Insert menu — nested submenu for Primitives, plus Browse/From File entries.
    if (dvui.menuItemLabel(@src(), "Insert", .{ .submenu = true }, .{ .id_extra = 5 })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = 5 });
        defer fw.deinit();

        // Nested "Primitives" submenu.
        if (dvui.menuItemLabel(@src(), "Primitives", .{ .submenu = true }, .{ .id_extra = 2000 })) |pr| {
            var pfw = dvui.floatingMenu(@src(), .{ .from = pr }, .{ .id_extra = 2000 });
            defer pfw.deinit();
            renderItems(app, pfw, &insert_primitives_items, 2100);
        }

        // Tail: Browse Library…, From File…
        renderItems(app, fw, &insert_items_tail, 2200);
    }

    // View menu — special: dynamic grid toggle between two item lists.
    if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{ .id_extra = 3 })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = 3 });
        defer fw.deinit();
        renderItems(app, fw, &view_items, 0);
        var grid_buf: [32]u8 = undefined;
        const grid_hint = "";
        const grid_label = std.fmt.bufPrint(&grid_buf, "{s} Grid{s}", .{
            if (app.show_grid) "Hide" else "Show",
            grid_hint,
        }) catch "Toggle Grid";
        if (menuAction(grid_label, 9900)) {
            app.show_grid = !app.show_grid;
            fw.close();
        }
        renderItems(app, fw, &view_items_after_grid, 1000);
    }

    // Simulate menu — placed after View (id_extra=4 to avoid collision with View's 3).
    drawSimpleMenu(app, "Simulate", &simulate_items, 4);

    // Plugins menu — marketplace + installed plugin panel toggles.
    if (dvui.menuItemLabel(@src(), "Plugins", .{ .submenu = true }, .{ .id_extra = 6 })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = 6 });
        defer fw.deinit();

        // Marketplace entry.
        if (menuAction("Plugin Marketplace\xe2\x80\xa6", 6000)) {
            app.gui.cold.marketplace.visible = true;
            fw.close();
        }

        // Installed plugin panels.
        const metas = app.gui.cold.plugin_panels_meta.items;
        const states = app.gui.cold.plugin_panels_state.items;
        if (metas.len > 0) {
            _ = dvui.separator(@src(), .{ .id_extra = 6001 });
            for (metas, 0..) |meta, i| {
                const label = if (meta.title.len > 0) meta.title else meta.id;
                const is_visible = states[i].visible;
                var buf: [128]u8 = undefined;
                const display = std.fmt.bufPrint(&buf, "{s}{s}", .{
                    if (is_visible) "\xe2\x9c\x93 " else "  ",
                    label,
                }) catch label;
                if (dvui.menuItemLabel(@src(), display, .{}, .{ .expand = .horizontal, .id_extra = 6100 + i }) != null) {
                    app.gui.cold.plugin_panels_state.items[i].visible = !is_visible;
                    fw.close();
                }
            }
        }
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
