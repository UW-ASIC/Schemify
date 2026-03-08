//! GUI shell — toolbar, tabbar, renderer, command bar.
//!
//! Frame layout order:
//!   toolbar -> tabbar -> { left_sidebar | { renderer / bottom_bar } | right_sidebar }
//!   -> command_bar -> overlays -> marketplace

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
const cmd_mod = @import("../command.zig");
const actions = @import("actions.zig");
const toolbar = @import("toolbar.zig");
const tabbar = @import("tabbar.zig");
const renderer = @import("renderer.zig");
const command_bar = @import("command_bar.zig");
const plugin_panels = @import("plugin_panels.zig");
const marketplace = @import("marketplace.zig");

/// Render a single GUI frame: input handling, layout, and all sub-panels.
pub fn frame(app: *AppState) !void {
    handleInput(app);

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer outer.deinit();

    toolbar.draw(app);
    tabbar.draw(app);
    {
        var middle = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer middle.deinit();
        plugin_panels.drawSidebar(app, .left_sidebar);
        drawCenterColumn(app);
        plugin_panels.drawSidebar(app, .right_sidebar);
    }
    command_bar.draw(app);
    plugin_panels.drawOverlays(app);
    marketplace.draw(app);
    drawFindDialog(app);
    drawKeybindsWindow(app);
    drawContextMenu(app);
    if (app.gui.props_dialog_open) drawPropertiesDialog(app);
    if (app.gui.lib_browser_open) drawLibraryBrowser(app);
}

/// Center column: renderer on top, optional bottom bar below.
fn drawCenterColumn(app: *AppState) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer col.deinit();
    renderer.draw(app);
    plugin_panels.drawBottomBar(app);
    drawNetlistPreview(app);
}

fn drawNetlistPreview(app: *AppState) void {
    if (!app.cmd_flags.show_netlist) return;
    if (app.last_netlist_len == 0) return;

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 200 },
        .background = true,
    });
    defer panel.deinit();

    dvui.labelNoFmt(@src(), "Netlist", .{}, .{ .style = .control });
    _ = dvui.separator(@src(), .{});

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    const text = app.last_netlist[0..app.last_netlist_len];
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_idx: usize = 0;
    while (lines.next()) |line| {
        dvui.labelNoFmt(@src(), line, .{}, .{ .id_extra = line_idx });
        line_idx += 1;
    }
}

fn handleInput(app: *AppState) void {
    for (dvui.events()) |*ev| {
        if (ev.handled) continue;

        switch (ev.evt) {
            .mouse => |m| {
                switch (m.action) {
                    .wheel_y => |dy| {
                        if (dy > 0) actions.enqueue(app, .{ .zoom_in = {} }, "Zoom in") else if (dy < 0) actions.enqueue(app, .{ .zoom_out = {} }, "Zoom out");
                        ev.handled = true;
                    },
                    else => {},
                }
            },
            .key => |k| {
                if (k.action != .down and k.action != .repeat) continue;
                const ctrl = k.mod.control();
                const shift = k.mod.shift();
                const alt = k.mod.alt();
                if (app.gui.command_mode) {
                    if (handleCommandMode(app, k.code, shift)) ev.handled = true;
                    continue;
                }
                if (handleNormalMode(app, k.code, ctrl, shift, alt)) ev.handled = true;
            },
            else => {},
        }
    }
}

fn handleCommandMode(app: *AppState, code: dvui.enums.Key, shift: bool) bool {
    // If find dialog is open, route typing into the find query
    if (app.gui.find_dialog_open) {
        switch (code) {
            .escape => { app.gui.find_dialog_open = false; return true; },
            .enter => {
                runFindQuery(app);
                return true;
            },
            .backspace => {
                if (app.gui.find_query_len > 0) app.gui.find_query_len -= 1;
                return true;
            },
            else => {
                const ch = keyToChar(code, shift);
                if (ch != 0 and app.gui.find_query_len < app.gui.find_query.len - 1) {
                    app.gui.find_query[app.gui.find_query_len] = ch;
                    app.gui.find_query_len += 1;
                }
                return ch != 0;
            },
        }
    }
    switch (code) {
        .escape => {
            app.gui.command_mode = false;
            app.status_msg = "Command canceled";
            return true;
        },
        .enter => {
            actions.runVimCommand(app, app.gui.command_buf[0..app.gui.command_len]);
            app.gui.command_mode = false;
            app.gui.command_len = 0;
            @memset(&app.gui.command_buf, 0);
            return true;
        },
        .backspace => {
            if (app.gui.command_len > 0) {
                app.gui.command_len -= 1;
                app.gui.command_buf[app.gui.command_len] = 0;
            }
            return true;
        },
        else => {
            const ch = keyToChar(code, shift);
            if (ch == 0 or app.gui.command_len >= app.gui.command_buf.len - 1) return false;
            app.gui.command_buf[app.gui.command_len] = ch;
            app.gui.command_len += 1;
            return true;
        },
    }
}

