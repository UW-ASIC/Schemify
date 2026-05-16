const std = @import("std");
const command = @import("commands");
const parser = command.parser;
const st = @import("state");
const AppState = st.AppState;

pub const GuiCommand = enum {
    view_schematic, view_symbol, view_doc,
    file_open,
};

// ── Public API ───────────────────────────────────────────────────────────────

pub fn enqueue(app: *AppState, cmd: command.Command, ok_msg: []const u8) void {
    const alloc = app.gpa.allocator();
    app.queue.push(alloc, cmd) catch { app.status_msg = "Command queue is full"; return; };
    app.status_msg = ok_msg;
}

pub fn runGuiCommand(app: *AppState, gui_cmd: GuiCommand) void {
    switch (gui_cmd) {
        .view_schematic => { app.gui.hot.view_mode = .schematic; app.status_msg = "Schematic view"; },
        .view_symbol => { app.gui.hot.view_mode = .symbol; app.status_msg = "Symbol view"; },
        .view_doc => { app.gui.hot.view_mode = .doc; app.status_msg = "Documentation view"; },
        .file_open => { app.open_file_explorer = true; },
    }
}

// ── Vim command table ────────────────────────────────────────────────────────

const VimAction = union(enum) {
    queue: struct { cmd: command.Command, msg: []const u8 },
    gui: GuiCommand,
};

