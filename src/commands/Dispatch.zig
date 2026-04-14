//! Central command dispatcher — routes Commands to handler groups.
//! Plugin and Props handlers are inlined here (they are trivial stubs);
//! all other groups are delegated to their own file.

const cmd       = @import("utils/command.zig");
const Command   = cmd.Command;
const Immediate = cmd.Immediate;
const Undoable  = cmd.Undoable;

const view      = @import("handlers/View.zig");
const selection = @import("handlers/Selection.zig");
const clipboard = @import("handlers/Clipboard.zig");
const edit      = @import("handlers/Edit.zig");
const wire      = @import("handlers/Wire.zig");
const file      = @import("handlers/File.zig");
const hierarchy = @import("handlers/Hierarchy.zig");
const netlist   = @import("handlers/Netlist.zig");
const sim       = @import("handlers/Sim.zig");
const undo      = @import("handlers/Undo.zig");

/// Union of every error a handler may return. No anyerror.
pub const DispatchError =
    view.Error ||
    selection.Error ||
    clipboard.Error ||
    edit.Error ||
    wire.Error ||
    file.Error ||
    hierarchy.Error ||
    netlist.Error ||
    sim.Error ||
    undo.Error;

/// Dispatch a command to its handler.
/// `state` must be a pointer whose child exposes the fields required by handlers.
pub fn dispatch(c: Command, state: anytype) DispatchError!void {
    switch (c) {
        .immediate => |imm| try dispatchImmediate(imm, state),
        .undoable  => |und| try dispatchUndoable(und, state),
    }
}

// ── Immediate routing ────────────────────────────────────────────────────────

/// Comptime tag-to-handler mapping for Immediate commands.
/// Each entry is (list of tags, handler fn). Plugin and Props handlers are
/// inlined directly via handlePlugin and handleProps below.
fn dispatchImmediate(imm: Immediate, state: anytype) DispatchError!void {
    switch (imm) {
        // View
        .zoom_in, .zoom_out, .zoom_fit, .zoom_reset, .zoom_fit_selected,
        .toggle_fullscreen, .toggle_colorscheme,
        .toggle_fill_rects, .toggle_text_in_symbols, .toggle_symbol_details,
        .show_all_layers, .show_only_current_layer,
        .increase_line_width, .decrease_line_width,
        .toggle_crosshair, .toggle_show_netlist,
        .snap_halve, .snap_double,
        .show_keybinds, .pan_interactive, .show_context_menu,
        .export_pdf, .export_png, .export_svg, .screenshot_area,
        => try view.handle(imm, state),

        // Selection
        .select_all, .select_none, .select_connected, .select_connected_stop_junctions,
        .highlight_dup_refdes, .rename_dup_refdes, .find_select_dialog,
        .highlight_selected_nets, .unhighlight_selected_nets, .unhighlight_all,
        .select_attached_nets,
        => try selection.handle(imm, state),

        // Clipboard
        .copy_selected, .clipboard_copy, .clipboard_cut, .clipboard_paste,
        => try clipboard.handle(imm, state),

        // Edit (immediate subset)
        .align_to_grid, .move_interactive, .move_interactive_stretch,
        .move_interactive_insert, .escape_mode, .insert_primitive,
        => try edit.handleImmediate(imm, state),

        // Wire placement
        .start_wire, .start_wire_snap, .cancel_wire, .finish_wire,
        .toggle_wire_routing, .toggle_orthogonal_routing,
        .break_wires_at_connections, .join_collapse_wires,
        .start_line, .start_rect, .start_polygon, .start_arc, .start_circle,
        => try wire.handle(imm, state),

        // File / Tab
        .new_tab, .close_tab, .next_tab, .prev_tab,
        .reopen_last_closed, .save_as_dialog, .save_as_symbol_dialog,
        .reload_from_disk, .clear_schematic, .merge_file_dialog, .place_text,
        => try file.handleImmediate(imm, state),

        // Hierarchy
        .descend_schematic, .descend_symbol, .ascend, .edit_in_new_tab,
        .make_symbol_from_schematic, .make_schematic_from_symbol,
        .make_schem_and_sym, .insert_from_library, .open_file_explorer,
        => try hierarchy.handle(imm, state),

        // Netlist
        .netlist_hierarchical, .netlist_flat, .netlist_top_only, .toggle_flat_netlist,
        .netlist_hierarchical_layout, .netlist_flat_layout, .netlist_top_only_layout,
        => try netlist.handle(imm, state),

        // Simulation
        .open_waveform_viewer => try sim.handleImmediate(imm, state),

        // Digital block dialog
        .open_digital_block_dialog => state.gui.cold.digital_block_dialog.is_open = true,

        // SPICE code block dialog — seed buffer from active document then open
        .open_spice_code_dialog => {
            const sd = &state.gui.cold.spice_code_dialog;
            sd.buf_len = 0;
            if (state.active()) |fio| {
                if (fio.sch.spice_body) |body| {
                    const copy_len = @min(body.len, sd.buf.len - 1);
                    @memcpy(sd.buf[0..copy_len], body[0..copy_len]);
                    sd.buf_len = copy_len;
                }
            }
            sd.is_open = true;
        },

        // Properties
        .edit_properties => {
            const fio = state.active() orelse return;
            if (fio.selection.instances.bit_length == 0) return;
            var it = fio.selection.instances.iterator(.{});
            const idx = it.next() orelse return;
            const pd = &state.gui.cold.props_dialog;
            pd.inst_idx = idx;
            pd.view_only = false;
            pd.is_open = true;
        },
        .view_properties => {
            const fio = state.active() orelse return;
            if (fio.selection.instances.bit_length == 0) return;
            var it = fio.selection.instances.iterator(.{});
            const idx = it.next() orelse return;
            const pd = &state.gui.cold.props_dialog;
            pd.inst_idx = idx;
            pd.view_only = true;
            pd.is_open = true;
        },
        .edit_schematic_metadata => state.setStatus("Edit metadata (use CLI :rename)"),

        // Plugin (inlined — stub only)
        .plugins_refresh => state.plugin_refresh_requested = true,
        .plugin_command  => |p| state.log.info("CMD", "plugin command: {s}", .{p.tag}),

        // Undo / Redo
        .undo, .redo => try undo.handle(imm, state),
    }
}

