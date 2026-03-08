//! Command system — every schematic mutation is expressed as a Command.
//! The History stack drives undo/redo; plugins can also inject Commands.
//! The CommandQueue is a fixed-capacity ring buffer drained once per frame.

const std = @import("std");
const state_mod = @import("state.zig");
const CT = state_mod.CT;

// ── Command payload types ─────────────────────────────────────────────────────

pub const PlaceDevice = struct { sym_path: []const u8, name: []const u8, x: f64, y: f64 };
pub const DeleteDevice = struct { idx: usize };
pub const MoveDevice = struct { idx: usize, dx: f64, dy: f64 };
pub const SetProp = struct { idx: usize, key: []const u8, val: []const u8 };
pub const AddWire = struct { x0: f64, y0: f64, x1: f64, y1: f64 };
pub const DeleteWire = struct { idx: usize };
pub const LoadSchematic = struct { path: []const u8 };
pub const SaveSchematic = struct { path: []const u8 };
pub const RunSim = struct { sim: state_mod.Sim };

// ── Command union ─────────────────────────────────────────────────────────────

pub const Command = union(enum) {
    // ── Schematic mutations (recorded in history) ─────────────────────────────
    place_device: PlaceDevice,
    delete_device: DeleteDevice,
    move_device: MoveDevice,
    set_prop: SetProp,
    add_wire: AddWire,
    delete_wire: DeleteWire,
    load_schematic: LoadSchematic,
    save_schematic: SaveSchematic,
    run_sim: RunSim,
    delete_selected: void,
    duplicate_selected: void,
    rotate_cw: void,
    rotate_ccw: void,
    flip_horizontal: void,
    flip_vertical: void,
    nudge_left: void,
    nudge_right: void,
    nudge_up: void,
    nudge_down: void,

    // ── View (not recorded in history) ────────────────────────────────────────
    zoom_in: void,
    zoom_out: void,
    zoom_fit: void,
    zoom_reset: void,
    zoom_fit_selected: void,
    toggle_fullscreen: void,
    toggle_colorscheme: void,
    toggle_fill_rects: void,
    toggle_text_in_symbols: void,
    toggle_symbol_details: void,
    show_all_layers: void,
    show_only_current_layer: void,
    increase_line_width: void,
    decrease_line_width: void,
    toggle_crosshair: void,
    toggle_show_netlist: void,

    // ── Selection (not recorded in history) ───────────────────────────────────
    select_all: void,
    select_none: void,
    select_connected: void,
    select_connected_stop_junctions: void,
    highlight_dup_refdes: void,
    rename_dup_refdes: void,
    find_select_dialog: void,
    highlight_selected_nets: void,
    unhighlight_selected_nets: void,
    unhighlight_all: void,
    select_attached_nets: void,

    // ── Move / Copy ───────────────────────────────────────────────────────────
    move_interactive: void,
    move_interactive_stretch: void,
    move_interactive_insert: void,
    copy_selected: void,
    clipboard_cut: void,
    clipboard_copy: void,
    clipboard_paste: void,
    align_to_grid: void,

    // ── Wire placement ────────────────────────────────────────────────────────
    start_wire: void,
    start_wire_snap: void,
    cancel_wire: void,
    finish_wire: void,
    toggle_wire_routing: void,
    toggle_orthogonal_routing: void,
    break_wires_at_connections: void,
    join_collapse_wires: void,

    // ── Graphic primitives ────────────────────────────────────────────────────
    start_line: void,
    start_rect: void,
    start_polygon: void,
    start_arc: void,
    start_circle: void,
    place_text: void,

    // ── Hierarchy ─────────────────────────────────────────────────────────────
    descend_schematic: void,
    descend_symbol: void,
    ascend: void,
    edit_in_new_tab: void,

    // ── Properties ────────────────────────────────────────────────────────────
    edit_properties: void,
    view_properties: void,
    edit_schematic_metadata: void,

    // ── Netlist ───────────────────────────────────────────────────────────────
    netlist_hierarchical: void,
    netlist_flat: void,
    netlist_top_only: void,
    toggle_flat_netlist: void,

    // ── Symbol creation ───────────────────────────────────────────────────────
    make_symbol_from_schematic: void,
    make_schematic_from_symbol: void,
    make_schem_and_sym: void,
    insert_from_library: void,

    // ── Tab management ────────────────────────────────────────────────────────
    new_tab: void,
    close_tab: void,
    next_tab: void,
    prev_tab: void,
    reopen_last_closed: void,

    // ── File operations ───────────────────────────────────────────────────────
    save_as_dialog: void,
    save_as_symbol_dialog: void,
    reload_from_disk: void,
    clear_schematic: void,
    merge_file_dialog: void,

    // ── Snap ──────────────────────────────────────────────────────────────────
    snap_halve: void,
    snap_double: void,

    // ── Export ────────────────────────────────────────────────────────────────
    export_pdf: void,
    export_png: void,
    export_svg: void,
    screenshot_area: void,

    // ── Simulation extras ─────────────────────────────────────────────────────
    open_waveform_viewer: void,

    // ── Misc ──────────────────────────────────────────────────────────────────
    show_keybinds: void,
    pan_interactive: void,
    escape_mode: void,
    show_context_menu: void,

    // ── Undo/redo (never recorded) ────────────────────────────────────────────
    undo: void,
    redo: void,

    // ── Runtime plugin lifecycle signal ───────────────────────────────────────
    plugins_refresh: void,

    // ── Plugin command (dispatched to plugin on_command callback) ─────────────
    plugin_command: struct { tag: []const u8, payload: ?[]const u8 },
};

