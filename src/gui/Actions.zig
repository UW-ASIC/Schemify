//! Actions — command dispatch, GUI commands, and vim-style command parsing.
//!
//! Pure GUI-layer actions that either enqueue a command or mutate GUI state
//! directly.  No rendering — this is the "controller" half.

const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const dvui = @import("dvui");
const command = @import("commands");
const st = @import("state");
const AppState = st.AppState;

/// Commands that are handled directly by the GUI layer (not queued).
pub const GuiCommand = enum {
    view_schematic,
    view_symbol,
    file_new,
    file_open,
    file_save,
    file_save_as,
    file_reload,
    file_clear,
    file_view_logs,
    file_start_process,
    file_exit,
};

// ── Vim no-arg command table ───────────────────────────────────────────────

const VimAction = union(enum) {
    queue: struct { cmd: command.Command, msg: []const u8 },
    gui: GuiCommand,
};

const vim_noarg_entries = [_]struct { []const u8, VimAction }{
    // Zoom
    .{ "zoomin", .{ .queue = .{ .cmd = .{ .immediate = .zoom_in }, .msg = "Queued zoom in" } } },
    .{ "zoomout", .{ .queue = .{ .cmd = .{ .immediate = .zoom_out }, .msg = "Queued zoom out" } } },
    .{ "zoomfit", .{ .queue = .{ .cmd = .{ .immediate = .zoom_fit }, .msg = "Queued zoom fit" } } },
    .{ "zoomreset", .{ .queue = .{ .cmd = .{ .immediate = .zoom_reset }, .msg = "Queued zoom reset" } } },
    .{ "zoomsel", .{ .queue = .{ .cmd = .{ .immediate = .zoom_fit_selected }, .msg = "Queued zoom fit selected" } } },
    // Undo/redo
    .{ "undo", .{ .queue = .{ .cmd = .{ .immediate = .undo }, .msg = "Queued undo" } } },
    .{ "redo", .{ .queue = .{ .cmd = .{ .immediate = .redo }, .msg = "Queued redo" } } },
    // Selection
    .{ "selectall", .{ .queue = .{ .cmd = .{ .immediate = .select_all }, .msg = "Queued select all" } } },
    .{ "selectnone", .{ .queue = .{ .cmd = .{ .immediate = .select_none }, .msg = "Queued select none" } } },
    .{ "delete", .{ .queue = .{ .cmd = .{ .undoable = .delete_selected }, .msg = "Queued delete" } } },
    .{ "duplicate", .{ .queue = .{ .cmd = .{ .undoable = .duplicate_selected }, .msg = "Queued duplicate" } } },
    // Rotation/flip
    .{ "rotcw", .{ .queue = .{ .cmd = .{ .undoable = .rotate_cw }, .msg = "Queued rotate CW" } } },
    .{ "rotccw", .{ .queue = .{ .cmd = .{ .undoable = .rotate_ccw }, .msg = "Queued rotate CCW" } } },
    .{ "fliph", .{ .queue = .{ .cmd = .{ .undoable = .flip_horizontal }, .msg = "Queued flip horizontal" } } },
    .{ "flipv", .{ .queue = .{ .cmd = .{ .undoable = .flip_vertical }, .msg = "Queued flip vertical" } } },
    // Nudge
    .{ "left", .{ .queue = .{ .cmd = .{ .undoable = .nudge_left }, .msg = "Queued nudge left" } } },
    .{ "right", .{ .queue = .{ .cmd = .{ .undoable = .nudge_right }, .msg = "Queued nudge right" } } },
    .{ "up", .{ .queue = .{ .cmd = .{ .undoable = .nudge_up }, .msg = "Queued nudge up" } } },
    .{ "down", .{ .queue = .{ .cmd = .{ .undoable = .nudge_down }, .msg = "Queued nudge down" } } },
    // Tabs
    .{ "tabnew", .{ .queue = .{ .cmd = .{ .immediate = .new_tab }, .msg = "Queued new tab" } } },
    .{ "tabclose", .{ .queue = .{ .cmd = .{ .immediate = .close_tab }, .msg = "Queued close tab" } } },
    .{ "tabnext", .{ .queue = .{ .cmd = .{ .immediate = .next_tab }, .msg = "Queued next tab" } } },
    .{ "tabprev", .{ .queue = .{ .cmd = .{ .immediate = .prev_tab }, .msg = "Queued previous tab" } } },
    .{ "tabreopen", .{ .queue = .{ .cmd = .{ .immediate = .reopen_last_closed }, .msg = "Queued reopen" } } },
    // Wires
    .{ "wire", .{ .queue = .{ .cmd = .{ .immediate = .start_wire }, .msg = "Wire mode" } } },
    .{ "wiresnap", .{ .queue = .{ .cmd = .{ .immediate = .start_wire_snap }, .msg = "Wire mode (snap)" } } },
    .{ "breakwires", .{ .queue = .{ .cmd = .{ .immediate = .break_wires_at_connections }, .msg = "Queued break wires" } } },
    .{ "joinwires", .{ .queue = .{ .cmd = .{ .immediate = .join_collapse_wires }, .msg = "Queued join wires" } } },
    .{ "orthoroute", .{ .queue = .{ .cmd = .{ .immediate = .toggle_orthogonal_routing }, .msg = "Toggle ortho" } } },
    // Drawing
    .{ "line", .{ .queue = .{ .cmd = .{ .immediate = .start_line }, .msg = "Line draw mode" } } },
    .{ "rect", .{ .queue = .{ .cmd = .{ .immediate = .start_rect }, .msg = "Rect draw mode" } } },
    .{ "text", .{ .queue = .{ .cmd = .{ .immediate = .place_text }, .msg = "Place text" } } },
    // Hierarchy
    .{ "descend", .{ .queue = .{ .cmd = .{ .immediate = .descend_schematic }, .msg = "Descend into schematic" } } },
    .{ "ascend", .{ .queue = .{ .cmd = .{ .immediate = .ascend }, .msg = "Ascend to parent" } } },
    .{ "back", .{ .queue = .{ .cmd = .{ .immediate = .ascend }, .msg = "Ascend to parent" } } },
    .{ "descsym", .{ .queue = .{ .cmd = .{ .immediate = .descend_symbol }, .msg = "Descend into symbol" } } },
    .{ "edittab", .{ .queue = .{ .cmd = .{ .immediate = .edit_in_new_tab }, .msg = "Edit in new tab" } } },
    // Properties
    .{ "props", .{ .queue = .{ .cmd = .{ .immediate = .edit_properties }, .msg = "Edit properties" } } },
    .{ "viewprops", .{ .queue = .{ .cmd = .{ .immediate = .view_properties }, .msg = "View properties" } } },
    // Netlist
    .{ "netlist", .{ .queue = .{ .cmd = .{ .immediate = .netlist_hierarchical }, .msg = "Generating hierarchical netlist" } } },
    .{ "netlsttop", .{ .queue = .{ .cmd = .{ .immediate = .netlist_top_only }, .msg = "Generating top-only netlist" } } },
    .{ "toggleflat", .{ .queue = .{ .cmd = .{ .immediate = .toggle_flat_netlist }, .msg = "Toggled flat netlist" } } },
    // Net highlighting
    .{ "hilight", .{ .queue = .{ .cmd = .{ .immediate = .highlight_selected_nets }, .msg = "Highlighting nets" } } },
    .{ "unhilight", .{ .queue = .{ .cmd = .{ .immediate = .unhighlight_selected_nets }, .msg = "Unhighlighting nets" } } },
    .{ "unhilightall", .{ .queue = .{ .cmd = .{ .immediate = .unhighlight_all }, .msg = "Unhighlighting all" } } },
    .{ "selnet", .{ .queue = .{ .cmd = .{ .immediate = .select_attached_nets }, .msg = "Selecting attached nets" } } },
    // Symbol/schematic creation
    .{ "makesym", .{ .queue = .{ .cmd = .{ .immediate = .make_symbol_from_schematic }, .msg = "Making symbol" } } },
    .{ "makesch", .{ .queue = .{ .cmd = .{ .immediate = .make_schematic_from_symbol }, .msg = "Making schematic" } } },
    // Library/find
    .{ "insert", .{ .queue = .{ .cmd = .{ .immediate = .insert_from_library }, .msg = "Opening library" } } },
    .{ "explorer", .{ .queue = .{ .cmd = .{ .immediate = .open_file_explorer }, .msg = "File explorer" } } },
    .{ "files", .{ .queue = .{ .cmd = .{ .immediate = .open_file_explorer }, .msg = "File explorer" } } },
    .{ "find", .{ .queue = .{ .cmd = .{ .immediate = .find_select_dialog }, .msg = "Find/select" } } },
    // View toggles
    .{ "fullscreen", .{ .queue = .{ .cmd = .{ .immediate = .toggle_fullscreen }, .msg = "Queued toggle fullscreen" } } },
    .{ "darkmode", .{ .queue = .{ .cmd = .{ .immediate = .toggle_colorscheme }, .msg = "Queued toggle colorscheme" } } },
    .{ "shownetlist", .{ .queue = .{ .cmd = .{ .immediate = .toggle_show_netlist }, .msg = "Toggle netlist display" } } },
    .{ "crosshair", .{ .queue = .{ .cmd = .{ .immediate = .toggle_crosshair }, .msg = "Toggle crosshair" } } },
    // Snap
    .{ "snapdouble", .{ .queue = .{ .cmd = .{ .immediate = .snap_double }, .msg = "Snap doubled" } } },
    .{ "snaphalve", .{ .queue = .{ .cmd = .{ .immediate = .snap_halve }, .msg = "Snap halved" } } },
    // Export
    .{ "exportpdf", .{ .queue = .{ .cmd = .{ .immediate = .export_pdf }, .msg = "Queued export PDF" } } },
    .{ "exportpng", .{ .queue = .{ .cmd = .{ .immediate = .export_png }, .msg = "Queued export PNG" } } },
    .{ "exportsvg", .{ .queue = .{ .cmd = .{ .immediate = .export_svg }, .msg = "Queued export SVG" } } },
    // Edit operations
    .{ "move", .{ .queue = .{ .cmd = .{ .immediate = .move_interactive }, .msg = "Move mode" } } },
    .{ "copy", .{ .queue = .{ .cmd = .{ .immediate = .copy_selected }, .msg = "Copy mode" } } },
    .{ "clipcopy", .{ .queue = .{ .cmd = .{ .immediate = .clipboard_copy }, .msg = "Copied to clipboard" } } },
    .{ "clipcut", .{ .queue = .{ .cmd = .{ .immediate = .clipboard_cut }, .msg = "Cut to clipboard" } } },
    .{ "clippaste", .{ .queue = .{ .cmd = .{ .immediate = .clipboard_paste }, .msg = "Pasted from clipboard" } } },
    .{ "aligngrid", .{ .queue = .{ .cmd = .{ .immediate = .align_to_grid }, .msg = "Aligned to grid" } } },
    // Help
    .{ "keybinds", .{ .queue = .{ .cmd = .{ .immediate = .show_keybinds }, .msg = "Keybind help" } } },
    .{ "help", .{ .queue = .{ .cmd = .{ .immediate = .show_keybinds }, .msg = "Keybind help" } } },
    // Waveform
    .{ "waveview", .{ .queue = .{ .cmd = .{ .immediate = .open_waveform_viewer }, .msg = "Opening waveform viewer" } } },
    .{ "wave", .{ .queue = .{ .cmd = .{ .immediate = .open_waveform_viewer }, .msg = "Opening waveform viewer" } } },
    // Refdes
    .{ "duprefdes", .{ .queue = .{ .cmd = .{ .immediate = .highlight_dup_refdes }, .msg = "Highlighting duplicate refdes" } } },
    .{ "fixrefdes", .{ .queue = .{ .cmd = .{ .immediate = .rename_dup_refdes }, .msg = "Renaming duplicate refdes" } } },
    // Plugins
    .{ "pluginsreload", .{ .queue = .{ .cmd = .{ .immediate = .plugins_refresh }, .msg = "Queued plugin refresh signal" } } },
    .{ "plugreload", .{ .queue = .{ .cmd = .{ .immediate = .plugins_refresh }, .msg = "Queued plugin refresh signal" } } },
    // View mode
    .{ "schematic", .{ .gui = .view_schematic } },
    .{ "symbol", .{ .gui = .view_symbol } },
    // File (no-arg variants)
    .{ "reload", .{ .queue = .{ .cmd = .{ .immediate = .reload_from_disk }, .msg = "Reloading" } } },
    .{ "e!", .{ .queue = .{ .cmd = .{ .immediate = .reload_from_disk }, .msg = "Reloading" } } },
    .{ "clear", .{ .queue = .{ .cmd = .{ .immediate = .clear_schematic }, .msg = "Queued clear schematic" } } },
};

