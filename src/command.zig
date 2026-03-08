//! Command system — every schematic mutation is expressed as a Command.
//! The History stack drives undo/redo; plugins can also inject Commands.
//! The CommandQueue is a fixed-capacity ring buffer drained once per frame.

const std = @import("std");
const state_mod = @import("state.zig");
const CT = state_mod.CT;
const core = @import("core");

// ── Module-level persistent buffers ──────────────────────────────────────────
// status_msg in AppState holds a []const u8 pointer; use a static buffer so the
// netlist status string survives past the dispatch call frame.
var netlist_status_buf: [256]u8 = undefined;

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

// ── Single dispatcher — the only place state is mutated ───────────────────────

const AppState = state_mod.AppState;

pub fn dispatch(c: Command, state: *AppState) !void {
    switch (c) {
        // ── View ──────────────────────────────────────────────────────────
        .zoom_in => state.view.zoomIn(),
        .zoom_out => state.view.zoomOut(),
        .zoom_fit => state.view.zoomFit(),
        .zoom_reset => state.view.zoomReset(),
        .zoom_fit_selected => state.setStatus("Zoom fit selected (stub)"),
        .toggle_fullscreen => {
            state.cmd_flags.fullscreen = !state.cmd_flags.fullscreen;
            state.setStatus(if (state.cmd_flags.fullscreen) "Fullscreen on (stub)" else "Fullscreen off (stub)");
        },
        .toggle_colorscheme => {
            state.cmd_flags.dark_mode = !state.cmd_flags.dark_mode;
            state.setStatus(if (state.cmd_flags.dark_mode) "Dark mode on (stub)" else "Dark mode off (stub)");
        },
        .toggle_fill_rects => {
            state.cmd_flags.fill_rects = !state.cmd_flags.fill_rects;
            state.setStatus(if (state.cmd_flags.fill_rects) "Fill rects on (stub)" else "Fill rects off (stub)");
        },
        .toggle_text_in_symbols => {
            state.cmd_flags.text_in_symbols = !state.cmd_flags.text_in_symbols;
            state.setStatus(if (state.cmd_flags.text_in_symbols) "Text in symbols on (stub)" else "Text in symbols off (stub)");
        },
        .toggle_symbol_details => {
            state.cmd_flags.symbol_details = !state.cmd_flags.symbol_details;
            state.setStatus(if (state.cmd_flags.symbol_details) "Symbol details on (stub)" else "Symbol details off (stub)");
        },
        .show_all_layers => {
            state.cmd_flags.show_all_layers = true;
            state.setStatus("Showing all layers (stub)");
        },
        .show_only_current_layer => {
            state.cmd_flags.show_all_layers = false;
            state.setStatus("Showing current layer only (stub)");
        },
        .increase_line_width => {
            state.cmd_flags.line_width = @min(10, state.cmd_flags.line_width + 1);
            state.setStatus("Increased line width (stub)");
        },
        .decrease_line_width => {
            state.cmd_flags.line_width = @max(1, state.cmd_flags.line_width - 1);
            state.setStatus("Decreased line width (stub)");
        },
        .toggle_crosshair => {
            state.cmd_flags.crosshair = !state.cmd_flags.crosshair;
            state.setStatus(if (state.cmd_flags.crosshair) "Crosshair on (stub)" else "Crosshair off (stub)");
        },
        .toggle_show_netlist => {
            state.cmd_flags.show_netlist = !state.cmd_flags.show_netlist;
            state.setStatus(if (state.cmd_flags.show_netlist) "Netlist panel shown" else "Netlist panel hidden");
        },

        // ── Selection ─────────────────────────────────────────────────────
        .select_all => state.selectAll(),
        .select_none => state.selection.clear(),
        .select_connected => state.setStatus("Select connected (stub)"),
        .select_connected_stop_junctions => state.setStatus("Select connected (stop junctions) (stub)"),
        .highlight_dup_refdes => state.setStatus("Highlight duplicate refdes (stub)"),
        .rename_dup_refdes => state.setStatus("Rename duplicate refdes (stub)"),
        .find_select_dialog => state.setStatus("Find/select dialog (stub)"),
        .highlight_selected_nets => state.setStatus("Highlight selected nets (stub)"),
        .unhighlight_selected_nets => state.setStatus("Unhighlight selected nets (stub)"),
        .unhighlight_all => state.setStatus("Unhighlight all (stub)"),
        .select_attached_nets => state.setStatus("Select attached nets (stub)"),

        // ── Undo / Redo ───────────────────────────────────────────────────
        .undo => {
            _ = try state.history.undo(state.allocator());
        },
        .redo => {
            _ = try state.history.redo(state.allocator());
        },

        // ── Plugin lifecycle ──────────────────────────────────────────────
        .plugins_refresh => state.plugin_refresh_requested = true,

        // ── Plugin command ───────────────────────────────────────────────
        .plugin_command => |p| {
            state.log.info("CMD", "plugin command: {s}", .{p.tag});
        },

        // ── Move / Copy ───────────────────────────────────────────────────
        .move_interactive => {
            state.tool.active = .move;
            state.setStatus("Move interactive (stub)");
        },
        .move_interactive_stretch => {
            state.tool.active = .move;
            state.setStatus("Move interactive stretch (stub)");
        },
        .move_interactive_insert => {
            state.tool.active = .move;
            state.setStatus("Move interactive insert wires (stub)");
        },
        .copy_selected => state.setStatus("Copy selected (stub)"),
        .clipboard_cut => state.setStatus("Cut to clipboard (stub)"),
        .clipboard_copy => state.setStatus("Copy to clipboard (stub)"),
        .clipboard_paste => state.setStatus("Paste from clipboard (stub)"),
        .align_to_grid => state.setStatus("Align to grid (stub)"),

        // ── Transform (operate on selection) ──────────────────────────────
        .delete_selected => {
            const fio = state.active() orelse return;
            const sch = fio.schematic();

            var wi = sch.wires.items.len;
            while (wi > 0) {
                wi -= 1;
                if (wi < state.selection.wires.bit_length and state.selection.wires.isSet(wi)) {
                    _ = sch.wires.orderedRemove(wi);
                }
            }

            var ii = sch.instances.items.len;
            while (ii > 0) {
                ii -= 1;
                if (ii < state.selection.instances.bit_length and state.selection.instances.isSet(ii)) {
                    _ = sch.instances.orderedRemove(ii);
                }
            }

            state.selection.clear();
            fio.dirty = true;
        },
        .duplicate_selected => {
            const fio = state.active() orelse return;
            duplicateSelected(fio, state);
        },
        .rotate_cw => {
            const fio = state.active() orelse return;
            rotateSelected(fio, state, 1);
        },
        .rotate_ccw => {
            const fio = state.active() orelse return;
            rotateSelected(fio, state, 3);
        },
        .flip_horizontal => {
            const fio = state.active() orelse return;
            flipSelected(fio, state);
        },
        .flip_vertical => {
            const fio = state.active() orelse return;
            flipSelected(fio, state);
            rotateSelected(fio, state, 2);
        },
        .nudge_left => {
            const fio = state.active() orelse return;
            nudgeSelected(fio, state, -10, 0);
        },
        .nudge_right => {
            const fio = state.active() orelse return;
            nudgeSelected(fio, state, 10, 0);
        },
        .nudge_up => {
            const fio = state.active() orelse return;
            nudgeSelected(fio, state, 0, -10);
        },
        .nudge_down => {
            const fio = state.active() orelse return;
            nudgeSelected(fio, state, 0, 10);
        },

        // ── Wire placement ────────────────────────────────────────────────
        .start_wire => {
            state.tool.active = .wire;
            state.tool.wire_start = null;
            state.setStatus("Wire mode — click to start");
        },
        .start_wire_snap => {
            state.tool.active = .wire;
            state.tool.wire_start = null;
            state.setStatus("Wire mode (snap) — click to start");
        },
        .cancel_wire => {
            state.tool.wire_start = null;
            state.tool.active = .select;
            state.setStatus("Wire canceled");
        },
        .finish_wire => state.setStatus("Wire finished (stub)"),
        .toggle_wire_routing => {
            state.cmd_flags.wire_routing = !state.cmd_flags.wire_routing;
            state.setStatus(if (state.cmd_flags.wire_routing) "Wire routing on (stub)" else "Wire routing off (stub)");
        },
        .toggle_orthogonal_routing => {
            state.cmd_flags.orthogonal_routing = !state.cmd_flags.orthogonal_routing;
            state.setStatus(if (state.cmd_flags.orthogonal_routing) "Orthogonal routing on (stub)" else "Orthogonal routing off (stub)");
        },
        .break_wires_at_connections => state.setStatus("Break wires at connections (stub)"),
        .join_collapse_wires => state.setStatus("Join/collapse wires (stub)"),

        // ── Graphic primitives ────────────────────────────────────────────
        .start_line => {
            state.tool.active = .line;
            state.setStatus("Line draw mode (stub)");
        },
        .start_rect => {
            state.tool.active = .rect;
            state.setStatus("Rect draw mode (stub)");
        },
        .start_polygon => {
            state.tool.active = .polygon;
            state.setStatus("Polygon draw mode (stub)");
        },
        .start_arc => {
            state.tool.active = .arc;
            state.setStatus("Arc draw mode (stub)");
        },
        .start_circle => {
            state.tool.active = .circle;
            state.setStatus("Circle draw mode (stub)");
        },
        .place_text => {
            state.tool.active = .text;
            state.setStatus("Place text (stub)");
        },

        // ── Hierarchy ─────────────────────────────────────────────────────
        .descend_schematic => {
            const fio = state.active() orelse return;
            const inst_idx = firstSelectedInstance(state) orelse {
                state.setStatus("No instance selected");
                return;
            };
            const sch = fio.schematic();
            if (inst_idx >= sch.instances.items.len) {
                state.setStatus("Selected instance index out of range");
                return;
            }
            const inst = &sch.instances.items[inst_idx];
            // Replace .sym extension with .chn to find the schematic path
            const sym_path = inst.symbol;
            var sch_path: []const u8 = undefined;
            var sch_path_owned = false;
            if (std.mem.endsWith(u8, sym_path, ".sym")) {
                const base = sym_path[0 .. sym_path.len - 4];
                const p = try std.fmt.allocPrint(state.allocator(), "{s}.chn", .{base});
                sch_path = p;
                sch_path_owned = true;
            } else {
                sch_path = sym_path;
            }
            defer if (sch_path_owned) state.allocator().free(sch_path);
            try state.hierarchy_stack.append(state.allocator(), .{
                .doc_idx = state.active_idx,
                .instance_idx = inst_idx,
            });
            state.openPath(sch_path) catch |err| {
                _ = state.hierarchy_stack.pop();
                state.setStatusErr("Failed to descend into schematic");
                state.log.err("CMD", "descend_schematic failed: {}", .{err});
            };
        },
        .descend_symbol => {
            const fio = state.active() orelse return;
            const inst_idx = firstSelectedInstance(state) orelse {
                state.setStatus("No instance selected");
                return;
            };
            const sch = fio.schematic();
            if (inst_idx >= sch.instances.items.len) {
                state.setStatus("Selected instance index out of range");
                return;
            }
            const inst = &sch.instances.items[inst_idx];
            const sym_path = inst.symbol;
            try state.hierarchy_stack.append(state.allocator(), .{
                .doc_idx = state.active_idx,
                .instance_idx = inst_idx,
            });
            state.openPath(sym_path) catch |err| {
                _ = state.hierarchy_stack.pop();
                state.setStatusErr("Failed to descend into symbol");
                state.log.err("CMD", "descend_symbol failed: {}", .{err});
                return;
            };
            state.gui.view_mode = .symbol;
        },
        .ascend => {
            const entry = state.hierarchy_stack.pop() orelse {
                state.setStatus("Already at top level");
                return;
            };
            if (entry.doc_idx >= state.schematics.items.len) {
                state.setStatus("Hierarchy parent no longer open");
                return;
            }
            state.active_idx = entry.doc_idx;
            state.selection.clear();
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            const inst_count = sch.instances.items.len;
            const alloc = state.allocator();
            state.selection.instances.resize(alloc, inst_count, false) catch return;
            if (entry.instance_idx < inst_count) {
                state.selection.instances.set(entry.instance_idx);
            }
            state.setStatus("Ascended to parent");
        },
        .edit_in_new_tab => {
            const fio = state.active() orelse return;
            const inst_idx = firstSelectedInstance(state) orelse {
                state.setStatus("No instance selected");
                return;
            };
            const sch = fio.schematic();
            if (inst_idx >= sch.instances.items.len) {
                state.setStatus("Selected instance index out of range");
                return;
            }
            const inst = &sch.instances.items[inst_idx];
            const sym_path = inst.symbol;
            state.openPath(sym_path) catch |err| {
                state.setStatusErr("Failed to open symbol in new tab");
                state.log.err("CMD", "edit_in_new_tab failed: {}", .{err});
            };
        },

        // ── Properties ────────────────────────────────────────────────────
        .edit_properties => {
            const fio = state.active() orelse {
                state.setStatus("No active schematic");
                return;
            };
            const sch = fio.schematic();
            // Find first selected instance
            var inst_idx: ?usize = null;
            for (0..sch.instances.items.len) |i| {
                if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i)) {
                    inst_idx = i;
                    break;
                }
            }
            const idx = inst_idx orelse {
                state.setStatus("No instance selected");
                return;
            };
            const inst = &sch.instances.items[idx];
            state.gui.props_dialog_open = true;
            state.gui.props_view_only = false;
            state.gui.props_inst_idx = idx;
            for (0..16) |i| {
                @memset(&state.gui.props_bufs[i], 0);
                state.gui.props_lens[i] = 0;
                state.gui.props_dirty[i] = false;
            }
            const prop_count = @min(inst.props.items.len, 16);
            for (0..prop_count) |i| {
                const val = inst.props.items[i].val;
                const copy_len = @min(val.len, 127);
                @memcpy(state.gui.props_bufs[i][0..copy_len], val[0..copy_len]);
                state.gui.props_lens[i] = copy_len;
            }
            state.setStatus("Editing instance properties");
        },
        .view_properties => {
            const fio = state.active() orelse {
                state.setStatus("No active schematic");
                return;
            };
            const sch = fio.schematic();
            var inst_idx: ?usize = null;
            for (0..sch.instances.items.len) |i| {
                if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i)) {
                    inst_idx = i;
                    break;
                }
            }
            const idx = inst_idx orelse {
                state.setStatus("No instance selected");
                return;
            };
            const inst = &sch.instances.items[idx];
            state.gui.props_dialog_open = true;
            state.gui.props_view_only = true;
            state.gui.props_inst_idx = idx;
            for (0..16) |i| {
                @memset(&state.gui.props_bufs[i], 0);
                state.gui.props_lens[i] = 0;
                state.gui.props_dirty[i] = false;
            }
            const prop_count = @min(inst.props.items.len, 16);
            for (0..prop_count) |i| {
                const val = inst.props.items[i].val;
                const copy_len = @min(val.len, 127);
                @memcpy(state.gui.props_bufs[i][0..copy_len], val[0..copy_len]);
                state.gui.props_lens[i] = copy_len;
            }
            state.setStatus("Viewing instance properties");
        },
        .edit_schematic_metadata => state.setStatus("(stub — use CLI :rename)"),

        // ── Netlist ───────────────────────────────────────────────────────
        .netlist_hierarchical => {
            const alloc = state.allocator();
            generateNetlistAndStore(state, alloc, "Netlist written to ") catch |err| {
                state.log.err("CMD", "netlist_hierarchical failed: {}", .{err});
                state.setStatusErr("Netlist generation failed");
            };
        },
        .netlist_flat => {
            const alloc = state.allocator();
            generateNetlistAndStore(state, alloc, "Flat netlist written to ") catch |err| {
                state.log.err("CMD", "netlist_flat failed: {}", .{err});
                state.setStatusErr("Flat netlist generation failed");
            };
        },
        .netlist_top_only => {
            const alloc = state.allocator();
            generateNetlistAndStore(state, alloc, "Top-level netlist written to ") catch |err| {
                state.log.err("CMD", "netlist_top_only failed: {}", .{err});
                state.setStatusErr("Top-level netlist generation failed");
            };
        },
        .toggle_flat_netlist => {
            state.cmd_flags.flat_netlist = !state.cmd_flags.flat_netlist;
            state.setStatus(if (state.cmd_flags.flat_netlist) "Flat netlist on (stub)" else "Flat netlist off (stub)");
        },

        // ── Symbol creation ───────────────────────────────────────────────
        .make_symbol_from_schematic => state.setStatus("Make symbol from schematic (stub)"),
        .make_schematic_from_symbol => state.setStatus("Make schematic from symbol (stub)"),
        .make_schem_and_sym => state.setStatus("Make both schematic and symbol (stub)"),
        .insert_from_library => {
            state.gui.lib_browser_open = true;
            state.gui.lib_selected = -1;
            state.gui.lib_entry_count = 0;
            var sym_path_buf: [512]u8 = undefined;
            const sym_dir_path = std.fmt.bufPrint(&sym_path_buf, "{s}/symbols", .{state.project_dir})
                catch {
                    state.setStatus("Library path too long");
                    return;
                };
            var sym_dir = std.fs.openDirAbsolute(sym_dir_path, .{ .iterate = true }) catch |err| blk: {
                _ = err;
                break :blk std.fs.cwd().openDir("symbols", .{ .iterate = true }) catch {
                    state.setStatus("Library browser: symbols/ dir not found");
                    return;
                };
            };
            defer sym_dir.close();
            var it = sym_dir.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".chn_sym")) continue;
                if (state.gui.lib_entry_count >= 256) break;
                const idx = state.gui.lib_entry_count;
                @memset(&state.gui.lib_entries[idx], 0);
                const copy_len = @min(entry.name.len, 255);
                @memcpy(state.gui.lib_entries[idx][0..copy_len], entry.name[0..copy_len]);
                state.gui.lib_entry_count += 1;
            }
            state.setStatus("Library browser opened");
        },

        // ── Tab management ────────────────────────────────────────────────
        .new_tab => {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "untitled_{d}", .{state.schematics.items.len + 1}) catch "untitled";
            state.newFile(name) catch |err| {
                state.setStatusErr("Failed to create new tab");
                state.log.err("CMD", "new tab failed: {}", .{err});
            };
        },
        .close_tab => {
            if (state.schematics.items.len <= 1) {
                state.setStatus("Cannot close last tab");
                return;
            }
            const alloc = state.allocator();
            const idx = state.active_idx;
            const fio = state.schematics.items[idx];
            // Save origin path to closed_tabs before destroying
            const origin_path: ?[]const u8 = switch (fio.origin) {
                .chn_file => |p| p,
                .sym_file => |p| p,
                else => null,
            };
            if (origin_path) |p| {
                const duped = alloc.dupe(u8, p) catch null;
                if (duped) |d| {
                    state.closed_tabs.append(alloc, d) catch alloc.free(d);
                }
            }
            fio.deinit();
            alloc.destroy(fio);
            _ = state.schematics.orderedRemove(idx);
            if (state.active_idx >= state.schematics.items.len) {
                state.active_idx = state.schematics.items.len - 1;
            }
            state.selection.clear();
            state.setStatus("Tab closed");
        },
        .next_tab => {
            if (state.schematics.items.len > 0) {
                state.active_idx = (state.active_idx + 1) % state.schematics.items.len;
                state.setStatus("Next tab");
            }
        },
        .prev_tab => {
            if (state.schematics.items.len > 0) {
                state.active_idx = if (state.active_idx == 0)
                    state.schematics.items.len - 1
                else
                    state.active_idx - 1;
                state.setStatus("Previous tab");
            }
        },
        .reopen_last_closed => {
            const path = state.closed_tabs.pop() orelse {
                state.setStatus("No recently closed tabs");
                return;
            };
            defer state.allocator().free(path);
            state.openPath(path) catch |err| {
                state.setStatusErr("Failed to reopen tab");
                state.log.err("CMD", "reopen_last_closed failed: {}", .{err});
            };
        },

        // ── File operations ───────────────────────────────────────────────
        .save_as_dialog => state.setStatus("Save as (use :saveas <path>)"),
        .save_as_symbol_dialog => state.setStatus("Save as symbol (stub)"),
        .reload_from_disk => {
            const fio = state.active() orelse return;
            const reload_path: ?[]const u8 = switch (fio.origin) {
                .chn_file => |p| p,
                .sym_file => |p| p,
                .xschem_files => |xf| xf.sch,
                .buffer, .unsaved => null,
            };
            if (reload_path) |p| {
                state.openPath(p) catch |err| {
                    state.setStatusErr("Reload failed");
                    state.log.err("CMD", "reload failed: {}", .{err});
                };
            } else {
                state.setStatus("No disk path to reload from");
            }
        },
        .clear_schematic => {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            sch.wires.clearRetainingCapacity();
            sch.instances.clearRetainingCapacity();
            state.selection.clear();
            fio.dirty = true;
            state.setStatus("Schematic cleared");
        },
        .merge_file_dialog => state.setStatus("Merge file (stub — use :merge <path>)"),

        // ── Snap ──────────────────────────────────────────────────────────
        .snap_halve => {
            state.tool.snap_size = @max(1.0, state.tool.snap_size / 2.0);
            state.setStatus("Snap halved");
        },
        .snap_double => {
            state.tool.snap_size = @min(100.0, state.tool.snap_size * 2.0);
            state.setStatus("Snap doubled");
        },

        // ── Export ────────────────────────────────────────────────────────
        .export_pdf => state.setStatus("Export (stub — inkscape/imagemagick not found)"),
        .export_png => state.setStatus("Export (stub — inkscape/imagemagick not found)"),
        .export_svg => {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            var buf: std.ArrayListUnmanaged(u8) = .{};
            defer buf.deinit(state.allocator());
            const w = buf.writer(state.allocator());
            try w.writeAll("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"-500 -500 1000 1000\">\n");
            for (sch.wires.items) |wire| {
                try w.print("  <line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"#4488ff\" stroke-width=\"2\"/>\n",
                    .{ wire.start.x, wire.start.y, wire.end.x, wire.end.y });
            }
            for (sch.instances.items) |inst| {
                try w.print("  <rect x=\"{d}\" y=\"{d}\" width=\"20\" height=\"20\" fill=\"none\" stroke=\"#88ccff\"/>\n",
                    .{ inst.pos.x - 10, inst.pos.y - 10 });
                try w.print("  <text x=\"{d}\" y=\"{d}\" font-size=\"8\" fill=\"#ffffff\">{s}</text>\n",
                    .{ inst.pos.x - 8, inst.pos.y - 14, inst.name });
            }
            try w.writeAll("</svg>\n");
            const path = try std.fmt.allocPrint(state.allocator(), "{s}.svg", .{fio.comp.name});
            defer state.allocator().free(path);
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = buf.items });
            state.setStatus("Exported SVG");
        },
        .screenshot_area => state.setStatus("Export (stub — inkscape/imagemagick not found)"),

        // ── Simulation extras ─────────────────────────────────────────────
        .open_waveform_viewer => {
            const fio = state.active() orelse {
                state.setStatus("No .raw file found — run simulation first");
                return;
            };
            // Derive .raw path from the active document's origin path
            const raw_path: ?[]const u8 = switch (fio.origin) {
                .chn_file => |p| blk: {
                    // Replace .chn or .chn_tb extension with .raw
                    if (std.mem.endsWith(u8, p, ".chn_tb")) {
                        break :blk try std.fmt.allocPrint(state.allocator(), "{s}.raw", .{p[0 .. p.len - 7]});
                    } else if (std.mem.endsWith(u8, p, ".chn")) {
                        break :blk try std.fmt.allocPrint(state.allocator(), "{s}.raw", .{p[0 .. p.len - 4]});
                    }
                    break :blk null;
                },
                else => null,
            };
            defer if (raw_path) |rp| state.allocator().free(rp);

            if (raw_path == null) {
                state.setStatus("No .raw file found — run simulation first");
                return;
            }

            const rp = raw_path.?;
            const raw_file = std.fs.cwd().openFile(rp, .{}) catch {
                state.setStatus("No .raw file found — run simulation first");
                return;
            };
            defer raw_file.close();

            // Parse ASCII ngspice raw: look for "Values:" section then read floats
            var reader = raw_file.reader();
            var line_buf: [1024]u8 = undefined;
            var in_values = false;
            state.waveform_len = 0;

            outer: while (true) {
                const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch break;
                const l = line orelse break;
                const trimmed = std.mem.trim(u8, l, " \t\r");
                if (!in_values) {
                    if (std.mem.startsWith(u8, trimmed, "Values:")) {
                        in_values = true;
                    }
                    continue;
                }
                // Parse whitespace-separated floats on this line
                var it = std.mem.tokenizeAny(u8, trimmed, " \t");
                while (it.next()) |tok| {
                    if (state.waveform_len >= 4096) break :outer;
                    const val = std.fmt.parseFloat(f32, tok) catch continue;
                    state.waveform_data[state.waveform_len] = val;
                    state.waveform_len += 1;
                }
            }

            // Set label from component name
            const label = fio.comp.name;
            const copy_len = @min(label.len, 63);
            @memcpy(state.waveform_label[0..copy_len], label[0..copy_len]);
            state.waveform_label_len = copy_len;

            state.gui.view_mode = .waveform;
            state.setStatus("Waveform viewer opened");
        },

        // ── Misc ──────────────────────────────────────────────────────────
        .show_keybinds => state.setStatus("Keybinds: see documentation or use :help"),
        .pan_interactive => {
            state.tool.active = .pan;
            state.setStatus("Pan mode (stub)");
        },
        .escape_mode => {
            state.tool.wire_start = null;
            state.tool.active = .select;
            state.selection.clear();
            state.setStatus("Ready");
        },
        .show_context_menu => state.setStatus("Context menu (stub)"),

        // ── Schematic mutations with payloads ─────────────────────────────
        .place_device => |p| {
            const fio = state.active() orelse return;
            _ = try fio.placeSymbol(p.sym_path, p.name, pointFromF64(p.x, p.y), .{});
        },
        .delete_device => |p| {
            const fio = state.active() orelse return;
            _ = fio.deleteInstanceAt(p.idx);
        },
        .move_device => |p| {
            const fio = state.active() orelse return;
            _ = fio.moveInstanceBy(
                p.idx,
                @as(i32, @intFromFloat(@round(p.dx))),
                @as(i32, @intFromFloat(@round(p.dy))),
            );
        },
        .set_prop => |p| {
            const fio = state.active() orelse return;
            try fio.setProp(p.idx, p.key, p.val);
        },
        .add_wire => |p| {
            const fio = state.active() orelse return;
            try fio.addWireSeg(pointFromF64(p.x0, p.y0), pointFromF64(p.x1, p.y1), null);
        },
        .delete_wire => |p| {
            const fio = state.active() orelse return;
            _ = fio.deleteWireAt(p.idx);
        },
        .load_schematic => |p| try state.openPath(p.path),
        .save_schematic => |p| try state.saveActiveTo(p.path),
        .run_sim => |p| {
            const fio = state.active() orelse return;
            const path = fio.createNetlist(p.sim) catch {
                state.setStatusErr("Netlist generation failed");
                return;
            };
            defer state.allocator().free(path);
            fio.runSpiceSim(p.sim, path);
            state.setStatus("Simulation started");
        },
    }

    // Only record data-mutating commands in history
    switch (c) {
        .zoom_in, .zoom_out, .zoom_fit, .zoom_reset, .zoom_fit_selected,
        .toggle_fullscreen, .toggle_colorscheme, .toggle_fill_rects,
        .toggle_text_in_symbols, .toggle_symbol_details, .show_all_layers,
        .show_only_current_layer, .increase_line_width, .decrease_line_width,
        .toggle_crosshair, .toggle_show_netlist,
        .select_all, .select_none, .select_connected, .select_connected_stop_junctions,
        .highlight_dup_refdes, .rename_dup_refdes, .find_select_dialog,
        .highlight_selected_nets, .unhighlight_selected_nets, .unhighlight_all,
        .select_attached_nets,
        .undo, .redo, .plugins_refresh, .plugin_command,
        .load_schematic, .save_schematic, .run_sim,
        .move_interactive, .move_interactive_stretch, .move_interactive_insert,
        .copy_selected, .clipboard_cut, .clipboard_copy, .clipboard_paste,
        .start_wire, .start_wire_snap, .cancel_wire, .finish_wire,
        .toggle_wire_routing, .toggle_orthogonal_routing,
        .descend_schematic, .descend_symbol, .ascend, .edit_in_new_tab,
        .edit_properties, .view_properties, .edit_schematic_metadata,
        .netlist_hierarchical, .netlist_flat, .netlist_top_only, .toggle_flat_netlist,
        .make_symbol_from_schematic, .make_schematic_from_symbol, .make_schem_and_sym,
        .insert_from_library,
        .new_tab, .close_tab, .next_tab, .prev_tab, .reopen_last_closed,
        .save_as_dialog, .save_as_symbol_dialog, .reload_from_disk, .merge_file_dialog,
        .snap_halve, .snap_double,
        .export_pdf, .export_png, .export_svg, .screenshot_area,
        .open_waveform_viewer,
        .show_keybinds, .pan_interactive, .escape_mode, .show_context_menu,
        => {},
        else => try state.history.push(c, state.allocator()),
    }
}

