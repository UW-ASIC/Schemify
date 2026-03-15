//! Actions — command dispatch, GUI commands, and vim-style command parsing.

const std     = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const dvui    = @import("dvui");
const command = @import("commands");
const AppState = @import("state").AppState;
const Sim      = @import("state").Sim;
const plugin_panels = @import("PluginPanels.zig");

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
//
// Stored at file scope so StaticStringMap can build its O(1) index at
// comptime.  Each entry maps a command name to an action value.

const VimAction = union(enum) {
    queue: struct { cmd: command.Command, msg: []const u8 },
    gui:   GuiCommand,
};

const vim_noarg_entries = [_]struct { []const u8, VimAction }{
    // Zoom
    .{ "zoomin",    .{ .queue = .{ .cmd = .{ .immediate = .zoom_in           }, .msg = "Queued zoom in"            } } },
    .{ "zoomout",   .{ .queue = .{ .cmd = .{ .immediate = .zoom_out          }, .msg = "Queued zoom out"           } } },
    .{ "zoomfit",   .{ .queue = .{ .cmd = .{ .immediate = .zoom_fit          }, .msg = "Queued zoom fit"           } } },
    .{ "zoomreset", .{ .queue = .{ .cmd = .{ .immediate = .zoom_reset        }, .msg = "Queued zoom reset"         } } },
    .{ "zoomsel",   .{ .queue = .{ .cmd = .{ .immediate = .zoom_fit_selected }, .msg = "Queued zoom fit selected"  } } },
    // Undo/redo
    .{ "undo", .{ .queue = .{ .cmd = .{ .immediate = .undo }, .msg = "Queued undo" } } },
    .{ "redo", .{ .queue = .{ .cmd = .{ .immediate = .redo }, .msg = "Queued redo" } } },
    // Selection
    .{ "selectall",  .{ .queue = .{ .cmd = .{ .immediate = .select_all         }, .msg = "Queued select all"  } } },
    .{ "selectnone", .{ .queue = .{ .cmd = .{ .immediate = .select_none        }, .msg = "Queued select none" } } },
    .{ "delete",     .{ .queue = .{ .cmd = .{ .undoable  = .delete_selected    }, .msg = "Queued delete"      } } },
    .{ "duplicate",  .{ .queue = .{ .cmd = .{ .undoable  = .duplicate_selected }, .msg = "Queued duplicate"   } } },
    // Rotation/flip
    .{ "rotcw",  .{ .queue = .{ .cmd = .{ .undoable = .rotate_cw       }, .msg = "Queued rotate CW"       } } },
    .{ "rotccw", .{ .queue = .{ .cmd = .{ .undoable = .rotate_ccw      }, .msg = "Queued rotate CCW"      } } },
    .{ "fliph",  .{ .queue = .{ .cmd = .{ .undoable = .flip_horizontal }, .msg = "Queued flip horizontal" } } },
    .{ "flipv",  .{ .queue = .{ .cmd = .{ .undoable = .flip_vertical   }, .msg = "Queued flip vertical"   } } },
    // Nudge
    .{ "left",  .{ .queue = .{ .cmd = .{ .undoable = .nudge_left  }, .msg = "Queued nudge left"  } } },
    .{ "right", .{ .queue = .{ .cmd = .{ .undoable = .nudge_right }, .msg = "Queued nudge right" } } },
    .{ "up",    .{ .queue = .{ .cmd = .{ .undoable = .nudge_up    }, .msg = "Queued nudge up"    } } },
    .{ "down",  .{ .queue = .{ .cmd = .{ .undoable = .nudge_down  }, .msg = "Queued nudge down"  } } },
    // Tabs
    .{ "tabnew",    .{ .queue = .{ .cmd = .{ .immediate = .new_tab            }, .msg = "Queued new tab"      } } },
    .{ "tabclose",  .{ .queue = .{ .cmd = .{ .immediate = .close_tab          }, .msg = "Queued close tab"    } } },
    .{ "tabnext",   .{ .queue = .{ .cmd = .{ .immediate = .next_tab           }, .msg = "Queued next tab"     } } },
    .{ "tabprev",   .{ .queue = .{ .cmd = .{ .immediate = .prev_tab           }, .msg = "Queued previous tab" } } },
    .{ "tabreopen", .{ .queue = .{ .cmd = .{ .immediate = .reopen_last_closed }, .msg = "Queued reopen"       } } },
    // Wires
    .{ "wire",       .{ .queue = .{ .cmd = .{ .immediate = .start_wire                 }, .msg = "Wire mode"          } } },
    .{ "wiresnap",   .{ .queue = .{ .cmd = .{ .immediate = .start_wire_snap            }, .msg = "Wire mode (snap)"   } } },
    .{ "breakwires", .{ .queue = .{ .cmd = .{ .immediate = .break_wires_at_connections }, .msg = "Queued break wires" } } },
    .{ "joinwires",  .{ .queue = .{ .cmd = .{ .immediate = .join_collapse_wires        }, .msg = "Queued join wires"  } } },
    .{ "orthoroute", .{ .queue = .{ .cmd = .{ .immediate = .toggle_orthogonal_routing  }, .msg = "Toggle ortho"       } } },
    // Drawing
    .{ "line", .{ .queue = .{ .cmd = .{ .immediate = .start_line }, .msg = "Line draw mode" } } },
    .{ "rect", .{ .queue = .{ .cmd = .{ .immediate = .start_rect }, .msg = "Rect draw mode" } } },
    .{ "text", .{ .queue = .{ .cmd = .{ .immediate = .place_text }, .msg = "Place text"     } } },
    // Hierarchy
    .{ "descend",  .{ .queue = .{ .cmd = .{ .immediate = .descend_schematic }, .msg = "Descend into schematic" } } },
    .{ "ascend",   .{ .queue = .{ .cmd = .{ .immediate = .ascend             }, .msg = "Ascend to parent"       } } },
    .{ "back",     .{ .queue = .{ .cmd = .{ .immediate = .ascend             }, .msg = "Ascend to parent"       } } },
    .{ "descsym",  .{ .queue = .{ .cmd = .{ .immediate = .descend_symbol     }, .msg = "Descend into symbol"    } } },
    .{ "edittab",  .{ .queue = .{ .cmd = .{ .immediate = .edit_in_new_tab    }, .msg = "Edit in new tab"        } } },
    // Properties
    .{ "props",     .{ .queue = .{ .cmd = .{ .immediate = .edit_properties }, .msg = "Edit properties" } } },
    .{ "viewprops", .{ .queue = .{ .cmd = .{ .immediate = .view_properties }, .msg = "View properties" } } },
    // Netlist
    .{ "netlist",    .{ .queue = .{ .cmd = .{ .immediate = .netlist_hierarchical }, .msg = "Generating hierarchical netlist" } } },
    .{ "netlsttop",  .{ .queue = .{ .cmd = .{ .immediate = .netlist_top_only     }, .msg = "Generating top-only netlist"    } } },
    .{ "toggleflat", .{ .queue = .{ .cmd = .{ .immediate = .toggle_flat_netlist  }, .msg = "Toggled flat netlist"           } } },
    // Net highlighting
    .{ "hilight",      .{ .queue = .{ .cmd = .{ .immediate = .highlight_selected_nets   }, .msg = "Highlighting nets"       } } },
    .{ "unhilight",    .{ .queue = .{ .cmd = .{ .immediate = .unhighlight_selected_nets }, .msg = "Unhighlighting nets"     } } },
    .{ "unhilightall", .{ .queue = .{ .cmd = .{ .immediate = .unhighlight_all           }, .msg = "Unhighlighting all"      } } },
    .{ "selnet",       .{ .queue = .{ .cmd = .{ .immediate = .select_attached_nets      }, .msg = "Selecting attached nets" } } },
    // Symbol/schematic creation
    .{ "makesym", .{ .queue = .{ .cmd = .{ .immediate = .make_symbol_from_schematic }, .msg = "Making symbol"    } } },
    .{ "makesch", .{ .queue = .{ .cmd = .{ .immediate = .make_schematic_from_symbol }, .msg = "Making schematic" } } },
    // Library/find
    .{ "insert", .{ .queue = .{ .cmd = .{ .immediate = .insert_from_library }, .msg = "Opening library" } } },
    .{ "find",   .{ .queue = .{ .cmd = .{ .immediate = .find_select_dialog  }, .msg = "Find/select"     } } },
    // View toggles
    .{ "fullscreen",  .{ .queue = .{ .cmd = .{ .immediate = .toggle_fullscreen   }, .msg = "Queued toggle fullscreen"  } } },
    .{ "darkmode",    .{ .queue = .{ .cmd = .{ .immediate = .toggle_colorscheme  }, .msg = "Queued toggle colorscheme" } } },
    .{ "shownetlist", .{ .queue = .{ .cmd = .{ .immediate = .toggle_show_netlist }, .msg = "Toggle netlist display"    } } },
    .{ "crosshair",   .{ .queue = .{ .cmd = .{ .immediate = .toggle_crosshair    }, .msg = "Toggle crosshair"          } } },
    // Snap
    .{ "snapdouble", .{ .queue = .{ .cmd = .{ .immediate = .snap_double }, .msg = "Snap doubled" } } },
    .{ "snaphalve",  .{ .queue = .{ .cmd = .{ .immediate = .snap_halve  }, .msg = "Snap halved"  } } },
    // Export
    .{ "exportpdf", .{ .queue = .{ .cmd = .{ .immediate = .export_pdf }, .msg = "Queued export PDF" } } },
    .{ "exportpng", .{ .queue = .{ .cmd = .{ .immediate = .export_png }, .msg = "Queued export PNG" } } },
    .{ "exportsvg", .{ .queue = .{ .cmd = .{ .immediate = .export_svg }, .msg = "Queued export SVG" } } },
    // Edit operations
    .{ "move",      .{ .queue = .{ .cmd = .{ .immediate = .move_interactive  }, .msg = "Move mode"             } } },
    .{ "copy",      .{ .queue = .{ .cmd = .{ .immediate = .copy_selected     }, .msg = "Copy mode"             } } },
    .{ "clipcopy",  .{ .queue = .{ .cmd = .{ .immediate = .clipboard_copy    }, .msg = "Copied to clipboard"   } } },
    .{ "clipcut",   .{ .queue = .{ .cmd = .{ .immediate = .clipboard_cut     }, .msg = "Cut to clipboard"      } } },
    .{ "clippaste", .{ .queue = .{ .cmd = .{ .immediate = .clipboard_paste   }, .msg = "Pasted from clipboard" } } },
    .{ "aligngrid", .{ .queue = .{ .cmd = .{ .immediate = .align_to_grid     }, .msg = "Aligned to grid"       } } },
    // Help
    .{ "keybinds", .{ .queue = .{ .cmd = .{ .immediate = .show_keybinds }, .msg = "Keybind help" } } },
    .{ "help",     .{ .queue = .{ .cmd = .{ .immediate = .show_keybinds }, .msg = "Keybind help" } } },
    // Waveform
    .{ "waveview", .{ .queue = .{ .cmd = .{ .immediate = .open_waveform_viewer }, .msg = "Opening waveform viewer" } } },
    .{ "wave",     .{ .queue = .{ .cmd = .{ .immediate = .open_waveform_viewer }, .msg = "Opening waveform viewer" } } },
    // Refdes
    .{ "duplicatewires", .{ .queue = .{ .cmd = .{ .immediate = .highlight_dup_refdes }, .msg = "Highlighting duplicate refdes" } } },
    .{ "duprefdes",      .{ .queue = .{ .cmd = .{ .immediate = .highlight_dup_refdes }, .msg = "Highlighting duplicate refdes" } } },
    .{ "fixrefdes",      .{ .queue = .{ .cmd = .{ .immediate = .rename_dup_refdes    }, .msg = "Renaming duplicate refdes"     } } },
    // Plugins
    .{ "pluginsreload", .{ .queue = .{ .cmd = .{ .immediate = .plugins_refresh }, .msg = "Queued plugin refresh signal" } } },
    .{ "plugreload",    .{ .queue = .{ .cmd = .{ .immediate = .plugins_refresh }, .msg = "Queued plugin refresh signal" } } },
    // View mode
    .{ "schematic", .{ .gui = .view_schematic } },
    .{ "symbol",    .{ .gui = .view_symbol    } },
    // File (no-arg variants)
    .{ "reload", .{ .queue = .{ .cmd = .{ .immediate = .reload_from_disk }, .msg = "Reloading"              } } },
    .{ "e!",     .{ .queue = .{ .cmd = .{ .immediate = .reload_from_disk }, .msg = "Reloading"              } } },
    .{ "clear",  .{ .queue = .{ .cmd = .{ .immediate = .clear_schematic  }, .msg = "Queued clear schematic" } } },
};