const vim_noarg_entries = [_]struct { []const u8, VimAction }{
    .{ "zoomin", .{ .queue = .{ .cmd = .{ .immediate = .zoom_in }, .msg = "Zoom in" } } },
    .{ "zoomout", .{ .queue = .{ .cmd = .{ .immediate = .zoom_out }, .msg = "Zoom out" } } },
    .{ "zoomfit", .{ .queue = .{ .cmd = .{ .immediate = .zoom_fit }, .msg = "Zoom fit" } } },
    .{ "zoomreset", .{ .queue = .{ .cmd = .{ .immediate = .zoom_reset }, .msg = "Zoom reset" } } },
    .{ "undo", .{ .queue = .{ .cmd = .{ .immediate = .undo }, .msg = "Undo" } } },
    .{ "redo", .{ .queue = .{ .cmd = .{ .immediate = .redo }, .msg = "Redo" } } },
    .{ "selectall", .{ .queue = .{ .cmd = .{ .immediate = .select_all }, .msg = "Select all" } } },
    .{ "selectnone", .{ .queue = .{ .cmd = .{ .immediate = .select_none }, .msg = "Select none" } } },
    .{ "delete", .{ .queue = .{ .cmd = .{ .undoable = .delete_selected }, .msg = "Delete" } } },
    .{ "duplicate", .{ .queue = .{ .cmd = .{ .undoable = .duplicate_selected }, .msg = "Duplicate" } } },
    .{ "rotcw", .{ .queue = .{ .cmd = .{ .undoable = .rotate_cw }, .msg = "Rotate CW" } } },
    .{ "rotccw", .{ .queue = .{ .cmd = .{ .undoable = .rotate_ccw }, .msg = "Rotate CCW" } } },
    .{ "fliph", .{ .queue = .{ .cmd = .{ .undoable = .flip_horizontal }, .msg = "Flip H" } } },
    .{ "flipv", .{ .queue = .{ .cmd = .{ .undoable = .flip_vertical }, .msg = "Flip V" } } },
    .{ "tabnew", .{ .queue = .{ .cmd = .{ .immediate = .new_tab }, .msg = "New tab" } } },
    .{ "tabclose", .{ .queue = .{ .cmd = .{ .immediate = .close_tab }, .msg = "Close tab" } } },
    .{ "tabnext", .{ .queue = .{ .cmd = .{ .immediate = .next_tab }, .msg = "Next tab" } } },
    .{ "tabprev", .{ .queue = .{ .cmd = .{ .immediate = .prev_tab }, .msg = "Prev tab" } } },
    .{ "wire", .{ .queue = .{ .cmd = .{ .immediate = .start_wire }, .msg = "Wire mode" } } },
    .{ "netlist", .{ .queue = .{ .cmd = .{ .immediate = .netlist_hierarchical }, .msg = "Netlist" } } },
    .{ "descend", .{ .queue = .{ .cmd = .{ .immediate = .descend_schematic }, .msg = "Descend" } } },
    .{ "ascend", .{ .queue = .{ .cmd = .{ .immediate = .ascend }, .msg = "Ascend" } } },
    .{ "back", .{ .queue = .{ .cmd = .{ .immediate = .ascend }, .msg = "Ascend" } } },
    .{ "props", .{ .queue = .{ .cmd = .{ .immediate = .edit_properties }, .msg = "Properties" } } },
    .{ "explorer", .{ .queue = .{ .cmd = .{ .immediate = .open_file_explorer }, .msg = "Files" } } },
    .{ "files", .{ .queue = .{ .cmd = .{ .immediate = .open_file_explorer }, .msg = "Files" } } },
    .{ "find", .{ .queue = .{ .cmd = .{ .immediate = .find_select_dialog }, .msg = "Find" } } },
    .{ "insert", .{ .queue = .{ .cmd = .{ .immediate = .insert_from_library }, .msg = "Library" } } },
    .{ "fullscreen", .{ .queue = .{ .cmd = .{ .immediate = .toggle_fullscreen }, .msg = "Fullscreen" } } },
    .{ "keybinds", .{ .queue = .{ .cmd = .{ .immediate = .show_keybinds }, .msg = "Keybinds" } } },
    .{ "help", .{ .queue = .{ .cmd = .{ .immediate = .show_keybinds }, .msg = "Help" } } },
    .{ "exportpdf", .{ .queue = .{ .cmd = .{ .immediate = .export_pdf }, .msg = "Export PDF" } } },
    .{ "exportpng", .{ .queue = .{ .cmd = .{ .immediate = .export_png }, .msg = "Export PNG" } } },
    .{ "exportsvg", .{ .queue = .{ .cmd = .{ .immediate = .export_svg }, .msg = "Export SVG" } } },
    .{ "reload", .{ .queue = .{ .cmd = .{ .immediate = .reload_from_disk }, .msg = "Reloading" } } },
    .{ "e!", .{ .queue = .{ .cmd = .{ .immediate = .reload_from_disk }, .msg = "Reloading" } } },
    .{ "pluginsreload", .{ .queue = .{ .cmd = .{ .immediate = .plugins_refresh }, .msg = "Plugin refresh" } } },
    .{ "clipcopy", .{ .queue = .{ .cmd = .{ .immediate = .clipboard_copy }, .msg = "Copied" } } },
    .{ "clipcut", .{ .queue = .{ .cmd = .{ .immediate = .clipboard_cut }, .msg = "Cut" } } },
    .{ "clippaste", .{ .queue = .{ .cmd = .{ .immediate = .clipboard_paste }, .msg = "Pasted" } } },
    .{ "newprim", .{ .queue = .{ .cmd = .{ .immediate = .open_new_prim_dialog }, .msg = "New Primitive" } } },
    .{ "spicecode", .{ .queue = .{ .cmd = .{ .immediate = .open_spice_code_dialog }, .msg = "Spice code" } } },
    .{ "marketplace", .{ .queue = .{ .cmd = .{ .immediate = .open_marketplace }, .msg = "Marketplace" } } },
    .{ "settings", .{ .queue = .{ .cmd = .{ .immediate = .open_preferences }, .msg = "Settings" } } },
    .{ "preferences", .{ .queue = .{ .cmd = .{ .immediate = .open_preferences }, .msg = "Settings" } } },
    .{ "saveas", .{ .queue = .{ .cmd = .{ .immediate = .file_save_as }, .msg = "Save as" } } },
    .{ "saveall", .{ .queue = .{ .cmd = .{ .immediate = .file_save_all }, .msg = "Saved all" } } },
    .{ "schematic", .{ .gui = .view_schematic } },
    .{ "symbol", .{ .gui = .view_symbol } },
    .{ "doc", .{ .gui = .view_doc } },
    .{ "documentation", .{ .gui = .view_doc } },
};

