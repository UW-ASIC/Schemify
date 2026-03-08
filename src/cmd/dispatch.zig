//! Central command dispatcher — routes Commands to handler groups.

const std = @import("std");
const cmd = @import("../command.zig");
const Command = cmd.Command;
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;

pub fn dispatch(c: Command, state: *AppState) !void {
    switch (c) {
        // ── View ──────────────────────────────────────────────────────────
        .zoom_in, .zoom_out, .zoom_fit, .zoom_reset, .zoom_fit_selected,
        .toggle_fullscreen, .toggle_colorscheme, .toggle_fill_rects,
        .toggle_text_in_symbols, .toggle_symbol_details,
        .show_all_layers, .show_only_current_layer,
        .increase_line_width, .decrease_line_width,
        .toggle_crosshair, .toggle_show_netlist,
        .snap_halve, .snap_double,
        .show_keybinds, .pan_interactive, .show_context_menu,
        .export_pdf, .export_png, .export_svg, .screenshot_area,
        => try @import("view.zig").handle(c, state),

        // ── Selection ─────────────────────────────────────────────────────
        .select_all, .select_none, .select_connected, .select_connected_stop_junctions,
        .highlight_dup_refdes, .rename_dup_refdes, .find_select_dialog,
        .highlight_selected_nets, .unhighlight_selected_nets, .unhighlight_all,
        .select_attached_nets,
        => try @import("selection.zig").handle(c, state),

        // ── Clipboard ─────────────────────────────────────────────────────
        .copy_selected, .clipboard_copy, .clipboard_cut, .clipboard_paste,
        => try @import("clipboard.zig").handle(c, state),

        // ── Edit (transforms, mutations with payloads) ────────────────────
        .delete_selected, .duplicate_selected,
        .rotate_cw, .rotate_ccw, .flip_horizontal, .flip_vertical,
        .nudge_left, .nudge_right, .nudge_up, .nudge_down,
        .align_to_grid,
        .move_interactive, .move_interactive_stretch, .move_interactive_insert,
        .escape_mode,
        .place_device, .delete_device, .move_device, .set_prop,
        .add_wire, .delete_wire,
        => try @import("edit.zig").handle(c, state),

        // ── Wire placement ────────────────────────────────────────────────
        .start_wire, .start_wire_snap, .cancel_wire, .finish_wire,
        .toggle_wire_routing, .toggle_orthogonal_routing,
        .break_wires_at_connections, .join_collapse_wires,
        .start_line, .start_rect, .start_polygon, .start_arc, .start_circle,
        => try @import("wire.zig").handle(c, state),

        // ── File / Tab management ─────────────────────────────────────────
        .new_tab, .close_tab, .next_tab, .prev_tab, .reopen_last_closed,
        .save_as_dialog, .save_as_symbol_dialog, .reload_from_disk,
        .clear_schematic, .merge_file_dialog,
        .place_text,
        .load_schematic, .save_schematic,
        => try @import("file.zig").handle(c, state),

        // ── Hierarchy ─────────────────────────────────────────────────────
        .descend_schematic, .descend_symbol, .ascend, .edit_in_new_tab,
        .make_symbol_from_schematic, .make_schematic_from_symbol,
        .make_schem_and_sym, .insert_from_library,
        => try @import("hierarchy.zig").handle(c, state),

        // ── Netlist ───────────────────────────────────────────────────────
        .netlist_hierarchical, .netlist_flat, .netlist_top_only,
        .toggle_flat_netlist,
        => try @import("netlist.zig").handle(c, state),

        // ── Simulation ────────────────────────────────────────────────────
        .run_sim, .open_waveform_viewer,
        => try @import("sim.zig").handle(c, state),

        // ── Properties ────────────────────────────────────────────────────
        .edit_properties, .view_properties, .edit_schematic_metadata,
        => try @import("props.zig").handle(c, state),

        // ── Plugin ────────────────────────────────────────────────────────
        .plugin_command, .plugins_refresh,
        => try @import("plugin.zig").handle(c, state),

        // ── Undo / Redo ───────────────────────────────────────────────────
        .undo, .redo,
        => try @import("undo.zig").handle(c, state),
    }
}
