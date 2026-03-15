//! Central command dispatcher — routes Commands to handler groups via flat switch.
//! No function pointers. No dispatch table. Each arm resolves at comptime to a
//! direct call to the appropriate handler module.

const cmd       = @import("command.zig");
const Command   = cmd.Command;
const Immediate = cmd.Immediate;
const Undoable  = cmd.Undoable;

const view      = @import("View.zig");
const selection = @import("Selection.zig");
const clipboard = @import("Clipboard.zig");
const edit      = @import("Edit.zig");
const wire      = @import("Wire.zig");
const file      = @import("File.zig");
const hierarchy = @import("Hierarchy.zig");
const netlist   = @import("Netlist.zig");
const sim       = @import("Sim.zig");
const props     = @import("Props.zig");
const plugin    = @import("Plugin.zig");
const undo      = @import("Undo.zig");

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
    props.Error ||
    plugin.Error ||
    undo.Error;

/// Dispatch a command to its handler.
/// `state` must be a pointer whose child exposes the fields required by handlers.
pub fn dispatch(c: Command, state: anytype) DispatchError!void {
    switch (c) {
        .immediate => |imm| switch (imm) {
            // ── View ──────────────────────────────────────────────────────────
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
            .snap_halve,
            .snap_double,
            .show_keybinds,
            .pan_interactive,
            .show_context_menu,
            .export_pdf,
            .export_png,
            .export_svg,
            .screenshot_area,
            => try view.handle(imm, state),

            // ── Selection ─────────────────────────────────────────────────────
            .select_all,
            .select_none,
            .select_connected,
            .select_connected_stop_junctions,
            .highlight_dup_refdes,
            .rename_dup_refdes,
            .find_select_dialog,
            .highlight_selected_nets,
            .unhighlight_selected_nets,
            .unhighlight_all,
            .select_attached_nets,
            => try selection.handle(imm, state),

            // ── Clipboard ─────────────────────────────────────────────────────
            .copy_selected,
            .clipboard_copy,
            .clipboard_cut,
            .clipboard_paste,
            => try clipboard.handle(imm, state),

            // ── Edit (immediate subset) ────────────────────────────────────────
            .align_to_grid,
            .move_interactive,
            .move_interactive_stretch,
            .move_interactive_insert,
            .escape_mode,
            => try edit.handleImmediate(imm, state),

            // ── Wire placement ────────────────────────────────────────────────
            .start_wire,
            .start_wire_snap,
            .cancel_wire,
            .finish_wire,
            .toggle_wire_routing,
            .toggle_orthogonal_routing,
            .break_wires_at_connections,
            .join_collapse_wires,
            .start_line,
            .start_rect,
            .start_polygon,
            .start_arc,
            .start_circle,
            => try wire.handle(imm, state),

            // ── File / Tab ────────────────────────────────────────────────────
            .new_tab,
            .close_tab,
            .next_tab,
            .prev_tab,
            .reopen_last_closed,
            .save_as_dialog,
            .save_as_symbol_dialog,
            .reload_from_disk,
            .clear_schematic,
            .merge_file_dialog,
            .place_text,
            => try file.handleImmediate(imm, state),

            // ── Hierarchy ─────────────────────────────────────────────────────
            .descend_schematic,
            .descend_symbol,
            .ascend,
            .edit_in_new_tab,
            .make_symbol_from_schematic,
            .make_schematic_from_symbol,
            .make_schem_and_sym,
            .insert_from_library,
            => try hierarchy.handle(imm, state),

            // ── Netlist ───────────────────────────────────────────────────────
            .netlist_hierarchical,
            .netlist_flat,
            .netlist_top_only,
            .toggle_flat_netlist,
            => try netlist.handle(imm, state),

            // ── Simulation ────────────────────────────────────────────────────
            .open_waveform_viewer => try sim.handleImmediate(imm, state),

            // ── Properties ───────────────────────────────────────────────────
            .edit_properties,
            .view_properties,
            .edit_schematic_metadata,
            => try props.handle(imm, state),

            // ── Plugin ────────────────────────────────────────────────────────
            .plugins_refresh,
            .plugin_command,
            => try plugin.handle(imm, state),

            // ── Undo / Redo ───────────────────────────────────────────────────
            .undo, .redo => try undo.handle(imm, state),
        },

        .undoable => |und| switch (und) {
            .place_device,
            .delete_device,
            .move_device,
            .set_prop,
            .add_wire,
            .delete_wire,
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
            => try edit.handleUndoable(und, state),

            .load_schematic => |p| try file.handleLoad(p, state),
            .save_schematic => |p| try file.handleSave(p, state),
            .run_sim        => |p| try sim.handleRun(p, state),
        },
    }
}