const vim_noarg_map = std.StaticStringMap(VimAction).initComptime(&vim_noarg_entries);

pub fn runVimCommand(app: *AppState, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) { app.status_msg = "Ready"; return; }

    // Legacy vim-bar entries (for GUI-only commands like view_schematic/view_symbol).
    var parts = std.mem.splitScalar(u8, trimmed, ' ');
    const name = parts.next() orelse return;
    const rest = std.mem.trim(u8, parts.rest(), " \t");

    if (vim_noarg_map.get(name)) |action| {
        switch (action) {
            .queue => |q| enqueue(app, q.cmd, q.msg),
            .gui => |gg| runGuiCommand(app, gg),
        }
        return;
    }

    // Plugin vim commands
    const plugin_panels = @import("PluginPanels.zig");
    if (plugin_panels.tryHandleVim(app, name)) return;

    // Use the shared parser for everything else (covers all commands).
    const result = parser.parse(trimmed);
    switch (result) {
        .command => |cmd| enqueue(app, cmd, "OK"),
        .meta => |m| switch (m) {
            .quit => {
                app.status_msg = "Exiting";
                app.quit_requested = true;
            },
            .save => enqueue(app, .{ .immediate = .file_save }, "Save"),
            .list_commands => { app.status_msg = "Use --commands from CLI"; },
            else => { app.status_msg = "Command available in CLI mode"; },
        },
        .meta_arg => |ma| switch (ma) {
            .set_snap => |v| {
                app.tool.snap_size = v;
                app.status_msg = "Snap size set";
            },
            .open_file => {
                app.open_file_explorer = true;
                app.status_msg = "Open file";
            },
            .select_instance => |idx| {
                const doc = app.active() orelse return;
                if (idx >= doc.sch.instances.len) { app.status_msg = "Index out of range"; return; }
                doc.selection.ensureCapacity(app.allocator(), doc.sch.instances.len, doc.sch.wires.len, false) catch return;
                doc.selection.instances.set(idx);
                app.status_msg = "Instance selected";
            },
            .select_wire => |idx| {
                const doc = app.active() orelse return;
                if (idx >= doc.sch.wires.len) { app.status_msg = "Index out of range"; return; }
                doc.selection.ensureCapacity(app.allocator(), doc.sch.instances.len, doc.sch.wires.len, false) catch return;
                doc.selection.wires.set(idx);
                app.status_msg = "Wire selected";
            },
            .saveas => |path| {
                app.saveActiveTo(path) catch {
                    app.status_msg = "Save failed";
                    return;
                };
                // Update doc name to match new path
                if (app.active()) |doc| {
                    const a = app.gpa.allocator();
                    const owned = a.dupe(u8, path) catch {
                        app.status_msg = "Saved (name update failed)";
                        return;
                    };
                    a.free(doc.name);
                    doc.name = owned;
                }
                app.status_msg = "Saved";
            },
            else => { app.status_msg = "OK"; },
        },
        .err => |msg| {
            if (msg.len > 0) {
                app.status_msg = msg;
            }
        },
    }

    // Plugin-registered commands (fallback).
    _ = rest;
    for (app.gui.cold.plugin_commands.items) |pc| {
        if (!std.mem.eql(u8, pc.id, name)) continue;
        const pr = std.mem.trim(u8, parts.rest(), " \t");
        enqueue(app, .{ .immediate = .{ .plugin_command = .{ .tag = pc.id, .payload = pr } } }, pc.display_name);
        return;
    }
}