fn handleNormalMode(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    // Plugin keybinds take priority
    if (dispatchPluginKeybind(app, code, ctrl, shift, alt)) return true;

    const plain = !ctrl and !shift and !alt;
    if (plain and plugin_panels.handlePlainKeyToggle(app, keyToChar(code, false))) return true;
    if (dispatchStaticKeybind(app, code, ctrl, shift, alt)) return true;

    switch (code) {
        .semicolon => if (shift) {
            app.gui.command_mode = true;
            app.gui.command_len = 0;
            @memset(&app.gui.command_buf, 0);
            app.status_msg = "Command mode";
            return true;
        } else return false,
        .escape => {
            if (app.gui.find_dialog_open) { app.gui.find_dialog_open = false; return true; }
            if (app.gui.keybinds_open) { app.gui.keybinds_open = false; return true; }
            if (app.gui.context_menu_open) { app.gui.context_menu_open = false; return true; }
            actions.enqueue(app, .{ .escape_mode = {} }, "Escape");
            return true;
        },
        .g => if (plain) {
            app.show_grid = !app.show_grid;
            app.status_msg = if (app.show_grid) "Grid on" else "Grid off";
            return true;
        } else if (shift and !ctrl and !alt) {
            actions.enqueue(app, .{ .snap_double = {} }, "Snap doubled");
            return true;
        } else return false,
        .s => if (plain) {
            actions.runGuiCommand(app, .view_schematic);
            return true;
        } else return false,
        .w => if (plain) {
            actions.enqueue(app, .{ .start_wire = {} }, "Wire mode");
            return true;
        } else if (shift and !ctrl and !alt) {
            actions.enqueue(app, .{ .start_wire_snap = {} }, "Wire mode (snap)");
            return true;
        } else return false,
        .left => if (plain) {
            app.view.panBy(-50, 0);
            return true;
        } else if (ctrl and !shift and !alt) {
            actions.enqueue(app, .{ .prev_tab = {} }, "Previous tab");
            return true;
        } else return false,
        .right => if (plain) {
            app.view.panBy(50, 0);
            return true;
        } else if (ctrl and !shift and !alt) {
            actions.enqueue(app, .{ .next_tab = {} }, "Next tab");
            return true;
        } else return false,
        .up => if (plain) {
            app.view.panBy(0, -50);
            return true;
        } else return false,
        .down => if (plain) {
            app.view.panBy(0, 50);
            return true;
        } else return false,
        .backspace => if (plain) {
            actions.enqueue(app, .{ .ascend = {} }, "Ascend");
            return true;
        } else return false,
        // Single-letter commands
        .a => if (plain) {
            actions.enqueue(app, .{ .make_symbol_from_schematic = {} }, "Making symbol");
            return true;
        } else return false,
        .b => if (plain) {
            actions.enqueue(app, .{ .merge_file_dialog = {} }, "Merge file");
            return true;
        } else return false,
        .c => if (plain) {
            actions.enqueue(app, .{ .copy_selected = {} }, "Copy mode");
            return true;
        } else return false,
        .d => if (plain) {
            actions.enqueue(app, .{ .duplicate_selected = {} }, "Queued duplicate");
            return true;
        } else return false,
        .e => if (plain) {
            actions.enqueue(app, .{ .descend_schematic = {} }, "Descend");
            return true;
        } else if (alt and !ctrl and !shift) {
            actions.enqueue(app, .{ .edit_in_new_tab = {} }, "Edit in new tab");
            return true;
        } else return false,
        .f => if (plain) {
            actions.enqueue(app, .{ .zoom_fit = {} }, "Queued zoom fit");
            return true;
        } else return false,
        .i => if (plain) {
            actions.enqueue(app, .{ .descend_symbol = {} }, "Descend symbol");
            return true;
        } else return false,
        .k => if (plain) {
            actions.enqueue(app, .{ .highlight_selected_nets = {} }, "Highlighting nets");
            return true;
        } else if (shift and !ctrl and !alt) {
            actions.enqueue(app, .{ .unhighlight_all = {} }, "Unhighlighting all");
            return true;
        } else return false,
        .l => if (plain) {
            actions.enqueue(app, .{ .start_line = {} }, "Line draw mode");
            return true;
        } else return false,
        .m => if (plain) {
            actions.enqueue(app, .{ .move_interactive = {} }, "Move mode");
            return true;
        } else return false,
        .n => if (plain) {
            actions.enqueue(app, .{ .netlist_hierarchical = {} }, "Generating netlist");
            return true;
        } else if (shift and !ctrl and !alt) {
            actions.enqueue(app, .{ .netlist_top_only = {} }, "Generating top netlist");
            return true;
        } else return false,
        .o => if (shift and !ctrl and !alt) {
            actions.enqueue(app, .{ .toggle_colorscheme = {} }, "Toggle colorscheme");
            return true;
        } else return false,
        .p => if (plain) {
            actions.enqueue(app, .{ .start_polygon = {} }, "Polygon draw mode");
            return true;
        } else return false,
        .q => if (plain) {
            actions.enqueue(app, .{ .edit_properties = {} }, "Edit properties");
            return true;
        } else return false,
        .r => if (plain) {
            actions.enqueue(app, .{ .rotate_cw = {} }, "Queued rotate CW");
            return true;
        } else if (shift and !ctrl and !alt) {
            actions.enqueue(app, .{ .rotate_ccw = {} }, "Queued rotate CCW");
            return true;
        } else return false,
        .t => if (plain) {
            actions.enqueue(app, .{ .place_text = {} }, "Place text");
            return true;
        } else return false,
        .v => if (shift and !ctrl and !alt) {
            app.gui.view_mode = .symbol;
            app.status_msg = "Viewing symbol";
            return true;
        } else return false,
        .x => if (plain) {
            actions.enqueue(app, .{ .flip_horizontal = {} }, "Queued flip horizontal");
            return true;
        } else if (shift and !ctrl and !alt) {
            actions.enqueue(app, .{ .flip_vertical = {} }, "Queued flip vertical");
            return true;
        } else return false,
        .z => if (plain) {
            actions.enqueue(app, .{ .zoom_fit = {} }, "Queued zoom fit");
            return true;
        } else return false,
        .insert => if (plain) {
            actions.enqueue(app, .{ .insert_from_library = {} }, "Opening library");
            return true;
        } else return false,
        .backslash => if (plain) {
            actions.enqueue(app, .{ .toggle_fullscreen = {} }, "Toggle fullscreen");
            return true;
        } else return false,
        .delete => if (plain) {
            actions.enqueue(app, .{ .delete_selected = {} }, "Queued delete");
            return true;
        } else return false,
        else => return false,
    }
}