/// Build a core.Schemify from the active CT.Schematic, generate SPICE, write to disk,
/// and store the result in state.last_netlist.
fn generateNetlistAndStore(state: *AppState, alloc: std.mem.Allocator, status_prefix: []const u8) !void {
    const fio = state.active() orelse return error.NoActiveDocument;
    const sch_ct = fio.schematic();

    var s = core.Schemify.init(alloc);
    defer s.deinit();
    s.name = sch_ct.name;

    for (sch_ct.instances.items) |inst| {
        const prop_start: u32 = @intCast(s.props.items.len);
        for (inst.props.items) |p| {
            s.props.append(s.alloc(), .{
                .key = s.alloc().dupe(u8, p.key) catch p.key,
                .val = s.alloc().dupe(u8, p.val) catch p.val,
            }) catch {};
        }
        s.instances.append(s.alloc(), .{
            .name       = s.alloc().dupe(u8, inst.name) catch inst.name,
            .symbol     = s.alloc().dupe(u8, inst.symbol) catch inst.symbol,
            .x          = inst.pos.x,
            .y          = inst.pos.y,
            .rot        = inst.xform.rot,
            .flip       = inst.xform.flip,
            .kind       = .unknown,
            .prop_start = prop_start,
            .prop_count = @intCast(s.props.items.len - prop_start),
            .conn_start = 0,
            .conn_count = 0,
        }) catch {};
    }

    // Copy wires
    for (sch_ct.wires.items) |wire| {
        s.wires.append(s.alloc(), .{
            .x0       = wire.start.x,
            .y0       = wire.start.y,
            .x1       = wire.end.x,
            .y1       = wire.end.y,
            .net_name = if (wire.net_name) |n| s.alloc().dupe(u8, n) catch null else null,
        }) catch {};
    }

    // Build UniversalNetlistForm and generate SPICE
    var unf = try core.netlist.UniversalNetlistForm.fromSchemify(alloc, &s);
    defer unf.deinit();

    const spice = try unf.generateSpice(alloc, core.pdk_registry);
    defer alloc.free(spice);

    // Write to <project_dir>/<name>.sp
    var sp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sp_path = std.fmt.bufPrint(&sp_path_buf, "{s}/{s}.sp", .{ state.project_dir, sch_ct.name }) catch sch_ct.name;
    std.fs.cwd().writeFile(.{ .sub_path = sp_path, .data = spice }) catch |err| {
        state.log.err("CMD", "failed to write netlist to {s}: {}", .{ sp_path, err });
    };

    // Store in state.last_netlist (truncated to 8192)
    const copy_len = @min(spice.len, state.last_netlist.len);
    @memcpy(state.last_netlist[0..copy_len], spice[0..copy_len]);
    state.last_netlist_len = copy_len;

    // Set status — use module-level static buffer (GUI is single-threaded)
    const status = std.fmt.bufPrint(&netlist_status_buf, "{s}{s}.sp", .{ status_prefix, sch_ct.name }) catch "Netlist written";
    state.setStatus(status);
}

