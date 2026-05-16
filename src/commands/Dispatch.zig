const std = @import("std");
const types = @import("types.zig");
const Command = types.Command;
const Immediate = types.Immediate;
const Undoable = types.Undoable;
const h = @import("handlers/lib.zig");

pub const DispatchError = h.Error;

pub fn dispatch(cmd: Command, state: anytype) DispatchError!void {
    comptime verifyStateContract(@TypeOf(state));
    switch (cmd) {
        .immediate => |imm| try dispatchImmediate(imm, state),
        .undoable => |und| try dispatchUndoable(und, state),
    }
}

fn verifyStateContract(comptime T: type) void {
    const S = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
    const fields = [_][]const u8{ "tool", "gui", "status_msg", "plugin_refresh_requested", "show_grid", "cmd_flags", "log" };
    for (fields) |name| {
        if (!@hasField(S, name))
            @compileError("State missing field: " ++ name);
    }
    const methods = [_][]const u8{ "active", "setStatus", "allocator", "selectAll" };
    for (methods) |name| {
        if (!@hasDecl(S, name))
            @compileError("State missing method: " ++ name);
    }
}

// ── Immediate routing ────────────────────────────────────────────────────────

fn dispatchImmediate(imm: Immediate, state: anytype) DispatchError!void {
    switch (imm) {
        // View
        .zoom_in,
        .zoom_out,
        .zoom_fit,
        .zoom_reset,
        .zoom_fit_selected,
        .toggle_fullscreen,
        .toggle_colorscheme,
        .toggle_fill_rects,
        .toggle_text_in_symbols,
        .toggle_symbol_details,
        .show_all_layers,
        .show_only_current_layer,
        .increase_line_width,
        .decrease_line_width,
        .toggle_crosshair,
        .toggle_show_netlist,
        .toggle_grid,
        .snap_halve,
        .snap_double,
        .show_keybinds,
        .pan_interactive,
        .show_context_menu,
        .export_pdf,
        .export_png,
        .export_svg,
        .export_netlist,
        .print_schematic,
        .toggle_orthogonal_routing,
        .toggle_chat_panel,
        .view_doc,
        => h.handleView(imm, state),

        // Selection
        .select_all,
        .select_none,
        .invert_selection,
        .find_select_dialog,
        .highlight_selected_nets,
        .unhighlight_all,
        .select_attached_nets,
        => h.handleSelection(imm, state),

        // Clipboard
        .clipboard_copy,
        .clipboard_cut,
        .clipboard_paste,
        => try h.handleClipboard(imm, state),

        // Mode / Tool
        .escape_mode => h.handleEscapeMode(state),
        .start_wire => h.handleStartWire(state),
        .tool_select,
        .tool_move,
        .tool_pan,
        .tool_line,
        .tool_rect,
        .tool_polygon,
        .tool_arc,
        .tool_circle,
        .tool_text,
        => h.handleToolSwitch(imm, state),

        // File / Tab
        .file_new,
        .file_open,
        .file_save,
        .file_save_as,
        .file_save_all,
        .new_tab,
        .close_tab,
        .next_tab,
        .prev_tab,
        .reopen_closed_tab,
        .reload_from_disk,
        => try h.handleFile(imm, state),

        // Dialogs
        .open_find_dialog,
        .open_props_dialog,
        .open_spice_code_dialog,
        .open_marketplace,
        .open_new_prim_dialog,
        .open_import_project,
        .edit_properties,
        => h.handleDialog(imm, state),

        // Hierarchy
        .descend_schematic,
        .descend_symbol,
        .ascend,
        .edit_in_new_tab,
        .insert_from_library,
        .open_file_explorer,
        .make_symbol_from_schematic,
        .make_schematic_from_symbol,
        => h.handleHierarchy(imm, state),

        // Netlist
        .netlist_hierarchical,
        .netlist_top_only,
        .netlist_flat,
        => try h.handleNetlist(imm, state),

        // Insert primitive
        .insert_primitive => |kind| h.handleInsertPrimitive(kind, state),

        // Plugin
        .plugins_refresh => {
            state.plugin_refresh_requested = true;
        },
        .plugin_command => |p| {
            state.log.info("CMD", "plugin command: {s}", .{p.tag});
        },

        // Undo / Redo
        .undo => try h.handleUndo(state),
        .redo => try h.handleRedo(state),

        // Config
        .open_preferences,
        .reload_config,
        .reload_settings,
        .save_settings,
        .clear_sim_cache,
        => h.handleConfig(imm, state),

        // Waveform viewer
        .open_waveform_viewer => h.handleOpenWaveformViewer(state),

        // Import
        .run_import => |p| h.handleRunImport(p, state),

        // Optimize
        .run_optimize => h.handleOptimize(state),
        .characterize_pdk => |p| {
            state.log.info("CMD", "characterize PDK: {s}", .{p.pdk_name});
        },

        // Generate schematic from PySpice
        .generate_schematic_from_pyspice => {
            state.log.info("CMD", "generate schematic from pyspice (stub)", .{});
        },
    }
}

// ── Undoable routing ─────────────────────────────────────────────────────────

fn dispatchUndoable(und: Undoable, state: anytype) DispatchError!void {
    if (state.active()) |fio| {
        if (h.invertCommand(und) != null) {
            // Invertible: store the forward command (cheap, no allocation).
            fio.undo_history.push(.{ .inverse = und });
            fio.redo_history.clear();
        } else {
            // Non-invertible: snapshot the schematic BEFORE mutation.
            if (fio.sch.clone(fio.alloc)) |snap| {
                fio.undo_history.push(.{ .snapshot = .{
                    .sch = snap,
                    .alloc = fio.alloc,
                } });
                fio.redo_history.clear();
            } else |_| {
                // OOM — proceed without recording undo.
            }
        }
    }

    switch (und) {
        .delete_selected,
        .duplicate_selected,
        .rotate_cw,
        .rotate_ccw,
        .flip_horizontal,
        .flip_vertical,
        .nudge_left,
        .nudge_right,
        .nudge_up,
        .nudge_down,
        .align_to_grid,
        .place_device,
        .add_wire,
        .add_line,
        .add_rect,
        .add_circle,
        .add_arc,
        .add_text,
        .delete_instance,
        .delete_wire,
        .move_instance,
        .move_wire,
        .set_instance_prop,
        .rename_instance,
        .rename_net,
        .set_spice_code,
        .set_documentation,
        => try h.handleEdit(und, state),

        .run_sim => |p| h.handleRunSim(p, state),

        .auto_layout => try h.handleAutoLayout(state),

        .plugin_mutation => |p| {
            state.log.info("CMD", "plugin mutation: {s}", .{p.tag});
        },
    }
}
