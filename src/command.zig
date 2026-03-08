//! Command system — every schematic mutation is expressed as a Command.
//! The History stack drives undo/redo; plugins can also inject Commands.
//! The CommandQueue is a fixed-capacity ring buffer drained once per frame.

const std = @import("std");
const state_mod = @import("state.zig");
const CT = state_mod.CT;
const core = @import("core");
const dvui = @import("dvui");

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
        .zoom_fit => zoomFitAll(state),
        .zoom_reset => state.view.zoomReset(),
        .zoom_fit_selected => zoomFitSelection(state),
        .toggle_fullscreen => {
            state.cmd_flags.fullscreen = !state.cmd_flags.fullscreen;
            // dvui does not expose a runtime fullscreen toggle; the flag is
            // only honoured at window-creation time.  We record the intent
            // so the GUI layer can act on it if a backend escape-hatch
            // becomes available.
            state.setStatus(if (state.cmd_flags.fullscreen) "Fullscreen on (no runtime API)" else "Fullscreen off");
        },
        .toggle_colorscheme => {
            state.cmd_flags.dark_mode = !state.cmd_flags.dark_mode;
            const theme = if (state.cmd_flags.dark_mode)
                dvui.Theme.builtin.adwaita_dark
            else
                dvui.Theme.builtin.adwaita_light;
            dvui.themeSet(theme);
            state.setStatus(if (state.cmd_flags.dark_mode) "Dark mode on" else "Dark mode off");
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
            state.setStatus(if (state.cmd_flags.show_netlist) "Netlist view on (stub)" else "Netlist view off (stub)");
        },

        // ── Selection ─────────────────────────────────────────────────────
        .select_all => state.selectAll(),
        .select_none => state.selection.clear(),
        .select_connected => selectConnected(state, false),
        .select_connected_stop_junctions => selectConnected(state, true),
        .highlight_dup_refdes => highlightDupRefdes(state),
        .rename_dup_refdes => try renameDupRefdes(state),
        .find_select_dialog => {
            // TODO Phase 9B: find_dialog_open moved to gui/find_dialog.zig State
            state.setStatus("Find: type query then Enter");
        },
        .highlight_selected_nets => highlightSelectedNets(state),
        .unhighlight_selected_nets => unhighlightSelectedNets(state),
        .unhighlight_all => state.highlighted_nets.unsetAll(),
        .select_attached_nets => selectAttachedNets(state),

        // ── Undo / Redo ───────────────────────────────────────────────────
        .undo => {
            const inv = state.history.popUndo() orelse {
                state.setStatus("Nothing to undo");
                return;
            };
            switch (inv) {
                .none => {},
                .place_device => |pd| {
                    const fio = state.active() orelse return;
                    _ = fio.deleteInstanceAt(pd.idx);
                },
                .delete_device => |dd| {
                    const fio = state.active() orelse return;
                    _ = try fio.placeSymbol(dd.sym_path, dd.name, pointFromF64(dd.x, dd.y), .{});
                },
                .move_device => |md| {
                    const fio = state.active() orelse return;
                    _ = fio.moveInstanceBy(
                        md.idx,
                        @as(i32, @intFromFloat(@round(md.dx))),
                        @as(i32, @intFromFloat(@round(md.dy))),
                    );
                },
                .set_prop => |sp| {
                    const fio = state.active() orelse return;
                    try fio.setProp(sp.idx, sp.key, sp.val);
                },
                .add_wire => |aw| {
                    const fio = state.active() orelse return;
                    _ = fio.deleteWireAt(aw.idx);
                },
                .delete_wire => |dw| {
                    const fio = state.active() orelse return;
                    try fio.addWireSeg(pointFromF64(dw.x0, dw.y0), pointFromF64(dw.x1, dw.y1), null);
                },
                .delete_selected => |snap| {
                    const fio = state.active() orelse return;
                    const sch = fio.schematic();
                    for (snap.instances) |inst| sch.instances.append(sch.alloc(), inst) catch {};
                    for (snap.wires)     |wire| sch.wires.append(sch.alloc(), wire)     catch {};
                    fio.dirty = true;
                    state.setStatus("Undo: restored deleted objects");
                },
                .duplicate_selected => |d| {
                    const fio = state.active() orelse return;
                    const sch = fio.schematic();
                    const n = @min(d.n, sch.instances.items.len);
                    sch.instances.items.len -= n;
                    fio.dirty = true;
                    state.setStatus("Undo: removed duplicated objects");
                },
            }
            return;
        },
        .redo => {
            state.setStatus("Redo not yet implemented");
            return;
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
        .copy_selected => try dispatch(.clipboard_copy, state),
        .clipboard_copy => {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            const alloc = state.allocator();
            state.clipboard.clear(alloc);
            for (sch.instances.items, 0..) |inst, i| {
                if (i >= state.selection.instances.bit_length or !state.selection.instances.isSet(i)) continue;
                var copy = inst;
                copy.name = alloc.dupe(u8, inst.name) catch inst.name;
                copy.symbol = alloc.dupe(u8, inst.symbol) catch inst.symbol;
                copy.props = .{};
                state.clipboard.instances.append(alloc, copy) catch {};
            }
            for (sch.wires.items, 0..) |wire, i| {
                if (i >= state.selection.wires.bit_length or !state.selection.wires.isSet(i)) continue;
                var copy = wire;
                copy.net_name = if (wire.net_name) |n| alloc.dupe(u8, n) catch n else null;
                state.clipboard.wires.append(alloc, copy) catch {};
            }
            state.setStatus("Copied to clipboard");
        },
        .clipboard_cut => {
            try dispatch(.clipboard_copy, state);
            try dispatch(.delete_selected, state);
            state.setStatus("Cut to clipboard");
        },
        .clipboard_paste => {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            const sa = sch.alloc();
            const alloc = state.allocator();
            state.selection.clear();
            const offset: i32 = 20;
            for (state.clipboard.instances.items) |inst| {
                var copy = inst;
                copy.pos.x += offset;
                copy.pos.y += offset;
                copy.name = sa.dupe(u8, inst.name) catch inst.name;
                copy.symbol = sa.dupe(u8, inst.symbol) catch inst.symbol;
                copy.props = .{};
                sch.instances.append(sa, copy) catch continue;
                const idx = sch.instances.items.len - 1;
                state.selection.instances.resize(alloc, idx + 1, false) catch {};
                if (idx < state.selection.instances.bit_length) state.selection.instances.set(idx);
            }
            for (state.clipboard.wires.items) |wire| {
                var copy = wire;
                copy.start.x += offset;
                copy.start.y += offset;
                copy.end.x += offset;
                copy.end.y += offset;
                copy.net_name = if (wire.net_name) |n| sa.dupe(u8, n) catch n else null;
                sch.wires.append(sa, copy) catch continue;
                const idx = sch.wires.items.len - 1;
                state.selection.wires.resize(alloc, idx + 1, false) catch {};
                if (idx < state.selection.wires.bit_length) state.selection.wires.set(idx);
            }
            fio.dirty = true;
            state.setStatus("Pasted from clipboard");
        },
        .align_to_grid => {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            const snap = state.tool.snap_size;
            var changed = false;
            for (sch.instances.items, 0..) |*inst, i| {
                if (i >= state.selection.instances.bit_length or !state.selection.instances.isSet(i)) continue;
                inst.pos.x = @intFromFloat(@round(@as(f32, @floatFromInt(inst.pos.x)) / snap) * snap);
                inst.pos.y = @intFromFloat(@round(@as(f32, @floatFromInt(inst.pos.y)) / snap) * snap);
                changed = true;
            }
            if (changed) {
                fio.dirty = true;
                state.setStatus("Aligned to grid");
            } else {
                state.setStatus("Nothing selected to align");
            }
        },

        // ── Transform (operate on selection) ──────────────────────────────
        .delete_selected => {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            const snap_alloc = state.allocator();

            // Snapshot for undo
            var sel_inst_count: usize = 0;
            for (0..sch.instances.items.len) |i| {
                if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i))
                    sel_inst_count += 1;
            }
            var sel_wire_count: usize = 0;
            for (0..sch.wires.items.len) |i| {
                if (i < state.selection.wires.bit_length and state.selection.wires.isSet(i))
                    sel_wire_count += 1;
            }
            const snap_inst: []CT.Instance = snap_alloc.alloc(CT.Instance, sel_inst_count) catch
                snap_alloc.alloc(CT.Instance, 0) catch unreachable;
            const snap_wire: []CT.Wire = snap_alloc.alloc(CT.Wire, sel_wire_count) catch
                snap_alloc.alloc(CT.Wire, 0) catch unreachable;
            var si: usize = 0;
            for (sch.instances.items, 0..) |inst, i| {
                if (i < state.selection.instances.bit_length and state.selection.instances.isSet(i)) {
                    if (si < snap_inst.len) { snap_inst[si] = inst; si += 1; }
                }
            }
            var sw: usize = 0;
            for (sch.wires.items, 0..) |wire, i| {
                if (i < state.selection.wires.bit_length and state.selection.wires.isSet(i)) {
                    if (sw < snap_wire.len) { snap_wire[sw] = wire; sw += 1; }
                }
            }

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
            state.history.push(c, .{ .delete_selected = .{ .instances = snap_inst, .wires = snap_wire } });
            return;
        },
        .duplicate_selected => {
            const fio = state.active() orelse return;
            const before_len = fio.schematic().instances.items.len;
            duplicateSelected(fio, state);
            const after_len = fio.schematic().instances.items.len;
            state.history.push(c, .{ .duplicate_selected = .{ .n = after_len - before_len } });
            return;
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
        .break_wires_at_connections => try breakWiresAtConnections(state),
        .join_collapse_wires => try joinCollapseWires(state),

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
        .descend_schematic => state.setStatus("Descend into schematic (stub)"),
        .descend_symbol => state.setStatus("Descend into symbol (stub)"),
        .ascend => state.setStatus("Ascend to parent (stub)"),
        .edit_in_new_tab => state.setStatus("Edit in new tab (stub)"),

        // ── Properties ────────────────────────────────────────────────────
        .edit_properties => {
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
            // TODO Phase 9B: props dialog state moved to gui/props_dialog.zig State
            _ = inst;
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
            // TODO Phase 9B: props dialog state moved to gui/props_dialog.zig State
            _ = idx;
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
            // TODO Phase 9B: lib browser state moved to gui/lib_browser.zig State
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
        .reopen_last_closed => state.setStatus("Reopen last closed (stub)"),

        // ── File operations ───────────────────────────────────────────────
        .save_as_dialog => state.setStatus("Save as (use :saveas <path>)"),
        .save_as_symbol_dialog => state.setStatus("Save as symbol (stub)"),
        .reload_from_disk => {
            const fio = state.active() orelse return;
            const reload_path: ?[]const u8 = switch (fio.origin) {
                .chn_file, .chn_sym_file => |p| p,
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
        .export_pdf => state.setStatus("Export PDF (stub)"),
        .export_png => state.setStatus("Export PNG (stub)"),
        .export_svg => state.setStatus("Export SVG (stub)"),
        .screenshot_area => state.setStatus("Screenshot (stub)"),

        // ── Simulation extras ─────────────────────────────────────────────
        .open_waveform_viewer => state.setStatus("Open waveform viewer (stub)"),

        // ── Misc ──────────────────────────────────────────────────────────
        .show_keybinds => {
            // TODO Phase 9B: keybinds_open moved to gui/keybinds_dialog.zig State
            state.setStatus("Keybinds window opened");
        },
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
            const new_idx = try fio.placeSymbol(p.sym_path, p.name, pointFromF64(p.x, p.y), .{});
            state.history.push(c, .{ .place_device = .{ .idx = @intCast(new_idx) } });
            return;
        },
        .delete_device => |p| {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            if (p.idx >= sch.instances.items.len) return;
            const inst = sch.instances.items[p.idx];
            const inv: CommandInverse = .{ .delete_device = .{
                .sym_path = inst.symbol,
                .name = inst.name,
                .x = @floatFromInt(inst.pos.x),
                .y = @floatFromInt(inst.pos.y),
            } };
            _ = fio.deleteInstanceAt(p.idx);
            state.history.push(c, inv);
            return;
        },
        .move_device => |p| {
            const fio = state.active() orelse return;
            _ = fio.moveInstanceBy(
                p.idx,
                @as(i32, @intFromFloat(@round(p.dx))),
                @as(i32, @intFromFloat(@round(p.dy))),
            );
            state.history.push(c, .{ .move_device = .{ .idx = p.idx, .dx = -p.dx, .dy = -p.dy } });
            return;
        },
        .set_prop => |p| {
            const fio = state.active() orelse return;
            try fio.setProp(p.idx, p.key, p.val);
            state.history.push(c, .none);
            return;
        },
        .add_wire => |p| {
            const fio = state.active() orelse return;
            try fio.addWireSeg(pointFromF64(p.x0, p.y0), pointFromF64(p.x1, p.y1), null);
            const new_wire_idx = fio.schematic().wires.items.len - 1;
            state.history.push(c, .{ .add_wire = .{ .idx = new_wire_idx } });
            return;
        },
        .delete_wire => |p| {
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            if (p.idx >= sch.wires.items.len) return;
            const wire = sch.wires.items[p.idx];
            const inv: CommandInverse = .{ .delete_wire = .{
                .x0 = @floatFromInt(wire.start.x),
                .y0 = @floatFromInt(wire.start.y),
                .x1 = @floatFromInt(wire.end.x),
                .y1 = @floatFromInt(wire.end.y),
            } };
            _ = fio.deleteWireAt(p.idx);
            state.history.push(c, inv);
            return;
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

}

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
            .name       = s.alloc().dupe(u8, inst.name)   catch inst.name,
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
    for (sch_ct.wires.items) |wire| {
        s.wires.append(s.alloc(), .{
            .x0       = wire.start.x,
            .y0       = wire.start.y,
            .x1       = wire.end.x,
            .y1       = wire.end.y,
            .net_name = if (wire.net_name) |n| s.alloc().dupe(u8, n) catch null else null,
        }) catch {};
    }

    var unf = try core.netlist.UniversalNetlistForm.fromSchemify(alloc, &s);
    defer unf.deinit();
    const spice = try unf.generateSpice(alloc, core.pdk_registry);
    defer alloc.free(spice);

    var sp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sp_path = std.fmt.bufPrint(&sp_path_buf, "{s}/{s}.sp", .{ state.project_dir, sch_ct.name }) catch sch_ct.name;
    std.fs.cwd().writeFile(.{ .sub_path = sp_path, .data = spice }) catch |err| {
        state.log.err("CMD", "failed to write netlist to {s}: {}", .{ sp_path, err });
    };

    const copy_len = @min(spice.len, state.last_netlist.len);
    @memcpy(state.last_netlist[0..copy_len], spice[0..copy_len]);
    state.last_netlist_len = copy_len;

    const status = std.fmt.bufPrint(&netlist_status_buf, "{s}{s}.sp", .{ status_prefix, sch_ct.name }) catch "Netlist written";
    state.setStatus(status);
}

// ── (removed catch-all history push — each mutation pushes inline) ──────────

fn _unused_history_dispatch(c: Command, state: *AppState) void {
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
        else => {},
    }
    _ = state;
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

// ── Phase 5B: Zoom fit ────────────────────────────────────────────────────────

fn schematicBBox(fio: *state_mod.FileIO) ?struct { x0: f32, y0: f32, x1: f32, y1: f32 } {
    const sch = fio.schematic();
    if (sch.instances.items.len == 0 and sch.wires.items.len == 0) return null;
    var x0: f32 = std.math.floatMax(f32);
    var y0: f32 = std.math.floatMax(f32);
    var x1: f32 = -std.math.floatMax(f32);
    var y1: f32 = -std.math.floatMax(f32);
    for (sch.instances.items) |inst| {
        const fx: f32 = @floatFromInt(inst.pos.x);
        const fy: f32 = @floatFromInt(inst.pos.y);
        if (fx < x0) x0 = fx;
        if (fy < y0) y0 = fy;
        if (fx > x1) x1 = fx;
        if (fy > y1) y1 = fy;
    }
    for (sch.wires.items) |wire| {
        const ax: f32 = @floatFromInt(wire.start.x);
        const ay: f32 = @floatFromInt(wire.start.y);
        const bx: f32 = @floatFromInt(wire.end.x);
        const by: f32 = @floatFromInt(wire.end.y);
        if (ax < x0) x0 = ax; if (bx < x0) x0 = bx;
        if (ay < y0) y0 = ay; if (by < y0) y0 = by;
        if (ax > x1) x1 = ax; if (bx > x1) x1 = bx;
        if (ay > y1) y1 = ay; if (by > y1) y1 = by;
    }
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn applyZoomFit(state: *AppState, x0: f32, y0: f32, x1: f32, y1: f32) void {
    const world_w = x1 - x0 + 1.0;
    const world_h = y1 - y0 + 1.0;
    const fit_zoom = @min(state.canvas_w / world_w, state.canvas_h / world_h) * 0.9;
    state.view.zoom = @max(0.01, @min(50.0, fit_zoom));
    state.view.pan = .{ (x0 + x1) / 2.0, (y0 + y1) / 2.0 };
}

fn zoomFitAll(state: *AppState) void {
    const fio = state.active() orelse { state.view.zoomReset(); return; };
    const bb = schematicBBox(fio) orelse { state.view.zoomReset(); return; };
    applyZoomFit(state, bb.x0, bb.y0, bb.x1, bb.y1);
}

fn zoomFitSelection(state: *AppState) void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    if (state.selection.isEmpty()) { zoomFitAll(state); return; }
    var x0: f32 = std.math.floatMax(f32);
    var y0: f32 = std.math.floatMax(f32);
    var x1: f32 = -std.math.floatMax(f32);
    var y1: f32 = -std.math.floatMax(f32);
    var found = false;
    for (sch.instances.items, 0..) |inst, i| {
        if (i >= state.selection.instances.bit_length or !state.selection.instances.isSet(i)) continue;
        const fx: f32 = @floatFromInt(inst.pos.x);
        const fy: f32 = @floatFromInt(inst.pos.y);
        if (fx < x0) x0 = fx; if (fy < y0) y0 = fy;
        if (fx > x1) x1 = fx; if (fy > y1) y1 = fy;
        found = true;
    }
    for (sch.wires.items, 0..) |wire, i| {
        if (i >= state.selection.wires.bit_length or !state.selection.wires.isSet(i)) continue;
        const ax: f32 = @floatFromInt(wire.start.x); const ay: f32 = @floatFromInt(wire.start.y);
        const bx: f32 = @floatFromInt(wire.end.x);   const by: f32 = @floatFromInt(wire.end.y);
        if (ax < x0) x0 = ax; if (bx < x0) x0 = bx;
        if (ay < y0) y0 = ay; if (by < y0) y0 = by;
        if (ax > x1) x1 = ax; if (bx > x1) x1 = bx;
        if (ay > y1) y1 = ay; if (by > y1) y1 = by;
        found = true;
    }
    if (found) applyZoomFit(state, x0, y0, x1, y1);
}

// ── Phase 6A: Selection operations ───────────────────────────────────────────

fn selectConnected(state: *AppState, stop_at_junctions: bool) void {
    _ = stop_at_junctions;
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();

    // BFS from selected wire endpoints
    var i: usize = 0;
    while (i < 8) : (i += 1) { // bounded passes to avoid infinite loop
        var added = false;
        for (sch.wires.items, 0..) |wa, a| {
            const a_sel = a < state.selection.wires.bit_length and state.selection.wires.isSet(a);
            if (!a_sel) continue;
            for (sch.wires.items, 0..) |wb, b| {
                if (a == b) continue;
                const b_sel = b < state.selection.wires.bit_length and state.selection.wires.isSet(b);
                if (b_sel) continue;
                const shares = ptEq(wa.start, wb.start) or ptEq(wa.start, wb.end) or
                    ptEq(wa.end, wb.start) or ptEq(wa.end, wb.end);
                if (shares) {
                    state.selection.wires.resize(alloc, b + 1, false) catch continue;
                    state.selection.wires.set(b);
                    added = true;
                }
            }
        }
        if (!added) break;
    }
    state.setStatus("Select connected done");
}

fn selectAttachedNets(state: *AppState) void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();
    for (sch.instances.items, 0..) |inst, ii| {
        if (ii >= state.selection.instances.bit_length or !state.selection.instances.isSet(ii)) continue;
        for (sch.wires.items, 0..) |wire, wi| {
            const touches = ptEq(wire.start, inst.pos) or ptEq(wire.end, inst.pos);
            if (touches) {
                state.selection.wires.resize(alloc, wi + 1, false) catch continue;
                state.selection.wires.set(wi);
            }
        }
    }
    state.setStatus("Attached nets selected");
}

fn highlightSelectedNets(state: *AppState) void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();
    state.highlighted_nets.resize(alloc, sch.wires.items.len, false) catch return;
    for (sch.wires.items, 0..) |_, wi| {
        if (wi < state.selection.wires.bit_length and state.selection.wires.isSet(wi)) {
            state.highlighted_nets.set(wi);
        }
    }
    state.setStatus("Nets highlighted");
}