/// O(1) comptime-hashed map from vim command name to VimAction.
const vim_noarg_map = std.StaticStringMap(VimAction).initComptime(&vim_noarg_entries);

// ── Vim commands that require arguments ────────────────────────────────────
//
// Each handler has signature  fn(*AppState, []const u8) void.
// runVimCommand() dispatches via `inline for` over the comptime tuple
// vim_arg_handlers -- zero indirection, no vtable, no heap.

fn cmdLog(app: *AppState, rest: []const u8) void {
    if (std.mem.eql(u8, rest, "clear")) {
        app.log.clear();
        app.setStatus("Log cleared");
        app.log.info("LOG", "cleared", .{});
    } else {
        runGuiCommand(app, .file_view_logs);
    }
}

fn cmdNew(app: *AppState, rest: []const u8) void {
    const name = if (rest.len > 0) rest else "untitled";
    app.newFile(name) catch |err| {
        app.setStatusErr("Failed to create file");
        app.log.err("CMD", "new failed: {}", .{err});
    };
}

fn cmdOpen(app: *AppState, rest: []const u8) void {
    if (rest.len == 0) { app.setStatusErr("Usage: :open <path>"); return; }
    app.openPath(rest) catch |err| {
        app.setStatusErr("Open failed");
        app.log.err("CMD", "open failed: {}", .{err});
    };
}