// ── Undoable routing ─────────────────────────────────────────────────────────

fn dispatchUndoable(und: Undoable, state: anytype) DispatchError!void {
    switch (und) {
        .place_device, .delete_device, .move_device, .set_prop,
        .add_wire, .delete_wire,
        .delete_selected, .duplicate_selected,
        .rotate_cw, .rotate_ccw, .flip_horizontal, .flip_vertical,
        .nudge_left, .nudge_right, .nudge_up, .nudge_down,
        => try edit.handleUndoable(und, state),

        .load_schematic => |p| try file.handleLoad(p, state),
        .save_schematic => |p| try file.handleSave(p, state),
        .run_sim        => |p| try sim.handleRun(p, state),

        .add_digital_block => |p| {
            const core = @import("core");
            const fio = state.active() orelse return;
            const name = p.name_buf[0..p.name_len];
            const rtl  = p.rtl_source_buf[0..p.rtl_source_len];
            const lang: core.HdlLanguage = if (p.language == 0) .verilog else .vhdl;

            const rtl_file: ?[]const u8 = if (p.source_mode == 1 and p.rtl_file_path_len > 0)
                p.rtl_file_path_buf[0..p.rtl_file_path_len]
            else
                null;
            const synth_file: ?[]const u8 = if (p.synth_file_path_len > 0)
                p.synth_file_path_buf[0..p.synth_file_path_len]
            else
                null;

            fio.sch.addDigitalBlockFull(name, rtl, lang, .{
                .source_mode = if (p.source_mode == 1) .file else .@"inline",
                .rtl_file_path = rtl_file,
                .synth_file_path = synth_file,
                .is_stimulus = p.is_stimulus == 1,
                .sim_preference = p.sim_preference,
            }) catch {
                state.setStatus("Failed to add digital block");
                return;
            };
            fio.dirty = true;
            state.setStatus("Digital block added");
        },

        .edit_spice_code => |p| {
            const fio = state.active() orelse return;
            const gpa = state.allocator();
            const new_text = p.buf[0..p.len];
            // Free old spice_body if it was GPA-allocated.
            // The arena owns strings loaded from file; we replace with a GPA dupe.
            // Safe to free only if non-null; arena will handle the rest on deinit.
            if (fio.sch.spice_body) |old| {
                // Only free if it came from the GPA (not the arena).  We detect
                // this by checking whether the pointer falls outside the arena's
                // memory.  Since we can't do that cheaply, we always dupe and
                // rely on the arena to clean up on document close.
                _ = old; // suppress unused warning
            }
            if (new_text.len == 0) {
                fio.sch.spice_body = null;
            } else {
                fio.sch.spice_body = gpa.dupe(u8, new_text) catch {
                    state.setStatus("Out of memory");
                    return;
                };
            }
            fio.dirty = true;
            state.setStatus("SPICE code block updated");
        },
    }
}
