//! Actions — command dispatch, GUI commands, and vim-style command parsing.

const std = @import("std");
const dvui = @import("dvui");
const command = @import("../command.zig");
const AppState = @import("../state.zig").AppState;
const Sim = @import("../state.zig").Sim;
const plugin_panels = @import("plugin_panels.zig");

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

/// Push a command onto the app queue and update the status message.
pub fn enqueue(app: *AppState, cmd: command.Command, ok_msg: []const u8) void {
    app.queue.push(cmd) catch {
        app.setStatusErr("Command queue is full");
        app.log.err("CMD", "queue push failed: {s}", .{@tagName(cmd)});
        return;
    };
    app.setStatus(ok_msg);
    app.log.info("CMD", "queued: {s}", .{@tagName(cmd)});
}

/// Execute a GUI-layer command immediately (not queued through the command system).
pub fn runGuiCommand(app: *AppState, gui_cmd: GuiCommand) void {
    switch (gui_cmd) {
        .view_schematic => {
            app.gui.view_mode = .schematic;
            app.setStatus("Viewing schematic");
        },
        .view_symbol => {
            const fio = app.active() orelse {
                app.setStatusErr("No active document");
                return;
            };
            if (fio.symbol() == null) {
                app.setStatusErr("No symbol in active document");
                return;
            }
            app.gui.view_mode = .symbol;
            app.setStatus("Viewing symbol");
        },
        .file_new => {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "untitled_{d}", .{app.schematics.items.len + 1}) catch "untitled";
            app.newFile(name) catch |err| {
                app.setStatusErr("Failed to create new file");
                app.log.err("GUI", "new file failed: {}", .{err});
            };
        },
        .file_open => {
            const filters = [_][]const u8{ "*.chn", "*.chn_tb", "*.sch" };
            const selected = dvui.dialogNativeFileOpen(app.allocator(), .{
                .title = "Open schematic",
                .path = app.project_dir,
                .filters = &filters,
                .filter_description = "Schematic files",
            }) catch |err| {
                app.setStatusErr("Open dialog failed");
                app.log.err("GUI", "open dialog failed: {}", .{err});
                return;
            };
            if (selected) |pathz| {
                defer app.allocator().free(pathz);
                app.openPath(pathz[0..pathz.len]) catch |err| {
                    app.setStatusErr("Open failed");
                    app.log.err("GUI", "open failed: {}", .{err});
                };
            } else {
                app.setStatus("Open canceled");
            }
        },
        .file_save => {
            const fio = app.active() orelse {
                app.setStatusErr("No active document");
                return;
            };

            fio.save() catch {
                app.setStatusErr("Save failed");
                return;
            };
            if (fio.isDirty()) {
                const selected = dvui.dialogNativeFileSave(app.allocator(), .{
                    .title = "Save schematic",
                    .path = app.project_dir,
                    .filters = &[_][]const u8{"*.chn"},
                    .filter_description = "CHN files",
                }) catch |err| {
                    app.setStatusErr("Save dialog failed");
                    app.log.err("GUI", "save dialog failed: {}", .{err});
                    return;
                };
                if (selected) |pathz| {
                    defer app.allocator().free(pathz);
                    app.saveActiveTo(pathz[0..pathz.len]) catch |err| {
                        app.setStatusErr("Save failed");
                        app.log.err("GUI", "save failed: {}", .{err});
                    };
                } else {
                    app.setStatus("Save canceled");
                }
                return;
            }
            app.setStatus("Saved file");
        },
        .file_save_as => {
            const selected = dvui.dialogNativeFileSave(app.allocator(), .{
                .title = "Save schematic as",
                .path = app.project_dir,
                .filters = &[_][]const u8{"*.chn"},
                .filter_description = "CHN files",
            }) catch |err| {
                app.setStatusErr("Save-as dialog failed");
                app.log.err("GUI", "save-as dialog failed: {}", .{err});
                return;
            };
            if (selected) |pathz| {
                defer app.allocator().free(pathz);
                app.saveActiveTo(pathz[0..pathz.len]) catch |err| {
                    app.setStatusErr("Save as failed");
                    app.log.err("GUI", "save-as failed: {}", .{err});
                };
            } else {
                app.setStatus("Save as canceled");
            }
        },
        .file_reload => enqueue(app, .{ .reload_from_disk = {} }, "Reloading from disk"),
        .file_clear => enqueue(app, .{ .clear_schematic = {} }, "Queued clear schematic"),
        .file_view_logs => {
            app.dumpLog();
            app.status_msg = "Log dumped to stderr";
        },
        .file_start_process => startNewProcess(app),
        .file_exit => {
            app.status_msg = "Exiting";
            std.process.exit(0);
        },
    }
}