/// O(1) comptime-hashed map from vim command name to VimAction.
const vim_noarg_map = std.StaticStringMap(VimAction).initComptime(&vim_noarg_entries);

// ── Vim commands that require arguments ────────────────────────────────────

fn cmdQuit(app: *AppState, _: []const u8) void {
    runGuiCommand(app, .file_exit);
}

fn cmdGrid(app: *AppState, _: []const u8) void {
    app.show_grid = !app.show_grid;
    app.status_msg = if (app.show_grid) "Grid on" else "Grid off";
}

fn cmdSnap(app: *AppState, rest: []const u8) void {
    const v = std.fmt.parseFloat(f64, rest) catch {
        app.status_msg = "Usage: :snap <value>";
        return;
    };
    app.tool.snap_size = @as(f32, @floatCast(v));
    app.status_msg = "Snap size set";
}

/// Comptime dispatch table for vim commands that take arguments.
const vim_arg_handlers = .{
    .{ "q", cmdQuit },
    .{ "quit", cmdQuit },
    .{ "grid", cmdGrid },
    .{ "snap", cmdSnap },
};

// ── Public API ─────────────────────────────────────────────────────────────

/// Push a command onto the app queue and update the status message.
pub fn enqueue(app: *AppState, cmd: command.Command, ok_msg: []const u8) void {
    const alloc = app.gpa.allocator();
    app.queue.push(alloc, cmd) catch {
        app.status_msg = "Command queue is full";
        return;
    };
    app.status_msg = ok_msg;
}