fn firstSelectedInstance(state: *AppState) ?usize {
    var it = state.selection.instances.iterator(.{});
    return it.next();
}

fn pointFromF64(x: f64, y: f64) CT.Point {
    return .{
        .x = @as(i32, @intFromFloat(@round(x))),
        .y = @as(i32, @intFromFloat(@round(y))),
    };
}

fn rotateSelected(fio: *state_mod.FileIO, state: *AppState, delta: u2) void {
    const sch = fio.schematic();
    var changed = false;
    for (sch.instances.items, 0..) |*inst, i| {
        if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i)) {
            inst.xform.rot = (inst.xform.rot + delta) & 0b11;
            changed = true;
        }
    }
    if (changed) fio.dirty = true;
}

fn flipSelected(fio: *state_mod.FileIO, state: *AppState) void {
    const sch = fio.schematic();
    var changed = false;
    for (sch.instances.items, 0..) |*inst, i| {
        if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i)) {
            inst.xform.flip = !inst.xform.flip;
            changed = true;
        }
    }
    if (changed) fio.dirty = true;
}

fn nudgeSelected(fio: *state_mod.FileIO, state: *AppState, dx: i32, dy: i32) void {
    const sch = fio.schematic();
    var changed = false;
    for (sch.instances.items, 0..) |*inst, i| {
        if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i)) {
            inst.pos.x += dx;
            inst.pos.y += dy;
            changed = true;
        }
    }
    if (changed) fio.dirty = true;
}