/// Parse and execute a vim-style colon command from the command bar.
pub fn runVimCommand(app: *AppState, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) {
        app.setStatus("Ready");
        return;
    }

    var parts = std.mem.splitScalar(u8, trimmed, ' ');
    const name = parts.next() orelse return;
    const rest = std.mem.trim(u8, parts.rest(), " \t");

    if (dispatchVimNoArg(app, name)) return;
    if (plugin_panels.tryHandleVim(app, name)) return;

    if (std.mem.eql(u8, name, "log")) {
        if (std.mem.eql(u8, rest, "clear")) {
            app.log.clear();
            app.setStatus("Log cleared");
            app.log.info("LOG", "cleared", .{});
            return;
        }
        runGuiCommand(app, .file_view_logs);
        return;
    }
    if (std.mem.eql(u8, name, "new")) {
        const file_name = if (rest.len > 0) rest else "untitled";
        app.newFile(file_name) catch |err| {
            app.setStatusErr("Failed to create file");
            app.log.err("CMD", "new failed: {}", .{err});
        };
        return;
    }
    if (std.mem.eql(u8, name, "open")) {
        if (rest.len == 0) {
            app.setStatusErr("Usage: :open <path>");
            return;
        }
        app.openPath(rest) catch |err| {
            app.setStatusErr("Open failed");
            app.log.err("CMD", "open failed: {}", .{err});
        };
        return;
    }

    if (std.mem.eql(u8, name, "load")) {
        if (rest.len == 0) {
            app.setStatusErr("Usage: :load <path>");
            return;
        }
        return enqueue(app, .{ .load_schematic = .{ .path = rest } }, "Queued load");
    }
    if (std.mem.eql(u8, name, "save") or std.mem.eql(u8, name, "w")) {
        if (rest.len == 0) {
            runGuiCommand(app, .file_save);
            return;
        }
        app.saveActiveTo(rest) catch |err| {
            app.setStatusErr("Save failed");
            app.log.err("CMD", "save failed: {}", .{err});
        };
        return;
    }
    if (std.mem.eql(u8, name, "saveas") or std.mem.eql(u8, name, "w!")) {
        if (rest.len == 0) {
            runGuiCommand(app, .file_save_as);
            return;
        }
        app.saveActiveTo(rest) catch |err| {
            app.setStatusErr("Save as failed");
            app.log.err("CMD", "saveas failed: {}", .{err});
        };
        return;
    }
    if (std.mem.eql(u8, name, "q") or std.mem.eql(u8, name, "quit")) {
        runGuiCommand(app, .file_exit);
        return;
    }
    if (std.mem.eql(u8, name, "reload") or std.mem.eql(u8, name, "e!")) {
        enqueue(app, .{ .reload_from_disk = {} }, "Reloading");
        return;
    }
    if (std.mem.eql(u8, name, "clear")) {
        enqueue(app, .{ .clear_schematic = {} }, "Queued clear schematic");
        return;
    }
    if (std.mem.eql(u8, name, "tabnew")) {
        enqueue(app, .{ .new_tab = {} }, "Queued new tab");
        return;
    }
    if (std.mem.eql(u8, name, "tabclose")) {
        enqueue(app, .{ .close_tab = {} }, "Queued close tab");
        return;
    }
    if (std.mem.eql(u8, name, "tabnext")) {
        enqueue(app, .{ .next_tab = {} }, "Queued next tab");
        return;
    }
    if (std.mem.eql(u8, name, "tabprev")) {
        enqueue(app, .{ .prev_tab = {} }, "Queued previous tab");
        return;
    }
    if (std.mem.eql(u8, name, "tabreopen")) {
        enqueue(app, .{ .reopen_last_closed = {} }, "Queued reopen");
        return;
    }
    if (std.mem.eql(u8, name, "wire")) {
        enqueue(app, .{ .start_wire = {} }, "Wire mode");
        return;
    }
    if (std.mem.eql(u8, name, "wiresnap")) {
        enqueue(app, .{ .start_wire_snap = {} }, "Wire mode (snap)");
        return;
    }
    if (std.mem.eql(u8, name, "breakwires")) {
        enqueue(app, .{ .break_wires_at_connections = {} }, "Queued break wires");
        return;
    }
    if (std.mem.eql(u8, name, "joinwires")) {
        enqueue(app, .{ .join_collapse_wires = {} }, "Queued join wires");
        return;
    }
    if (std.mem.eql(u8, name, "orthoroute")) {
        enqueue(app, .{ .toggle_orthogonal_routing = {} }, "Queued toggle ortho routing");
        return;
    }
    if (std.mem.eql(u8, name, "line")) {
        enqueue(app, .{ .start_line = {} }, "Line draw mode");
        return;
    }
    if (std.mem.eql(u8, name, "rect")) {
        enqueue(app, .{ .start_rect = {} }, "Rect draw mode");
        return;
    }
    if (std.mem.eql(u8, name, "text")) {
        enqueue(app, .{ .place_text = {} }, "Place text");
        return;
    }
    if (std.mem.eql(u8, name, "descend")) {
        enqueue(app, .{ .descend_schematic = {} }, "Descend into schematic");
        return;
    }
    if (std.mem.eql(u8, name, "ascend") or std.mem.eql(u8, name, "back")) {
        enqueue(app, .{ .ascend = {} }, "Ascend to parent");
        return;
    }
    if (std.mem.eql(u8, name, "descsym")) {
        enqueue(app, .{ .descend_symbol = {} }, "Descend into symbol");
        return;
    }
    if (std.mem.eql(u8, name, "edittab")) {
        enqueue(app, .{ .edit_in_new_tab = {} }, "Edit in new tab");
        return;
    }
    if (std.mem.eql(u8, name, "props")) {
        enqueue(app, .{ .edit_properties = {} }, "Edit properties");
        return;
    }
    if (std.mem.eql(u8, name, "viewprops")) {
        enqueue(app, .{ .view_properties = {} }, "View properties");
        return;
    }
    if (std.mem.eql(u8, name, "netlist")) {
        enqueue(app, .{ .netlist_hierarchical = {} }, "Generating hierarchical netlist");
        return;
    }
    if (std.mem.eql(u8, name, "netlsttop")) {
        enqueue(app, .{ .netlist_top_only = {} }, "Generating top-only netlist");
        return;
    }
    if (std.mem.eql(u8, name, "toggleflat")) {
        enqueue(app, .{ .toggle_flat_netlist = {} }, "Toggled flat netlist");
        return;
    }
    if (std.mem.eql(u8, name, "hilight")) {
        enqueue(app, .{ .highlight_selected_nets = {} }, "Highlighting nets");
        return;
    }
    if (std.mem.eql(u8, name, "unhilight")) {
        enqueue(app, .{ .unhighlight_selected_nets = {} }, "Unhighlighting nets");
        return;
    }
    if (std.mem.eql(u8, name, "unhilightall")) {
        enqueue(app, .{ .unhighlight_all = {} }, "Unhighlighting all");
        return;
    }
    if (std.mem.eql(u8, name, "selnet")) {
        enqueue(app, .{ .select_attached_nets = {} }, "Selecting attached nets");
        return;
    }
    if (std.mem.eql(u8, name, "makesym")) {
        enqueue(app, .{ .make_symbol_from_schematic = {} }, "Making symbol");
        return;
    }
    if (std.mem.eql(u8, name, "makesch")) {
        enqueue(app, .{ .make_schematic_from_symbol = {} }, "Making schematic");
        return;
    }
    if (std.mem.eql(u8, name, "insert")) {
        enqueue(app, .{ .insert_from_library = {} }, "Opening library");
        return;
    }
    if (std.mem.eql(u8, name, "find")) {
        enqueue(app, .{ .find_select_dialog = {} }, "Find/select");
        return;
    }
    if (std.mem.eql(u8, name, "zoomsel")) {
        enqueue(app, .{ .zoom_fit_selected = {} }, "Queued zoom fit selected");
        return;
    }
    if (std.mem.eql(u8, name, "fullscreen")) {
        enqueue(app, .{ .toggle_fullscreen = {} }, "Queued toggle fullscreen");
        return;
    }
    if (std.mem.eql(u8, name, "darkmode")) {
        enqueue(app, .{ .toggle_colorscheme = {} }, "Queued toggle colorscheme");
        return;
    }
    if (std.mem.eql(u8, name, "grid")) {
        app.show_grid = !app.show_grid;
        app.setStatus(if (app.show_grid) "Grid on" else "Grid off");
        return;
    }
    if (std.mem.eql(u8, name, "snapdouble")) {
        enqueue(app, .{ .snap_double = {} }, "Snap doubled");
        return;
    }
    if (std.mem.eql(u8, name, "snaphalve")) {
        enqueue(app, .{ .snap_halve = {} }, "Snap halved");
        return;
    }
    if (std.mem.eql(u8, name, "exportpdf")) {
        enqueue(app, .{ .export_pdf = {} }, "Queued export PDF");
        return;
    }
    if (std.mem.eql(u8, name, "exportpng")) {
        enqueue(app, .{ .export_png = {} }, "Queued export PNG");
        return;
    }
    if (std.mem.eql(u8, name, "exportsvg")) {
        enqueue(app, .{ .export_svg = {} }, "Queued export SVG");
        return;
    }
    if (std.mem.eql(u8, name, "move")) {
        enqueue(app, .{ .move_interactive = {} }, "Move mode");
        return;
    }
    if (std.mem.eql(u8, name, "copy")) {
        enqueue(app, .{ .copy_selected = {} }, "Copy mode");
        return;
    }
    if (std.mem.eql(u8, name, "clipcopy")) {
        enqueue(app, .{ .clipboard_copy = {} }, "Copied to clipboard");
        return;
    }
    if (std.mem.eql(u8, name, "clipcut")) {
        enqueue(app, .{ .clipboard_cut = {} }, "Cut to clipboard");
        return;
    }
    if (std.mem.eql(u8, name, "clippaste")) {
        enqueue(app, .{ .clipboard_paste = {} }, "Pasted from clipboard");
        return;
    }
    if (std.mem.eql(u8, name, "aligngrid")) {
        enqueue(app, .{ .align_to_grid = {} }, "Aligned to grid");
        return;
    }
    if (std.mem.eql(u8, name, "keybinds") or std.mem.eql(u8, name, "help")) {
        enqueue(app, .{ .show_keybinds = {} }, "Keybind help");
        return;
    }
    if (std.mem.eql(u8, name, "shownetlist")) {
        enqueue(app, .{ .toggle_show_netlist = {} }, "Toggle netlist display");
        return;
    }
    if (std.mem.eql(u8, name, "waveview") or std.mem.eql(u8, name, "wave")) {
        enqueue(app, .{ .open_waveform_viewer = {} }, "Opening waveform viewer");
        return;
    }
    if (std.mem.eql(u8, name, "crosshair")) {
        enqueue(app, .{ .toggle_crosshair = {} }, "Toggle crosshair");
        return;
    }
    if (std.mem.eql(u8, name, "duplicatewires") or std.mem.eql(u8, name, "duprefdes")) {
        enqueue(app, .{ .highlight_dup_refdes = {} }, "Highlighting duplicate refdes");
        return;
    }
    if (std.mem.eql(u8, name, "fixrefdes")) {
        enqueue(app, .{ .rename_dup_refdes = {} }, "Renaming duplicate refdes");
        return;
    }
    if (std.mem.eql(u8, name, "runsim")) {
        const sim = if (std.mem.eql(u8, rest, "xyce")) Sim.xyce else Sim.ngspice;
        return enqueue(app, .{ .run_sim = .{ .sim = sim } }, "Queued simulation");
    }

    if (std.mem.eql(u8, name, "deletedevice")) {
        const idx = parseUsize(rest) orelse return usage(app, "Usage: :deletedevice <idx>");
        return enqueue(app, .{ .delete_device = .{ .idx = idx } }, "Queued device delete");
    }
    if (std.mem.eql(u8, name, "deletewire")) {
        const idx = parseUsize(rest) orelse return usage(app, "Usage: :deletewire <idx>");
        return enqueue(app, .{ .delete_wire = .{ .idx = idx } }, "Queued wire delete");
    }

    if (std.mem.eql(u8, name, "placedevice")) {
        var p = std.mem.splitScalar(u8, rest, ' ');
        const sym = p.next() orelse return usage(app, "Usage: :placedevice <sym> <name> <x> <y>");
        const inst = p.next() orelse return usage(app, "Usage: :placedevice <sym> <name> <x> <y>");
        const xs = p.next() orelse return usage(app, "Usage: :placedevice <sym> <name> <x> <y>");
        const ys = p.next() orelse return usage(app, "Usage: :placedevice <sym> <name> <x> <y>");
        const x = parseF64(xs) orelse return usage(app, "Usage: :placedevice <sym> <name> <x> <y>");
        const y = parseF64(ys) orelse return usage(app, "Usage: :placedevice <sym> <name> <x> <y>");
        return enqueue(app, .{ .place_device = .{ .sym_path = sym, .name = inst, .x = x, .y = y } }, "Queued place device");
    }

    if (std.mem.eql(u8, name, "movedevice")) {
        var p = std.mem.splitScalar(u8, rest, ' ');
        const is = p.next() orelse return usage(app, "Usage: :movedevice <idx> <dx> <dy>");
        const dxs = p.next() orelse return usage(app, "Usage: :movedevice <idx> <dx> <dy>");
        const dys = p.next() orelse return usage(app, "Usage: :movedevice <idx> <dx> <dy>");
        const idx = parseUsize(is) orelse return usage(app, "Usage: :movedevice <idx> <dx> <dy>");
        const dx = parseF64(dxs) orelse return usage(app, "Usage: :movedevice <idx> <dx> <dy>");
        const dy = parseF64(dys) orelse return usage(app, "Usage: :movedevice <idx> <dx> <dy>");
        return enqueue(app, .{ .move_device = .{ .idx = idx, .dx = dx, .dy = dy } }, "Queued move device");
    }

    if (std.mem.eql(u8, name, "setprop")) {
        var p = std.mem.splitScalar(u8, rest, ' ');
        const is = p.next() orelse return usage(app, "Usage: :setprop <idx> <key> <val>");
        const key = p.next() orelse return usage(app, "Usage: :setprop <idx> <key> <val>");
        const val = std.mem.trim(u8, p.rest(), " \t");
        if (val.len == 0) return usage(app, "Usage: :setprop <idx> <key> <val>");
        const idx = parseUsize(is) orelse return usage(app, "Usage: :setprop <idx> <key> <val>");
        return enqueue(app, .{ .set_prop = .{ .idx = idx, .key = key, .val = val } }, "Queued set prop");
    }

    if (std.mem.eql(u8, name, "addwire")) {
        var p = std.mem.splitScalar(u8, rest, ' ');
        const x0s = p.next() orelse return usage(app, "Usage: :addwire <x0> <y0> <x1> <y1>");
        const y0s = p.next() orelse return usage(app, "Usage: :addwire <x0> <y0> <x1> <y1>");
        const x1s = p.next() orelse return usage(app, "Usage: :addwire <x0> <y0> <x1> <y1>");
        const y1s = p.next() orelse return usage(app, "Usage: :addwire <x0> <y0> <x1> <y1>");
        const x0 = parseF64(x0s) orelse return usage(app, "Usage: :addwire <x0> <y0> <x1> <y1>");
        const y0 = parseF64(y0s) orelse return usage(app, "Usage: :addwire <x0> <y0> <x1> <y1>");
        const x1 = parseF64(x1s) orelse return usage(app, "Usage: :addwire <x0> <y0> <x1> <y1>");
        const y1 = parseF64(y1s) orelse return usage(app, "Usage: :addwire <x0> <y0> <x1> <y1>");
        return enqueue(app, .{ .add_wire = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } }, "Queued add wire");
    }

    if (std.mem.eql(u8, name, "snap")) {
        if (rest.len > 0) {
            if (parseF64(rest)) |v| {
                app.tool.snap_size = @as(f32, @floatCast(v));
                app.setStatus("Snap size set");
                return;
            }
        }
        app.setStatusErr("Usage: :snap <value>");
        return;
    }

    if (std.mem.eql(u8, name, "tabopen")) {
        if (rest.len == 0) {
            app.setStatusErr("Usage: :tabopen <path>");
            return;
        }
        app.openPath(rest) catch |err| {
            app.setStatusErr("Open failed");
            app.log.err("CMD", "tabopen failed: {}", .{err});
        };
        return;
    }

    app.setStatusErr("Unknown command");
    app.log.warn("CMD", "unknown command: {s}", .{name});
}