fn unhighlightSelectedNets(state: *AppState) void {
    for (0..@min(state.selection.wires.bit_length, state.highlighted_nets.bit_length)) |wi| {
        if (state.selection.wires.isSet(wi)) {
            state.highlighted_nets.unset(wi);
        }
    }
    state.setStatus("Nets unhighlighted");
}

fn highlightDupRefdes(state: *AppState) void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();
    var map = std.StringHashMap(usize).init(alloc);
    defer map.deinit();
    for (sch.instances.items) |inst| {
        const entry = map.getOrPutValue(inst.name, 0) catch continue;
        entry.value_ptr.* += 1;
    }
    state.selection.clear();
    for (sch.instances.items, 0..) |inst, i| {
        const count = map.get(inst.name) orelse 0;
        if (count > 1) {
            state.selection.instances.resize(alloc, i + 1, false) catch continue;
            state.selection.instances.set(i);
        }
    }
    state.setStatus("Duplicate refdes highlighted");
}

fn renameDupRefdes(state: *AppState) !void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = state.allocator();
    var map = std.StringHashMap(u32).init(alloc);
    defer map.deinit();
    for (sch.instances.items, 0..) |inst, i| {
        const res = try map.getOrPut(inst.name);
        if (res.found_existing) {
            res.value_ptr.* += 1;
            const suffix = res.value_ptr.*;
            var new_name_buf: [128]u8 = undefined;
            const new_name = std.fmt.bufPrint(&new_name_buf, "{s}_{d}", .{ inst.name, suffix }) catch continue;
            try fio.setProp(i, "name", new_name);
        } else {
            res.value_ptr.* = 1;
        }
    }
    state.setStatus("Duplicate refdes renamed");
}