fn runFindQuery(app: *AppState) void {
    const fio = app.active() orelse return;
    const sch = fio.schematic();
    const query = app.gui.find_query[0..app.gui.find_query_len];
    app.gui.find_result_count = 0;
    for (sch.instances.items, 0..) |inst, i| {
        if (std.mem.indexOf(u8, inst.name, query) != null or
            std.mem.indexOf(u8, inst.symbol, query) != null)
        {
            if (app.gui.find_result_count < app.gui.find_results.len) {
                app.gui.find_results[app.gui.find_result_count] = i;
                app.gui.find_result_count += 1;
            }
        }
    }
    app.setStatus("Find: results updated");
}

// ── Phase 7C: Find / select dialog ───────────────────────────────────────────

fn drawFindDialog(app: *AppState) void {
    if (!app.gui.find_dialog_open) return;

    var fw = dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{ .w = 320, .h = 200 } });
    defer fw.deinit();

    dvui.labelNoFmt(@src(), "Find / Select", .{}, .{ .style = .highlight });

    {
        var query_buf: [130]u8 = undefined;
        const query_text = std.fmt.bufPrint(&query_buf, "{s}", .{app.gui.find_query[0..app.gui.find_query_len]}) catch "";
        dvui.labelNoFmt(@src(), query_text, .{}, .{});
    }

    {
        var count_buf: [64]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d} match(es)", .{app.gui.find_result_count}) catch "?";
        dvui.labelNoFmt(@src(), count_text, .{}, .{ .id_extra = 1 });
    }

    if (dvui.button(@src(), "Select All Matches", .{}, .{})) {
        const fio = app.active() orelse { app.gui.find_dialog_open = false; return; };
        const sch = fio.schematic();
        const alloc = app.allocator();
        app.selection.clear();
        for (sch.instances.items, 0..) |inst, i| {
            const matches = std.mem.indexOf(u8, inst.name, app.gui.find_query[0..app.gui.find_query_len]) != null or
                std.mem.indexOf(u8, inst.symbol, app.gui.find_query[0..app.gui.find_query_len]) != null;
            if (matches) {
                app.selection.instances.resize(alloc, i + 1, false) catch continue;
                app.selection.instances.set(i);
            }
        }
        app.gui.find_dialog_open = false;
    }

    if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 1 })) {
        app.gui.find_dialog_open = false;
    }
}

