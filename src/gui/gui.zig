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
const find_dialog = @import("find_dialog.zig");
const context_menu = @import("context_menu.zig");
const keybinds_dialog = @import("keybinds_dialog.zig");
const props_dialog = @import("props_dialog.zig");
const library_browser = @import("library_browser.zig");

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
    find_dialog.draw(app);
    keybinds_dialog.draw(app);
    context_menu.draw(app);
    if (props_dialog.state.open) props_dialog.draw(app);
    if (library_browser.state.open) library_browser.draw(app);
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
    if (find_dialog.state.open) {
        switch (code) {
            .escape => { find_dialog.state.open = false; return true; },
            .enter => {
                find_dialog.runFindQuery(app);
                return true;
            },
            .backspace => {
                if (find_dialog.state.query_len > 0) find_dialog.state.query_len -= 1;
                return true;
            },
            else => {
                const ch = keybinds_dialog.keyToChar(code, shift);
                if (ch != 0 and find_dialog.state.query_len < find_dialog.state.query.len - 1) {
                    find_dialog.state.query[find_dialog.state.query_len] = ch;
                    find_dialog.state.query_len += 1;
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
            const ch = keybinds_dialog.keyToChar(code, shift);
            if (ch == 0 or app.gui.command_len >= app.gui.command_buf.len - 1) return false;
            app.gui.command_buf[app.gui.command_len] = ch;
            app.gui.command_len += 1;
            return true;
        },
    }
}

fn handleNormalMode(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    // Plugin keybinds take priority
    if (keybinds_dialog.dispatchPlugin(app, code, ctrl, shift, alt)) return true;

    const plain = !ctrl and !shift and !alt;
    if (plain and plugin_panels.handlePlainKeyToggle(app, keybinds_dialog.keyToChar(code, false))) return true;
    if (keybinds_dialog.dispatchStatic(app, code, ctrl, shift, alt)) return true;

    switch (code) {
        .semicolon => if (shift) {
            app.gui.command_mode = true;
            app.gui.command_len = 0;
            @memset(&app.gui.command_buf, 0);
            app.status_msg = "Command mode";
            return true;
        } else return false,
        .escape => {
            if (find_dialog.state.open) { find_dialog.state.open = false; return true; }
            if (keybinds_dialog.state.open) { keybinds_dialog.state.open = false; return true; }
            if (context_menu.state.open) { context_menu.state.open = false; return true; }
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