fn ptEq(a: CT.Point, b: CT.Point) bool {
    return a.x == b.x and a.y == b.y;
}

// ── Phase 6D: Wire geometry ───────────────────────────────────────────────────

fn breakWiresAtConnections(state: *AppState) !void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = sch.alloc();
    var i: usize = 0;
    while (i < sch.wires.items.len) {
        const w = sch.wires.items[i];
        var split_pt: ?CT.Point = null;
        // Check if any other wire's endpoint lies strictly inside this wire
        for (sch.wires.items, 0..) |other, j| {
            if (i == j) continue;
            if (pointOnSegmentStrict(other.start, w.start, w.end)) { split_pt = other.start; break; }
            if (pointOnSegmentStrict(other.end, w.start, w.end)) { split_pt = other.end; break; }
        }
        if (split_pt) |sp| {
            // Replace wire i with two wires
            const w0 = CT.Wire{ .start = w.start, .end = sp, .net_name = w.net_name };
            const w1 = CT.Wire{ .start = sp, .end = w.end, .net_name = w.net_name };
            _ = sch.wires.orderedRemove(i);
            try sch.wires.insert(alloc, i, w0);
            try sch.wires.insert(alloc, i + 1, w1);
            i += 2; // skip both new wires
        } else {
            i += 1;
        }
    }
    fio.dirty = true;
    state.setStatus("Wires broken at connections");
}