fn cmdTabOpen(app: *AppState, rest: []const u8) void {
    if (rest.len == 0) { app.setStatusErr("Usage: :tabopen <path>"); return; }
    app.openPath(rest) catch |err| {
        app.setStatusErr("Open failed");
        app.log.err("CMD", "tabopen failed: {}", .{err});
    };
}

fn cmdLoad(app: *AppState, rest: []const u8) void {
    if (rest.len == 0) { app.setStatusErr("Usage: :load <path>"); return; }
    enqueue(app, .{ .undoable = .{ .load_schematic = .{ .path = rest } } }, "Queued load");
}

fn cmdSave(app: *AppState, rest: []const u8) void {
    if (rest.len == 0) { runGuiCommand(app, .file_save); return; }
    app.saveActiveTo(rest) catch |err| {
        app.setStatusErr("Save failed");
        app.log.err("CMD", "save failed: {}", .{err});
    };
}

fn cmdSaveAs(app: *AppState, rest: []const u8) void {
    if (rest.len == 0) { runGuiCommand(app, .file_save_as); return; }
    app.saveActiveTo(rest) catch |err| {
        app.setStatusErr("Save as failed");
        app.log.err("CMD", "saveas failed: {}", .{err});
    };
}

fn cmdQuit(app: *AppState, _: []const u8) void { runGuiCommand(app, .file_exit); }