const VimNoArg = struct {
    name: []const u8,
    action: Action,
};

const Action = union(enum) {
    queue: struct { cmd: command.Command, msg: []const u8 },
    gui: GuiCommand,
};

const vim_noarg = [_]VimNoArg{
    .{ .name = "zoomin", .action = .{ .queue = .{ .cmd = .{ .zoom_in = {} }, .msg = "Queued zoom in" } } },
    .{ .name = "zoomout", .action = .{ .queue = .{ .cmd = .{ .zoom_out = {} }, .msg = "Queued zoom out" } } },
    .{ .name = "zoomfit", .action = .{ .queue = .{ .cmd = .{ .zoom_fit = {} }, .msg = "Queued zoom fit" } } },
    .{ .name = "zoomreset", .action = .{ .queue = .{ .cmd = .{ .zoom_reset = {} }, .msg = "Queued zoom reset" } } },
    .{ .name = "undo", .action = .{ .queue = .{ .cmd = .{ .undo = {} }, .msg = "Queued undo" } } },
    .{ .name = "redo", .action = .{ .queue = .{ .cmd = .{ .redo = {} }, .msg = "Queued redo" } } },
    .{ .name = "selectall", .action = .{ .queue = .{ .cmd = .{ .select_all = {} }, .msg = "Queued select all" } } },
    .{ .name = "selectnone", .action = .{ .queue = .{ .cmd = .{ .select_none = {} }, .msg = "Queued select none" } } },
    .{ .name = "delete", .action = .{ .queue = .{ .cmd = .{ .delete_selected = {} }, .msg = "Queued delete" } } },
    .{ .name = "duplicate", .action = .{ .queue = .{ .cmd = .{ .duplicate_selected = {} }, .msg = "Queued duplicate" } } },
    .{ .name = "rotcw", .action = .{ .queue = .{ .cmd = .{ .rotate_cw = {} }, .msg = "Queued rotate CW" } } },
    .{ .name = "rotccw", .action = .{ .queue = .{ .cmd = .{ .rotate_ccw = {} }, .msg = "Queued rotate CCW" } } },
    .{ .name = "fliph", .action = .{ .queue = .{ .cmd = .{ .flip_horizontal = {} }, .msg = "Queued flip horizontal" } } },
    .{ .name = "flipv", .action = .{ .queue = .{ .cmd = .{ .flip_vertical = {} }, .msg = "Queued flip vertical" } } },
    .{ .name = "left", .action = .{ .queue = .{ .cmd = .{ .nudge_left = {} }, .msg = "Queued nudge left" } } },
    .{ .name = "right", .action = .{ .queue = .{ .cmd = .{ .nudge_right = {} }, .msg = "Queued nudge right" } } },
    .{ .name = "up", .action = .{ .queue = .{ .cmd = .{ .nudge_up = {} }, .msg = "Queued nudge up" } } },
    .{ .name = "down", .action = .{ .queue = .{ .cmd = .{ .nudge_down = {} }, .msg = "Queued nudge down" } } },
    .{ .name = "pluginsreload", .action = .{ .queue = .{ .cmd = .{ .plugins_refresh = {} }, .msg = "Queued plugin refresh signal" } } },
    .{ .name = "plugreload", .action = .{ .queue = .{ .cmd = .{ .plugins_refresh = {} }, .msg = "Queued plugin refresh signal" } } },
    .{ .name = "schematic", .action = .{ .gui = .view_schematic } },
    .{ .name = "symbol", .action = .{ .gui = .view_symbol } },
};

fn dispatchVimNoArg(app: *AppState, name: []const u8) bool {
    for (vim_noarg) |entry| {
        if (!std.mem.eql(u8, name, entry.name)) continue;
        switch (entry.action) {
            .queue => |q| enqueue(app, q.cmd, q.msg),
            .gui => |g| runGuiCommand(app, g),
        }
        return true;
    }
    return false;
}

fn usage(app: *AppState, msg: []const u8) void {
    app.setStatusErr(msg);
}

fn parseUsize(s: []const u8) ?usize {
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn parseF64(s: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, s) catch null;
}

fn startNewProcess(app: *AppState) void {
    const exe = std.mem.span(std.os.argv[0]);
    var child = std.process.Child.init(&.{exe}, app.allocator());
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        app.setStatusErr("Failed to start new process");
        app.log.err("GUI", "spawn failed: {}", .{err});
        return;
    };
    app.setStatus("Started new process");
    app.log.info("GUI", "spawned process: {s}", .{exe});
}