// ── Phase 7D: Keybinds help window ───────────────────────────────────────────

fn drawKeybindsWindow(app: *AppState) void {
    if (!app.gui.keybinds_open) return;

    var fw = dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{ .w = 500, .h = 400 } });
    defer fw.deinit();

    dvui.labelNoFmt(@src(), "Keyboard Shortcuts", .{}, .{ .style = .highlight });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    for (static_keybinds, 0..) |kb, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
        defer row.deinit();

        var key_buf: [32]u8 = undefined;
        const ctrl_str: []const u8 = if (kb.ctrl) "Ctrl+" else "";
        const shift_str: []const u8 = if (kb.shift) "Shift+" else "";
        const alt_str: []const u8 = if (kb.alt) "Alt+" else "";
        const key_str = std.fmt.bufPrint(&key_buf, "{s}{s}{s}{s}", .{ ctrl_str, shift_str, alt_str, @tagName(kb.key) }) catch "?";
        dvui.labelNoFmt(@src(), key_str, .{}, .{ .min_size_content = .{ .w = 150 }, .id_extra = i });

        var action_buf: [64]u8 = undefined;
        const action_str: []const u8 = switch (kb.action) {
            .queue => |q| q.msg,
            .gui => |g| @tagName(g),
        };
        const action_text = std.fmt.bufPrint(&action_buf, "{s}", .{action_str}) catch "?";
        dvui.labelNoFmt(@src(), action_text, .{}, .{ .expand = .horizontal, .id_extra = i + 1000 });
    }

    if (dvui.button(@src(), "Close [Esc]", .{}, .{})) {
        app.gui.keybinds_open = false;
    }
}

// ── Phase 5I: Context menu ────────────────────────────────────────────────────

fn drawContextMenu(app: *AppState) void {
    if (!app.gui.context_menu_open) return;

    var fw = dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{ .w = 180, .h = 160 } });
    defer fw.deinit();

    if (app.gui.context_menu_inst >= 0) {
        dvui.labelNoFmt(@src(), "Instance", .{}, .{ .style = .highlight });
        if (dvui.button(@src(), "Properties [Q]", .{}, .{})) {
            actions.enqueue(app, .{ .edit_properties = {} }, "Edit properties");
            app.gui.context_menu_open = false;
        }
        if (dvui.button(@src(), "Delete [Del]", .{}, .{ .id_extra = 1 })) {
            actions.enqueue(app, .{ .delete_selected = {} }, "Delete");
            app.gui.context_menu_open = false;
        }
        if (dvui.button(@src(), "Rotate CW [R]", .{}, .{ .id_extra = 2 })) {
            actions.enqueue(app, .{ .rotate_cw = {} }, "Rotate CW");
            app.gui.context_menu_open = false;
        }
        if (dvui.button(@src(), "Flip H [X]", .{}, .{ .id_extra = 3 })) {
            actions.enqueue(app, .{ .flip_horizontal = {} }, "Flip H");
            app.gui.context_menu_open = false;
        }
        if (dvui.button(@src(), "Move [M]", .{}, .{ .id_extra = 4 })) {
            actions.enqueue(app, .{ .move_interactive = {} }, "Move");
            app.gui.context_menu_open = false;
        }
        if (dvui.button(@src(), "Descend [E]", .{}, .{ .id_extra = 5 })) {
            actions.enqueue(app, .{ .descend_schematic = {} }, "Descend");
            app.gui.context_menu_open = false;
        }
    } else if (app.gui.context_menu_wire >= 0) {
        dvui.labelNoFmt(@src(), "Wire", .{}, .{ .style = .highlight });
        if (dvui.button(@src(), "Delete [Del]", .{}, .{})) {
            actions.enqueue(app, .{ .delete_selected = {} }, "Delete");
            app.gui.context_menu_open = false;
        }
        if (dvui.button(@src(), "Select Connected", .{}, .{ .id_extra = 1 })) {
            actions.enqueue(app, .{ .select_connected = {} }, "Select connected");
            app.gui.context_menu_open = false;
        }
    } else {
        dvui.labelNoFmt(@src(), "Canvas", .{}, .{ .style = .highlight });
        if (dvui.button(@src(), "Paste [Ctrl+V]", .{}, .{})) {
            actions.enqueue(app, .{ .clipboard_paste = {} }, "Paste");
            app.gui.context_menu_open = false;
        }
        if (dvui.button(@src(), "Insert from Library", .{}, .{ .id_extra = 1 })) {
            actions.enqueue(app, .{ .insert_from_library = {} }, "Insert from library");
            app.gui.context_menu_open = false;
        }
    }

    _ = dvui.separator(@src(), .{ .id_extra = 99 });
    if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = 99 })) {
        app.gui.context_menu_open = false;
    }
}

