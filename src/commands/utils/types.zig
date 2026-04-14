//! Command types — payloads, discriminants, and enums for the command system.
//! Commands split into Immediate (never historised) and Undoable (history ring).

const st = @import("state");
pub const Point = st.Point;
pub const Sim = st.Sim;

// Re-export PrimitiveKind from command.zig
pub const PrimitiveKind = @import("command.zig").PrimitiveKind;

// ── Payload types ─────────────────────────────────────────────────────────────

/// Index + symbolic name of a placed instance.
pub const PlaceDevice = struct { sym_path: []const u8, name: []const u8, pos: Point };
/// Index of the instance to remove.
pub const DeleteDevice = struct { idx: u32 };
/// Index + integer delta in schematic coordinates.
pub const MoveDevice = struct { idx: u32, delta: Point };
/// Property mutation — key/val are slices into the arena.
pub const SetProp = struct { idx: u32, key: []const u8, val: []const u8 };
/// Wire segment expressed as two integer endpoints.
pub const AddWire = struct { start: Point, end: Point };
/// Index of the wire to remove.
pub const DeleteWire = struct { idx: u32 };
pub const LoadSchematic = struct { path: []const u8 };
pub const SaveSchematic = struct { path: []const u8 };
pub const RunSim = struct { sim: Sim };


// ── Immediate: view/UI commands that never enter history ──────────────────────

pub const Immediate = union(enum) {
    zoom_in,
    zoom_out,
    zoom_fit,
    zoom_reset,
    zoom_fit_selected,
    toggle_fullscreen,
    toggle_colorscheme,
    toggle_fill_rects,
    toggle_text_in_symbols,
    toggle_symbol_details,
    show_all_layers,
    show_only_current_layer,
    increase_line_width,
    decrease_line_width,
    toggle_crosshair,
    toggle_show_netlist,
    snap_halve,
    snap_double,
    show_keybinds,
    pan_interactive,
    show_context_menu,
    export_pdf,
    export_png,
    export_svg,
    screenshot_area,

    select_all,
    select_none,
    select_connected,
    select_connected_stop_junctions,
    highlight_dup_refdes,
    rename_dup_refdes,
    find_select_dialog,
    highlight_selected_nets,
    unhighlight_selected_nets,
    unhighlight_all,
    select_attached_nets,

    copy_selected,
    clipboard_copy,
    clipboard_cut,
    clipboard_paste,
    align_to_grid,

    move_interactive,
    move_interactive_stretch,
    move_interactive_insert,
    escape_mode,

    start_wire,
    start_wire_snap,
    cancel_wire,
    finish_wire,
    toggle_wire_routing,
    toggle_orthogonal_routing,
    break_wires_at_connections,
    join_collapse_wires,
    start_line,
    start_rect,
    start_polygon,
    start_arc,
    start_circle,

    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    reopen_last_closed,
    save_as_dialog,
    save_as_symbol_dialog,
    reload_from_disk,
    clear_schematic,
    merge_file_dialog,
    place_text,

    descend_schematic,
    descend_symbol,
    ascend,
    edit_in_new_tab,
    make_symbol_from_schematic,
    make_schematic_from_symbol,
    make_schem_and_sym,
    insert_from_library,
    insert_primitive: PrimitiveKind,
    open_file_explorer,

    netlist_hierarchical,
    netlist_flat,
    netlist_top_only,
    toggle_flat_netlist,
    netlist_hierarchical_layout,
    netlist_flat_layout,
    netlist_top_only_layout,

    open_waveform_viewer,

    edit_properties,
    multi_edit_properties,
    view_properties,
    edit_schematic_metadata,

    plugins_refresh,
    plugin_command: struct { tag: []const u8, payload: ?[]const u8 },

    undo,
    redo,

    open_digital_block_dialog,
    open_spice_code_dialog,
};

// ── Undoable: schematic mutations that enter the history ring ─────────────────

pub const Undoable = union(enum) {
    place_device: PlaceDevice,
    delete_device: DeleteDevice,
    move_device: MoveDevice,
    set_prop: SetProp,
    add_wire: AddWire,
    delete_wire: DeleteWire,
    load_schematic: LoadSchematic,
    save_schematic: SaveSchematic,
    run_sim: RunSim,
    delete_selected,
    duplicate_selected,
    rotate_cw,
    rotate_ccw,
    flip_horizontal,
    flip_vertical,
    nudge_left,
    nudge_right,
    nudge_up,
    nudge_down,
    add_digital_block: struct {
        name_buf: [128]u8,
        name_len: usize,
        rtl_source_buf: [4096]u8,
        rtl_source_len: usize,
        language: u8,
        /// 0 = from scratch, 1 = library template
        block_mode: u8 = 0,
        /// 0 = inline, 1 = file reference
        source_mode: u8 = 0,
        /// 0 = device, 1 = stimulus
        is_stimulus: u8 = 0,
        /// 0 = behavioral, 1 = post-synth, 2 = both
        sim_preference: u8 = 0,
        /// RTL file path (source_mode == 1)
        rtl_file_path_buf: [512]u8 = [_]u8{0} ** 512,
        rtl_file_path_len: usize = 0,
        /// Synthesized SPICE file path (optional)
        synth_file_path_buf: [512]u8 = [_]u8{0} ** 512,
        synth_file_path_len: usize = 0,
    },
    edit_spice_code: struct {
        buf: [8192]u8,
        len: usize,
    },
};

// ── Top-level Command discriminant ────────────────────────────────────────────

pub const Command = union(enum) {
    immediate: Immediate,
    undoable: Undoable,
};