fn cmdGrid(app: *AppState, _: []const u8) void {
    app.show_grid = !app.show_grid;
    app.setStatus(if (app.show_grid) "Grid on" else "Grid off");
}

fn cmdRunSim(app: *AppState, rest: []const u8) void {
    const sim = if (std.mem.eql(u8, rest, "xyce")) Sim.xyce else Sim.ngspice;
    enqueue(app, .{ .undoable = .{ .run_sim = .{ .sim = sim } } }, "Queued simulation");
}

fn cmdSnap(app: *AppState, rest: []const u8) void {
    const v = parseF64(rest) orelse { app.setStatusErr("Usage: :snap <value>"); return; };
    app.tool.snap_size = @as(f32, @floatCast(v));
    app.setStatus("Snap size set");
}

fn cmdDeleteDevice(app: *AppState, rest: []const u8) void {
    const idx = parseUsize(rest) orelse { app.setStatusErr("Usage: :deletedevice <idx>"); return; };
    enqueue(app, .{ .undoable = .{ .delete_device = .{ .idx = @intCast(idx) } } }, "Queued device delete");
}

fn cmdDeleteWire(app: *AppState, rest: []const u8) void {
    const idx = parseUsize(rest) orelse { app.setStatusErr("Usage: :deletewire <idx>"); return; };
    enqueue(app, .{ .undoable = .{ .delete_wire = .{ .idx = @intCast(idx) } } }, "Queued wire delete");
}