const KeybindAction = union(enum) {
    queue: struct { cmd: @import("../command.zig").Command, msg: []const u8 },
    gui: actions.GuiCommand,
};

const Keybind = struct {
    key: dvui.enums.Key,
    ctrl: bool,
    shift: bool,
    alt: bool,
    action: KeybindAction,
};

const static_keybinds = [_]Keybind{
    // File
    .{ .key = .n, .ctrl = true, .shift = false, .alt = false, .action = .{ .gui = .file_new } },
    .{ .key = .o, .ctrl = true, .shift = false, .alt = false, .action = .{ .gui = .file_open } },
    .{ .key = .s, .ctrl = true, .shift = false, .alt = false, .action = .{ .gui = .file_save } },
    .{ .key = .s, .ctrl = true, .shift = true, .alt = false, .action = .{ .gui = .file_save_as } },
    .{ .key = .s, .ctrl = false, .shift = false, .alt = true, .action = .{ .gui = .file_reload } },
    .{ .key = .l, .ctrl = true, .shift = false, .alt = false, .action = .{ .gui = .file_view_logs } },
    .{ .key = .n, .ctrl = true, .shift = true, .alt = false, .action = .{ .gui = .file_start_process } },
    .{ .key = .q, .ctrl = true, .shift = false, .alt = false, .action = .{ .gui = .file_exit } },
    // Tab management
    .{ .key = .t, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .new_tab = {} }, .msg = "New tab" } } },
    .{ .key = .w, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .close_tab = {} }, .msg = "Close tab" } } },
    .{ .key = .t, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .reopen_last_closed = {} }, .msg = "Reopen last closed" } } },
    // Simulation
    .{ .key = .f5, .ctrl = false, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .run_sim = .{ .sim = .ngspice } }, .msg = "Queued simulation" } } },
    .{ .key = .f6, .ctrl = false, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .plugins_refresh = {} }, .msg = "Queued plugin refresh signal" } } },
    // Zoom
    .{ .key = .equal, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .zoom_in = {} }, .msg = "Zoom in" } } },
    .{ .key = .minus, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .zoom_out = {} }, .msg = "Zoom out" } } },
    .{ .key = .zero, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .zoom_reset = {} }, .msg = "Zoom reset" } } },
    .{ .key = .f, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .zoom_fit_selected = {} }, .msg = "Zoom fit selected" } } },
    // Undo/Redo
    .{ .key = .z, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .undo = {} }, .msg = "Undo" } } },
    .{ .key = .y, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .redo = {} }, .msg = "Redo" } } },
    // Selection
    .{ .key = .a, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .select_all = {} }, .msg = "Select all" } } },
    .{ .key = .a, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .select_none = {} }, .msg = "Select none" } } },
    .{ .key = .f, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .find_select_dialog = {} }, .msg = "Find/select" } } },
    // Edit
    .{ .key = .c, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .clipboard_copy = {} }, .msg = "Copied" } } },
    .{ .key = .x, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .clipboard_cut = {} }, .msg = "Cut" } } },
    .{ .key = .v, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .clipboard_paste = {} }, .msg = "Pasted" } } },
    // Net highlight
    .{ .key = .k, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .unhighlight_selected_nets = {} }, .msg = "Unhighlighting nets" } } },
    .{ .key = .k, .ctrl = false, .shift = false, .alt = true, .action = .{ .queue = .{ .cmd = .{ .select_attached_nets = {} }, .msg = "Selecting nets" } } },
    // Move/stretch
    .{ .key = .m, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .move_interactive_stretch = {} }, .msg = "Move stretch mode" } } },
    .{ .key = .u, .ctrl = false, .shift = false, .alt = true, .action = .{ .queue = .{ .cmd = .{ .align_to_grid = {} }, .msg = "Aligned to grid" } } },
    // Snap
    .{ .key = .g, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .snap_halve = {} }, .msg = "Snap halved" } } },
    // Hierarchy
    .{ .key = .e, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .ascend = {} }, .msg = "Ascend" } } },
    .{ .key = .l, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .make_schematic_from_symbol = {} }, .msg = "Make schematic from symbol" } } },
    .{ .key = .h, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .make_schem_and_sym = {} }, .msg = "Make both" } } },
    // Netlisting
    .{ .key = .n, .ctrl = false, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .netlist_top_only = {} }, .msg = "Top netlist" } } },
    // View toggles
    .{ .key = .b, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .toggle_text_in_symbols = {} }, .msg = "Toggle text in symbols" } } },
    .{ .key = .b, .ctrl = false, .shift = false, .alt = true, .action = .{ .queue = .{ .cmd = .{ .toggle_symbol_details = {} }, .msg = "Toggle symbol details" } } },
    .{ .key = .x, .ctrl = false, .shift = false, .alt = true, .action = .{ .queue = .{ .cmd = .{ .toggle_crosshair = {} }, .msg = "Toggle crosshair" } } },
    // Wires
    .{ .key = .w, .ctrl = false, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .start_wire_snap = {} }, .msg = "Wire snap mode" } } },
    .{ .key = .l, .ctrl = false, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .toggle_orthogonal_routing = {} }, .msg = "Toggle ortho routing" } } },
    // Export
    .{ .key = .p, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .export_pdf = {} }, .msg = "Export PDF (stub)" } } },
    // Query props
    .{ .key = .q, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .view_properties = {} }, .msg = "View properties" } } },
    // Symbol pins
    .{ .key = .p, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .make_symbol_from_schematic = {} }, .msg = "Make symbol" } } },
};