fn duplicateSelected(fio: *state_mod.FileIO, state: *AppState) void {
    const sch = fio.schematic();
    const sa = sch.alloc();
    const base_len = sch.instances.items.len;

    for (0..base_len) |i| {
        if (i >= state.selection.instances.bit_length or !state.selection.instances.isSet(i)) continue;
        var copy = sch.instances.items[i];
        copy.pos.x += 20;
        copy.pos.y += 20;
        sch.instances.append(sa, copy) catch continue;
    }
    fio.dirty = true;
}

// ── Undo/redo history ─────────────────────────────────────────────────────────

/// Linear history.  Execute the command first, then push it.
/// Any new push clears the redo stack.
pub const History = struct {
    done: std.ArrayListUnmanaged(Command) = .{},
    undone: std.ArrayListUnmanaged(Command) = .{},

    pub fn push(self: *History, cmd: Command, alloc: std.mem.Allocator) !void {
        self.undone.clearRetainingCapacity();
        try self.done.append(alloc, cmd);
    }

    /// Pop the last executed command (caller must reverse its effect).
    pub fn undo(self: *History, alloc: std.mem.Allocator) !?Command {
        const cmd = self.done.pop() orelse return null;
        try self.undone.append(alloc, cmd);
        return cmd;
    }

    /// Re-apply the most recently undone command.
    pub fn redo(self: *History, alloc: std.mem.Allocator) !?Command {
        const cmd = self.undone.pop() orelse return null;
        try self.done.append(alloc, cmd);
        return cmd;
    }

    pub fn deinit(self: *History, alloc: std.mem.Allocator) void {
        self.done.deinit(alloc);
        self.undone.deinit(alloc);
    }
};