fn cmdPlaceDevice(app: *AppState, rest: []const u8) void {
    const usage = "Usage: :placedevice <sym> <name> <x> <y>";
    var p    = std.mem.splitScalar(u8, rest, ' ');
    const sym  = p.next() orelse { app.setStatusErr(usage); return; };
    const inst = p.next() orelse { app.setStatusErr(usage); return; };
    const xs   = p.next() orelse { app.setStatusErr(usage); return; };
    const ys   = p.next() orelse { app.setStatusErr(usage); return; };
    const x    = parseF64(xs) orelse { app.setStatusErr(usage); return; };
    const y    = parseF64(ys) orelse { app.setStatusErr(usage); return; };
    enqueue(app, .{ .undoable = .{ .place_device = .{
        .sym_path = sym, .name = inst,
        .pos = @Vector(2, i32){ @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)) },
    } } }, "Queued place device");
}

fn cmdMoveDevice(app: *AppState, rest: []const u8) void {
    const usage = "Usage: :movedevice <idx> <dx> <dy>";
    var p    = std.mem.splitScalar(u8, rest, ' ');
    const is  = p.next()  orelse { app.setStatusErr(usage); return; };
    const dxs = p.next()  orelse { app.setStatusErr(usage); return; };
    const dys = p.next()  orelse { app.setStatusErr(usage); return; };
    const idx = parseUsize(is)  orelse { app.setStatusErr(usage); return; };
    const dx  = parseF64(dxs)   orelse { app.setStatusErr(usage); return; };
    const dy  = parseF64(dys)   orelse { app.setStatusErr(usage); return; };
    enqueue(app, .{ .undoable = .{ .move_device = .{
        .idx = @intCast(idx),
        .delta = @Vector(2, i32){ @as(i32, @intFromFloat(dx)), @as(i32, @intFromFloat(dy)) },
    } } }, "Queued move device");
}

fn cmdSetProp(app: *AppState, rest: []const u8) void {
    const usage = "Usage: :setprop <idx> <key> <val>";
    var p    = std.mem.splitScalar(u8, rest, ' ');
    const is  = p.next() orelse { app.setStatusErr(usage); return; };
    const key = p.next() orelse { app.setStatusErr(usage); return; };
    const val = std.mem.trim(u8, p.rest(), " \t");
    if (val.len == 0) { app.setStatusErr(usage); return; }
    const idx = parseUsize(is) orelse { app.setStatusErr(usage); return; };
    enqueue(app, .{ .undoable = .{ .set_prop = .{ .idx = @intCast(idx), .key = key, .val = val } } },
        "Queued set prop");
}

fn cmdAddWire(app: *AppState, rest: []const u8) void {
    const usage = "Usage: :addwire <x0> <y0> <x1> <y1>";
    var p    = std.mem.splitScalar(u8, rest, ' ');
    const x0s = p.next() orelse { app.setStatusErr(usage); return; };
    const y0s = p.next() orelse { app.setStatusErr(usage); return; };
    const x1s = p.next() orelse { app.setStatusErr(usage); return; };
    const y1s = p.next() orelse { app.setStatusErr(usage); return; };
    const x0  = parseF64(x0s) orelse { app.setStatusErr(usage); return; };
    const y0  = parseF64(y0s) orelse { app.setStatusErr(usage); return; };
    const x1  = parseF64(x1s) orelse { app.setStatusErr(usage); return; };
    const y1  = parseF64(y1s) orelse { app.setStatusErr(usage); return; };
    enqueue(app, .{ .undoable = .{ .add_wire = .{
        .start = @Vector(2, i32){ @as(i32, @intFromFloat(x0)), @as(i32, @intFromFloat(y0)) },
        .end   = @Vector(2, i32){ @as(i32, @intFromFloat(x1)), @as(i32, @intFromFloat(y1)) },
    } } }, "Queued add wire");
}