/// Dispatch a key event against plugin-registered keybinds.
fn dispatchPluginKeybind(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    const key_char = keyToChar(code, false);
    if (key_char == 0) return false;
    const mods = encodeMods(ctrl, shift, alt);
    for (app.gui.plugin_keybinds.items) |kb| {
        if (key_char == kb.key and mods == kb.mods) {
            app.queue.push(.{ .plugin_command = .{ .tag = kb.cmd_tag, .payload = null } }) catch {};
            return true;
        }
    }
    return false;
}

/// Encode modifier flags into a single byte matching PluginKeybind.mods layout.
fn encodeMods(ctrl: bool, shift: bool, alt: bool) u8 {
    var m: u8 = 0;
    if (ctrl) m |= 0x01;
    if (shift) m |= 0x02;
    if (alt) m |= 0x04;
    return m;
}

fn dispatchStaticKeybind(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    for (static_keybinds) |kb| {
        if (kb.key != code or kb.ctrl != ctrl or kb.shift != shift or kb.alt != alt) continue;
        switch (kb.action) {
            .queue => |q| actions.enqueue(app, q.cmd, q.msg),
            .gui => |g| actions.runGuiCommand(app, g),
        }
        return true;
    }
    return false;
}

fn keyToChar(code: dvui.enums.Key, shift: bool) u8 {
    return switch (code) {
        .a => if (shift) 'A' else 'a',
        .b => if (shift) 'B' else 'b',
        .c => if (shift) 'C' else 'c',
        .d => if (shift) 'D' else 'd',
        .e => if (shift) 'E' else 'e',
        .f => if (shift) 'F' else 'f',
        .g => if (shift) 'G' else 'g',
        .h => if (shift) 'H' else 'h',
        .i => if (shift) 'I' else 'i',
        .j => if (shift) 'J' else 'j',
        .k => if (shift) 'K' else 'k',
        .l => if (shift) 'L' else 'l',
        .m => if (shift) 'M' else 'm',
        .n => if (shift) 'N' else 'n',
        .o => if (shift) 'O' else 'o',
        .p => if (shift) 'P' else 'p',
        .q => if (shift) 'Q' else 'q',
        .r => if (shift) 'R' else 'r',
        .s => if (shift) 'S' else 's',
        .t => if (shift) 'T' else 't',
        .u => if (shift) 'U' else 'u',
        .v => if (shift) 'V' else 'v',
        .w => if (shift) 'W' else 'w',
        .x => if (shift) 'X' else 'x',
        .y => if (shift) 'Y' else 'y',
        .z => if (shift) 'Z' else 'z',
        .zero => if (shift) ')' else '0',
        .one => if (shift) '!' else '1',
        .two => if (shift) '@' else '2',
        .three => if (shift) '#' else '3',
        .four => if (shift) '$' else '4',
        .five => if (shift) '%' else '5',
        .six => if (shift) '^' else '6',
        .seven => if (shift) '&' else '7',
        .eight => if (shift) '*' else '8',
        .nine => if (shift) '(' else '9',
        .grave => if (shift) '~' else '`',
        .minus => if (shift) '_' else '-',
        .equal => if (shift) '+' else '=',
        .left_bracket => if (shift) '{' else '[',
        .right_bracket => if (shift) '}' else ']',
        .backslash => if (shift) '|' else '\\',
        .semicolon => if (shift) ':' else ';',
        .apostrophe => if (shift) '"' else '\'',
        .comma => if (shift) '<' else ',',
        .period => if (shift) '>' else '.',
        .slash => if (shift) '?' else '/',
        .space => ' ',
        else => 0,
    };
}