// ── Command queue (fixed-capacity ring buffer, no heap allocs) ────────────────

pub const CommandQueue = struct {
    const CAP = 256;
    buf: [CAP]Command = undefined,
    head: usize = 0,
    tail: usize = 0,

    pub fn push(self: *CommandQueue, c: Command) error{Full}!void {
        const next = (self.tail + 1) % CAP;
        if (next == self.head) return error.Full;
        self.buf[self.tail] = c;
        self.tail = next;
    }

    pub fn pop(self: *CommandQueue) ?Command {
        if (self.head == self.tail) return null;
        const c = self.buf[self.head];
        self.head = (self.head + 1) % CAP;
        return c;
    }

    pub fn isEmpty(self: *const CommandQueue) bool {
        return self.head == self.tail;
    }
};

// ── Single dispatcher — routes to cmd/ group handlers ─────────────────────────

pub const dispatch = @import("cmd/dispatch.zig").dispatch;

// ── Inverse command types ─────────────────────────────────────────────────────

pub const RestoreSnapshot = struct {
    instances: []CT.Instance,
    wires: []CT.Wire,
};

pub const DeleteLastN = struct { n: usize };

pub const CommandInverse = union(enum) {
    none: void,
    place_device: DeleteDevice,
    delete_device: PlaceDevice,
    move_device: MoveDevice,
    set_prop: SetProp,
    add_wire: DeleteWire,
    delete_wire: AddWire,
    delete_selected: RestoreSnapshot,
    duplicate_selected: DeleteLastN,
};

// ── Undo/redo history ─────────────────────────────────────────────────────────

pub const HistoryEntry = struct {
    fwd: Command,
    inv: CommandInverse,
};

/// Ring-buffer history with inverse commands (Option A).
/// Push records (fwd, inv) pairs; popUndo walks back one step.
/// Redo not supported in Option A.
pub const History = struct {
    entries: [256]HistoryEntry = undefined,
    len: usize = 0,
    head: usize = 0,
    undo_depth: usize = 0,

    pub fn push(self: *History, fwd: Command, inv: CommandInverse) void {
        self.entries[self.head % 256] = .{ .fwd = fwd, .inv = inv };
        self.head = (self.head + 1) % 256;
        if (self.len < 256) self.len += 1;
        self.undo_depth = 0;
    }

    pub fn popUndo(self: *History) ?CommandInverse {
        if (self.len == 0) return null;
        self.head = if (self.head == 0) 255 else self.head - 1;
        const entry = self.entries[self.head];
        self.len -= 1;
        return entry.inv;
    }

    pub fn popRedo(_: *History) ?Command {
        return null; // not supported in Option A
    }

    pub fn deinit(self: *History, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
        // Ring buffer is stack-allocated; snapshot slices leak on exit (acceptable).
    }
};