/// Execute a GUI-layer command immediately (not queued through the command system).
pub fn runGuiCommand(app: *AppState, gui_cmd: GuiCommand) void {
    switch (gui_cmd) {
        .view_schematic => {
            app.gui.view_mode = .schematic;
            app.status_msg = "Viewing schematic";
        },
        .view_symbol => {
            app.gui.view_mode = .symbol;
            app.status_msg = "Viewing symbol";
        },
        .file_new => {
            app.status_msg = "New file";
        },
        .file_open => {
            app.open_file_explorer = true;
        },
        .file_save => {
            app.status_msg = "Save";
        },
        .file_save_as => {
            app.status_msg = "Save as";
        },
        .file_reload => enqueue(app, .{ .immediate = .reload_from_disk }, "Reloading from disk"),
        .file_clear => enqueue(app, .{ .immediate = .clear_schematic }, "Queued clear schematic"),
        .file_view_logs => {
            app.status_msg = "Log dumped to stderr";
        },
        .file_start_process => {
            if (comptime is_wasm) {
                app.status_msg = "Not supported on web";
            } else {
                app.status_msg = "Starting new process";
            }
        },
        .file_exit => {
            app.status_msg = "Exiting";
            if (comptime !is_wasm) std.process.exit(0);
        },
    }
}

/// Parse and execute a vim-style colon command from the command bar.
pub fn runVimCommand(app: *AppState, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) {
        app.status_msg = "Ready";
        return;
    }

    var parts = std.mem.splitScalar(u8, trimmed, ' ');
    const name = parts.next() orelse return;
    const rest = std.mem.trim(u8, parts.rest(), " \t");

    if (vim_noarg_map.get(name)) |action| {
        switch (action) {
            .queue => |q| enqueue(app, q.cmd, q.msg),
            .gui => |g| runGuiCommand(app, g),
        }
        return;
    }

    // Plugin vim commands
    const plugin_panels = @import("PluginPanels.zig");
    if (plugin_panels.tryHandleVim(app, name)) return;

    inline for (vim_arg_handlers) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            entry[1](app, rest);
            return;
        }
    }

    // Plugin-registered commands
    for (app.gui.plugin_commands.items) |pc| {
        if (!std.mem.eql(u8, pc.id, name)) continue;
        enqueue(app, .{ .immediate = .{ .plugin_command = .{ .tag = pc.id, .payload = rest } } }, pc.display_name);
        return;
    }

    app.status_msg = "Unknown command";
}
