const std = @import("std");

// ── Coordinate / backend types ───────────────────────────────────────────────
// Defined locally so the command module has no dependency on gui/state.

pub const Point = [2]i32;

// ── Primitive kind ───────────────────────────────────────────────────────────

pub const PrimitiveKind = enum {
    nmos, pmos, nmos3, pmos3,
    resistor, capacitor, inductor,
    diode, zener,
    npn, pnp,
    njfet, pjfet,
    vsource, isource,
    gnd, vdd,
    input_pin, output_pin, inout_pin, lab_pin,
    probe, ammeter,
    vcvs, vccs, ccvs, cccs,
    tline,
    vswitch, iswitch,
    generic,

    pub fn kindName(self: PrimitiveKind) []const u8 {
        return @tagName(self);
    }

    pub fn prefix(self: PrimitiveKind) u8 {
        return switch (self) {
            .resistor => 'R',
            .capacitor => 'C',
            .inductor => 'L',
            .diode, .zener => 'D',
            .nmos, .pmos, .nmos3, .pmos3 => 'M',
            .npn, .pnp => 'Q',
            .njfet, .pjfet => 'J',
            .vsource => 'V',
            .isource, .ammeter => 'I',
            .vcvs => 'E',
            .vccs => 'G',
            .ccvs => 'H',
            .cccs => 'F',
            .tline => 'T',
            .vswitch, .iswitch => 'S',
            .probe => 'P',
            .gnd, .vdd, .input_pin, .output_pin, .inout_pin, .lab_pin, .generic => 'X',
        };
    }
};

// ── Undoable payload types ───────────────────────────────────────────────────

pub const PlaceDevice = struct {
    sym_path: []const u8,
    name: []const u8,
    x: i32,
    y: i32,
};

pub const AddWire = struct {
    x0: i32, y0: i32,
    x1: i32, y1: i32,
    net_name: ?[]const u8 = null,
};

pub const DeleteWire = struct { idx: u32 };
pub const DeleteInstance = struct { idx: u32 };

pub const MoveInstance = struct {
    idx: u32,
    dx: i32,
    dy: i32,
};

pub const MoveWire = struct {
    idx: u32,
    dx: i32,
    dy: i32,
};

pub const SetInstanceProp = struct {
    idx: u32,
    key: []const u8,
    val: []const u8,
};

pub const RenameInstance = struct {
    idx: u32,
    new_name: []const u8,
};

pub const RenameNet = struct {
    wire_idx: u32,
    new_name: []const u8,
};

pub const RunSim = struct {};

pub const SetSpiceCode = struct {
    code: []const u8,
};

pub const SetDocumentation = struct {
    content: []const u8,
};

pub const AddLine = struct {
    x0: i32, y0: i32, x1: i32, y1: i32,
    layer: u8 = 4,
};

pub const AddRect = struct {
    x0: i32, y0: i32, x1: i32, y1: i32,
    layer: u8 = 4,
};

pub const AddCircle = struct {
    cx: i32, cy: i32, radius: i32,
    layer: u8 = 4,
};

pub const AddArc = struct {
    cx: i32, cy: i32, radius: i32,
    start_angle: i16, sweep_angle: i16,
    layer: u8 = 4,
};

pub const AddText = struct {
    content: []const u8,
    x: i32, y: i32,
    layer: u8 = 4,
    size: u8 = 10,
};

pub const PluginMutation = struct {
    tag: []const u8,
    payload: ?[]const u8 = null,
};

// ── Immediate payload types ────────────────────────────────────────────────

pub const RunImport = struct {
    path: []const u8,
};

// ── Immediate: view/UI commands that never enter history ─────────────────────

pub const Immediate = union(enum) {
    // View
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
    toggle_grid,
    snap_halve,
    snap_double,
    show_keybinds,
    pan_interactive,
    show_context_menu,

    // File / Tab
    file_new,
    file_open,
    file_save,
    file_save_as,
    file_save_all,
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    reopen_closed_tab,
    reload_from_disk,

    // Selection
    select_all,
    select_none,
    invert_selection,
    find_select_dialog,

    // Clipboard
    clipboard_copy,
    clipboard_cut,
    clipboard_paste,

    // Mode / Tool
    escape_mode,
    start_wire,
    tool_select,
    tool_move,
    tool_pan,
    tool_line,
    tool_rect,
    tool_polygon,
    tool_arc,
    tool_circle,
    tool_text,
    open_file_explorer,
    insert_from_library,
    insert_primitive: PrimitiveKind,

    // Dialogs
    open_find_dialog,
    open_props_dialog,
    open_spice_code_dialog,
    open_marketplace,
    open_new_prim_dialog,
    open_import_project,
    edit_properties,

    // Plugin (extensible — plugins dispatch arbitrary commands via tag)
    plugins_refresh,
    plugin_command: struct { tag: []const u8, payload: ?[]const u8 },

    // Undo / Redo
    undo,
    redo,

    // Net
    highlight_selected_nets,
    unhighlight_all,
    netlist_hierarchical,
    netlist_top_only,
    netlist_flat,

    // Hierarchy
    descend_schematic,
    descend_symbol,
    ascend,
    edit_in_new_tab,

    // Export
    export_pdf,
    export_png,
    export_svg,
    export_netlist,

    // Print
    print_schematic,

    // Config / Preferences
    open_preferences,
    reload_config,
    reload_settings,
    save_settings,
    clear_sim_cache,

    // Stubs (not yet implemented — used by plugins via push_command)
    select_attached_nets,
    toggle_orthogonal_routing,
    make_symbol_from_schematic,
    make_schematic_from_symbol,
    open_waveform_viewer,

    // Import
    run_import: RunImport,

    // Optimizer
    run_optimize,
    characterize_pdk: struct { pdk_name: []const u8 },

    // Chat / Documentation
    toggle_chat_panel,
    generate_schematic_from_pyspice,
    view_doc,
};

// ── Undoable: schematic mutations that enter the history ring ─────────────────

pub const Undoable = union(enum) {
    // Selection operations
    delete_selected,
    duplicate_selected,

    // Transform
    rotate_cw,
    rotate_ccw,
    flip_horizontal,
    flip_vertical,
    nudge_left,
    nudge_right,
    nudge_up,
    nudge_down,
    align_to_grid,

    // Placement
    place_device: PlaceDevice,
    add_wire: AddWire,

    // Geometry
    add_line: AddLine,
    add_rect: AddRect,
    add_circle: AddCircle,
    add_arc: AddArc,
    add_text: AddText,

    // Deletion (individual)
    delete_instance: DeleteInstance,
    delete_wire: DeleteWire,

    // Move
    move_instance: MoveInstance,
    move_wire: MoveWire,

    // Properties
    set_instance_prop: SetInstanceProp,
    rename_instance: RenameInstance,
    rename_net: RenameNet,
    set_spice_code: SetSpiceCode,

    // Documentation
    set_documentation: SetDocumentation,

    // Simulation
    run_sim: RunSim,

    // Layout
    auto_layout,

    // Plugin (extensible — plugins dispatch arbitrary mutations via tag)
    plugin_mutation: PluginMutation,
};

// ── Top-level Command ────────────────────────────────────────────────────────

pub const Command = union(enum) {
    immediate: Immediate,
    undoable: Undoable,
};

