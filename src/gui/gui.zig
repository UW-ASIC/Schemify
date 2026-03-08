//! GUI shell — toolbar, tabbar, renderer, command bar.
//!
//! Frame layout order:
//!   toolbar -> tabbar -> { left_sidebar | { renderer / bottom_bar } | right_sidebar }
//!   -> command_bar -> overlays -> marketplace

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
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
}

/// Center column: renderer on top, optional bottom bar below.
fn drawCenterColumn(app: *AppState) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer col.deinit();
    renderer.draw(app);
    plugin_panels.drawBottomBar(app);
    drawNetlistPreview(app);
}

/// Netlist preview panel — shown when show_netlist is true and last_netlist_len > 0.
fn drawNetlistPreview(app: *AppState) void {
    if (!app.cmd_flags.show_netlist) return;
    if (app.last_netlist_len == 0) return;

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = .{ .r = 20, .g = 20, .b = 24, .a = 255 },
        .min_size_content = .{ .h = 200 },
        .expand = .horizontal,
    });
    defer panel.deinit();

    dvui.labelNoFmt(@src(), "Netlist Preview", .{}, .{});

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .min_size_content = .{ .h = 170 },
    });
    defer scroll.deinit();

    const text = app.last_netlist[0..app.last_netlist_len];
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_i: u32 = 0;
    while (lines.next()) |line| {
        dvui.labelNoFmt(@src(), line, .{}, .{ .id_extra = 0x7E00 + line_i });
        line_i += 1;
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