// ── Persistent window rects for dialogs ───────────────────────────────────────

var props_win_rect = dvui.Rect{ .x = 120, .y = 100, .w = 480, .h = 380 };
var lib_win_rect   = dvui.Rect{ .x = 100, .y = 80,  .w = 420, .h = 460 };

// ── Phase 6F / 7B — Properties dialog ────────────────────────────────────────

fn drawPropertiesDialog(app: *AppState) void {
    const gs = &app.gui;

    var fwin = dvui.floatingWindow(@src(), .{
        .modal     = true,
        .open_flag = &gs.props_dialog_open,
        .rect      = &props_win_rect,
    }, .{
        .min_size_content = .{ .w = 380, .h = 260 },
    });
    defer fwin.deinit();

    const title = if (gs.props_view_only) "Instance Properties (read-only)" else "Instance Properties";
    fwin.dragAreaSet(dvui.windowHeader(title, "", &gs.props_dialog_open));

    const fio = app.active();
    const CT = @import("../state.zig").CT;
    const inst_opt: ?CT.Instance = if (fio) |f| blk: {
        const sch = f.schematic();
        if (gs.props_inst_idx < sch.instances.items.len)
            break :blk sch.instances.items[gs.props_inst_idx]
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

            if (gs.props_view_only) {
                const val_slice = gs.props_bufs[i][0..gs.props_lens[i]];
                dvui.labelNoFmt(@src(), val_slice, .{}, .{
                    .id_extra  = i * 10 + 3,
                    .expand    = .horizontal,
                    .gravity_y = 0.5,
                });
            } else {
                var te = dvui.textEntry(@src(), .{
                    .text = .{ .buffer = gs.props_bufs[i][0..127] },
                }, .{
                    .id_extra = i * 10 + 3,
                    .expand   = .horizontal,
                });
                defer te.deinit();
                gs.props_lens[i] = std.mem.indexOfScalar(u8, &gs.props_bufs[i], 0) orelse 127;
                gs.props_dirty[i] = true;
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

            if (!gs.props_view_only) {
                if (dvui.button(@src(), "OK", .{}, .{ .id_extra = 100, .style = .highlight })) {
                    if (fio) |f| {
                        if (inst_opt) |inst| {
                            const pc = @min(inst.props.items.len, 16);
                            for (0..pc) |i| {
                                const key = inst.props.items[i].key;
                                const buf_len = std.mem.indexOfScalar(u8, &gs.props_bufs[i], 0) orelse gs.props_lens[i];
                                const val = gs.props_bufs[i][0..buf_len];
                                f.setProp(gs.props_inst_idx, key, val) catch {};
                            }
                        }
                    }
                    app.setStatus("Properties updated");
                    gs.props_dialog_open = false;
                }
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });
            }

            if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = 101 })) {
                gs.props_dialog_open = false;
                app.setStatus("Properties canceled");
            }
        }
    }
}