fn joinCollapseWires(state: *AppState) !void {
    const fio = state.active() orelse return;
    const sch = fio.schematic();
    const alloc = sch.alloc();
    var i: usize = 0;
    while (i < sch.wires.items.len) {
        const wa = sch.wires.items[i];
        var merged = false;
        var j: usize = i + 1;
        while (j < sch.wires.items.len) {
            const wb = sch.wires.items[j];
            // Check collinearity and shared endpoint
            if (wiresCollinear(wa, wb)) {
                var merged_wire: ?CT.Wire = null;
                if (ptEq(wa.end, wb.start)) {
                    merged_wire = .{ .start = wa.start, .end = wb.end, .net_name = wa.net_name };
                } else if (ptEq(wa.start, wb.end)) {
                    merged_wire = .{ .start = wb.start, .end = wa.end, .net_name = wa.net_name };
                } else if (ptEq(wa.start, wb.start)) {
                    merged_wire = .{ .start = wa.end, .end = wb.end, .net_name = wa.net_name };
                } else if (ptEq(wa.end, wb.end)) {
                    merged_wire = .{ .start = wa.start, .end = wb.start, .net_name = wa.net_name };
                }
                if (merged_wire) |mw| {
                    _ = sch.wires.orderedRemove(j);
                    _ = sch.wires.orderedRemove(i);
                    try sch.wires.insert(alloc, i, mw);
                    merged = true;
                    break;
                }
            }
            j += 1;
        }
        if (!merged) i += 1;
    }
    fio.dirty = true;
    state.setStatus("Wires joined");
}

fn pointOnSegmentStrict(p: CT.Point, a: CT.Point, b: CT.Point) bool {
    // p must be collinear with a-b and strictly between them (not at endpoints)
    if (ptEq(p, a) or ptEq(p, b)) return false;
    const cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
    if (cross != 0) return false;
    const min_x = @min(a.x, b.x);
    const max_x = @max(a.x, b.x);
    const min_y = @min(a.y, b.y);
    const max_y = @max(a.y, b.y);
    return p.x > min_x and p.x < max_x or p.y > min_y and p.y < max_y;
}

fn wiresCollinear(wa: CT.Wire, wb: CT.Wire) bool {
    const dx_a = wa.end.x - wa.start.x;
    const dy_a = wa.end.y - wa.start.y;
    const dx_b = wb.end.x - wb.start.x;
    const dy_b = wb.end.y - wb.start.y;
    // Same direction (or opposite): cross product of direction vectors == 0
    return dx_a * dy_b == dy_a * dx_b;
}

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