/// Comptime dispatch table for vim commands that take arguments.
/// `inline for` in runVimCommand folds this to a straight string comparison
/// chain -- no vtable, no function-pointer indirection at runtime.
const vim_arg_handlers = .{
    .{ "log",          cmdLog          },
    .{ "new",          cmdNew          },
    .{ "open",         cmdOpen         },
    .{ "tabopen",      cmdTabOpen      },
    .{ "load",         cmdLoad         },
    .{ "save",         cmdSave         },
    .{ "w",            cmdSave         },
    .{ "saveas",       cmdSaveAs       },
    .{ "w!",           cmdSaveAs       },
    .{ "q",            cmdQuit         },
    .{ "quit",         cmdQuit         },
    .{ "grid",         cmdGrid         },
    .{ "runsim",       cmdRunSim       },
    .{ "snap",         cmdSnap         },
    .{ "deletedevice", cmdDeleteDevice },
    .{ "deletewire",   cmdDeleteWire   },
    .{ "placedevice",  cmdPlaceDevice  },
    .{ "movedevice",   cmdMoveDevice   },
    .{ "setprop",      cmdSetProp      },
    .{ "addwire",      cmdAddWire      },
};

// ── Public API ─────────────────────────────────────────────────────────────

/// Push a command onto the app queue and update the status message.
pub fn enqueue(app: *AppState, cmd: command.Command, ok_msg: []const u8) void {
    app.queue.push(app.allocator(), cmd) catch {
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
            const name = std.fmt.bufPrint(&name_buf, "untitled_{d}", .{app.documents.items.len + 1})
                catch "untitled";
            app.newFile(name) catch |err| {
                app.setStatusErr("Failed to create new file");
                app.log.err("GUI", "new file failed: {}", .{err});
            };
        },
        .file_open => {
            const filters = [_][]const u8{ "*.chn", "*.chn_tb", "*.sch" };
            const selected = dvui.dialogNativeFileOpen(app.allocator(), .{
                .title              = "Open schematic",
                .path               = app.project_dir,
                .filters            = &filters,
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
                    .title              = "Save schematic",
                    .path               = app.project_dir,
                    .filters            = &[_][]const u8{"*.chn"},
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
                .title              = "Save schematic as",
                .path               = app.project_dir,
                .filters            = &[_][]const u8{"*.chn"},
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
        .file_reload        => enqueue(app, .{ .immediate = .reload_from_disk }, "Reloading from disk"),
        .file_clear         => enqueue(app, .{ .immediate = .clear_schematic  }, "Queued clear schematic"),
        .file_view_logs     => { app.dumpLog(); app.status_msg = "Log dumped to stderr"; },
        .file_start_process => startNewProcess(app),
        .file_exit          => { app.status_msg = "Exiting"; if (comptime !is_wasm) std.process.exit(0); },
    }
}

/// Parse and execute a vim-style colon command from the command bar.
pub fn runVimCommand(app: *AppState, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) { app.setStatus("Ready"); return; }

    var parts = std.mem.splitScalar(u8, trimmed, ' ');
    const name = parts.next() orelse return;
    const rest = std.mem.trim(u8, parts.rest(), " \t");

    if (vim_noarg_map.get(name)) |action| {
        switch (action) {
            .queue => |q| enqueue(app, q.cmd, q.msg),
            .gui   => |g| runGuiCommand(app, g),
        }
        return;
    }

    if (plugin_panels.tryHandleVim(app, name)) return;

    inline for (vim_arg_handlers) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            entry[1](app, rest);
            return;
        }
    }

    // Plugin-registered commands (register_command 0x8F)
    for (app.gui.plugin_commands.items) |pc| {
        if (!std.mem.eql(u8, pc.id, name)) continue;
        enqueue(app, .{ .immediate = .{ .plugin_command = .{ .tag = pc.id, .payload = rest } } },
            pc.display_name);
        return;
    }

    app.setStatusErr("Unknown command");
    app.log.warn("CMD", "unknown command: {s}", .{name});
}

// ── Utilities ──────────────────────────────────────────────────────────────

fn parseUsize(s: []const u8) ?usize {
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn parseF64(s: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, s) catch null;
}

fn startNewProcess(app: *AppState) void {
    if (comptime is_wasm) { app.setStatusErr("Not supported on web"); return; }
    const exe = std.mem.span(std.os.argv[0]);
    var child = std.process.Child.init(&.{exe}, app.allocator());
    child.stdin_behavior  = .Ignore;
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