// ── Phase 7A — Library browser ────────────────────────────────────────────────

fn drawLibraryBrowser(app: *AppState) void {
    const gs = &app.gui;

    var fwin = dvui.floatingWindow(@src(), .{
        .modal     = true,
        .open_flag = &gs.lib_browser_open,
        .rect      = &lib_win_rect,
    }, .{
        .min_size_content = .{ .w = 320, .h = 360 },
    });
    defer fwin.deinit();

    fwin.dragAreaSet(dvui.windowHeader("Library Browser", "", &gs.lib_browser_open));

    {
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand  = .both,
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
        });
        defer body.deinit();

        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            dvui.labelNoFmt(@src(), "Search:", .{}, .{ .gravity_y = 0.5 });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 } });
            var te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = gs.lib_search_buf[0..127] },
            }, .{ .expand = .horizontal });
            defer te.deinit();
            gs.lib_search_len = std.mem.indexOfScalar(u8, &gs.lib_search_buf, 0) orelse 0;
        }

        _ = dvui.separator(@src(), .{ .id_extra = 1 });

        if (gs.lib_entry_count == 0) {
            dvui.labelNoFmt(@src(), "No .chn_sym files found in symbols/", .{}, .{ .style = .control });
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        const search_text = gs.lib_search_buf[0..gs.lib_search_len];

        for (0..gs.lib_entry_count) |i| {
            const entry_name = std.mem.sliceTo(&gs.lib_entries[i], 0);

            if (search_text.len > 0) {
                var found = false;
                if (entry_name.len >= search_text.len) {
                    var si: usize = 0;
                    while (si + search_text.len <= entry_name.len) : (si += 1) {
                        var match = true;
                        for (search_text, 0..) |sc, j| {
                            if (std.ascii.toLower(entry_name[si + j]) != std.ascii.toLower(sc)) {
                                match = false;
                                break;
                            }
                        }
                        if (match) { found = true; break; }
                    }
                }
                if (!found) continue;
            }

            const is_selected = gs.lib_selected == @as(i32, @intCast(i));

            var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra   = i,
                .expand     = .horizontal,
                .background = true,
                .border     = .{ .x = 1, .y = 1, .w = 1, .h = 1 },
                .padding    = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
                .margin     = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
                .color_fill = if (is_selected)
                    .{ .r = 38, .g = 52, .b = 90, .a = 255 }
                else
                    .{ .r = 36, .g = 36, .b = 42, .a = 0 },
            });
            defer card.deinit();

            dvui.labelNoFmt(@src(), entry_name, .{}, .{
                .id_extra  = i * 10 + 1,
                .expand    = .horizontal,
                .gravity_y = 0.5,
            });

            if (dvui.button(@src(), "Select", .{}, .{ .id_extra = i * 10 + 2 })) {
                gs.lib_selected = @intCast(i);
            }
        }

        _ = dvui.separator(@src(), .{ .id_extra = 20 });

        {
            var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
            });
            defer btn_row.deinit();

            _ = dvui.spacer(@src(), .{ .expand = .horizontal });

            if (dvui.button(@src(), "Place", .{}, .{ .id_extra = 200, .style = .highlight })) {
                if (gs.lib_selected >= 0 and @as(usize, @intCast(gs.lib_selected)) < gs.lib_entry_count) {
                    const sel_idx: usize = @intCast(gs.lib_selected);
                    const sym_name = std.mem.sliceTo(&gs.lib_entries[sel_idx], 0);
                    app.queue.push(.{ .place_device = .{
                        .sym_path = sym_name,
                        .name     = sym_name,
                        .x        = 0,
                        .y        = 0,
                    } }) catch {};
                    app.setStatus("Symbol placed");
                    gs.lib_browser_open = false;
                } else {
                    app.setStatus("No symbol selected");
                }
            }

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });

            if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = 201 })) {
                gs.lib_browser_open = false;
                app.setStatus("Library browser closed");
            }
        }
    }
}
