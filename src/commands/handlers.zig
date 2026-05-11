//! Unified command handlers — all immediate and undoable command logic in one file.
//! Handlers are duck-typed over `state`: any pointer whose child exposes the
//! fields/methods used (active(), setStatus(), allocator(), etc.) is accepted.
//!
//! Sections: View, Selection, Clipboard, Edit, Wire, File, Hierarchy, Netlist,
//! Simulation, Undo/Redo.

const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const types = @import("types.zig");
const Immediate = types.Immediate;
const Undoable = types.Undoable;
const Point = types.Point;

pub const Error = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    Unexpected,
    Full,
};

// ═══════════════════════════════════════════════════════════════════════════════
//  Helpers
// ═══════════════════════════════════════════════════════════════════════════════

inline fn selInst(fio: anytype, i: usize) bool {
    return i < fio.selection.instances.bit_length and fio.selection.instances.isSet(i);
}

inline fn selWire(fio: anytype, i: usize) bool {
    return i < fio.selection.wires.bit_length and fio.selection.wires.isSet(i);
}

inline fn ptEq(a: Point, b: Point) bool {
    return a[0] == b[0] and a[1] == b[1];
}

inline fn toggleFlag(state: anytype, comptime field: []const u8, comptime label: []const u8) void {
    const ptr = &@field(state.cmd_flags, field);
    ptr.* = !ptr.*;
    state.setStatus(if (ptr.*) label ++ " on" else label ++ " off");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  View
// ═══════════════════════════════════════════════════════════════════════════════

const V2 = @Vector(2, f32);

const BBox = struct {
    lo: V2,
    hi: V2,

    fn empty() BBox {
        const inf = std.math.floatMax(f32);
        return .{ .lo = @splat(inf), .hi = @splat(-inf) };
    }
    inline fn expand(self: *BBox, p: V2) void {
        self.lo = @min(self.lo, p);
        self.hi = @max(self.hi, p);
    }
    inline fn center(self: BBox) V2 { return (self.lo + self.hi) * @as(V2, @splat(0.5)); }
    inline fn size(self: BBox) V2 { return self.hi - self.lo + @as(V2, @splat(1.0)); }
};

inline fn pointToVec(p: anytype) V2 {
    return .{ @floatFromInt(p[0]), @floatFromInt(p[1]) };
}

fn zoomFitAll(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    if (sch.instances.len == 0 and sch.wires.len == 0) { fio.view.zoomReset(); return; }
    var bb = BBox.empty();
    for (0..sch.instances.len) |i| {
        const inst = sch.instances.get(i);
        bb.expand(pointToVec([2]i32{ inst.x, inst.y }));
    }
    for (0..sch.wires.len) |i| {
        const w = sch.wires.get(i);
        bb.expand(pointToVec([2]i32{ w.x0, w.y0 }));
        bb.expand(pointToVec([2]i32{ w.x1, w.y1 }));
    }
    applyZoomFit(state, bb);
}

fn applyZoomFit(state: anytype, bb: BBox) void {
    const fio = state.active() orelse return;
    const sz = bb.size();
    const canvas: V2 = .{ state.canvas_w, state.canvas_h };
    const fit_zoom = @reduce(.Min, canvas / sz) * 0.9;
    fio.view.zoom = @max(0.01, @min(50.0, fit_zoom));
    const c = bb.center();
    fio.view.pan = .{ c[0], c[1] };
}

pub fn handleView(imm: Immediate, state: anytype) void {
    switch (imm) {
        .zoom_in => { if (state.active()) |fio| fio.view.zoomIn(); },
        .zoom_out => { if (state.active()) |fio| fio.view.zoomOut(); },
        .zoom_fit => zoomFitAll(state),
        .zoom_reset => { if (state.active()) |fio| fio.view.zoomReset(); },
        .zoom_fit_selected => {
            const fio = state.active() orelse return;
            if (fio.selection.isEmpty()) { zoomFitAll(state); return; }
            const sch = &fio.sch;
            var bb = BBox.empty();
            var found = false;
            for (0..sch.instances.len) |i| {
                if (!selInst(fio, i)) continue;
                const inst = sch.instances.get(i);
                bb.expand(pointToVec([2]i32{ inst.x, inst.y }));
                found = true;
            }
            for (0..sch.wires.len) |i| {
                if (!selWire(fio, i)) continue;
                const w = sch.wires.get(i);
                bb.expand(pointToVec([2]i32{ w.x0, w.y0 }));
                bb.expand(pointToVec([2]i32{ w.x1, w.y1 }));
                found = true;
            }
            if (found) applyZoomFit(state, bb);
        },
        .toggle_fullscreen => {
            state.cmd_flags.fullscreen = !state.cmd_flags.fullscreen;
            state.setStatus(if (state.cmd_flags.fullscreen) "Fullscreen on" else "Fullscreen off");
        },
        .toggle_colorscheme => {
            state.cmd_flags.dark_mode = !state.cmd_flags.dark_mode;
            state.setStatus(if (state.cmd_flags.dark_mode) "Dark mode on" else "Dark mode off");
        },
        .toggle_fill_rects => toggleFlag(state, "fill_rects", "Fill rects"),
        .toggle_text_in_symbols => toggleFlag(state, "text_in_symbols", "Text in symbols"),
        .toggle_symbol_details => toggleFlag(state, "symbol_details", "Symbol details"),
        .toggle_crosshair => toggleFlag(state, "crosshair", "Crosshair"),
        .toggle_show_netlist => toggleFlag(state, "show_netlist", "Netlist view"),
        .toggle_grid => {
            state.show_grid = !state.show_grid;
            state.setStatus(if (state.show_grid) "Grid on" else "Grid off");
        },
        .show_all_layers => { state.cmd_flags.show_all_layers = true; state.setStatus("Showing all layers"); },
        .show_only_current_layer => { state.cmd_flags.show_all_layers = false; state.setStatus("Showing current layer only"); },
        .increase_line_width => { state.cmd_flags.line_width = @min(10, state.cmd_flags.line_width + 1); state.setStatus("Line width increased"); },
        .decrease_line_width => { state.cmd_flags.line_width = @max(1, state.cmd_flags.line_width - 1); state.setStatus("Line width decreased"); },
        .snap_halve => { state.tool.snap_size = @max(1.0, state.tool.snap_size / 2.0); state.setStatus("Snap halved"); },
        .snap_double => { state.tool.snap_size = @min(100.0, state.tool.snap_size * 2.0); state.setStatus("Snap doubled"); },
        .show_keybinds => { state.gui.cold.keybinds_open = true; state.setStatus("Keybinds"); },
        .pan_interactive => { state.tool.active = .pan; state.setStatus("Pan mode"); },
        .show_context_menu => { state.gui.cold.ctx_menu.open = true; state.setStatus("Context menu"); },
        .toggle_orthogonal_routing => toggleFlag(state, "orthogonal_routing", "Orthogonal routing"),
        .export_svg => {
            if (is_wasm) { state.setStatus("Export not available in browser"); return; }
            const fio = state.active() orelse { state.setStatus("No active document"); return; };
            const path: []const u8 = switch (fio.origin) {
                .chn_file => |p| p,
                else => { state.setStatus("Save the file first to export SVG"); return; },
            };
            var path_buf: [512]u8 = undefined;
            const stem_end = std.mem.lastIndexOf(u8, path, ".") orelse path.len;
            const svg_path = std.fmt.bufPrint(&path_buf, "{s}.svg", .{path[0..stem_end]}) catch {
                state.setStatus("Path too long for SVG export");
                return;
            };
            exportSvgFile(&fio.sch, svg_path) catch {
                state.setStatus("SVG export failed");
                return;
            };
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Exported: {s}", .{svg_path}) catch "SVG exported";
            state.setStatusBuf(msg);
        },
        .export_png => state.setStatus("PNG export not yet available (use --export-svg)"),
        .export_pdf => state.setStatus("PDF export not yet available (use --export-svg)"),
        .export_netlist => state.setStatus("Use :netlist command or --netlist CLI flag"),
        .print_schematic => state.setStatus("Print not yet available"),
        else => {},
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Selection
// ═══════════════════════════════════════════════════════════════════════════════

pub fn handleToolSwitch(imm: Immediate, state: anytype) void {
    // Duck-typed: state.tool.active is a Tool enum, state.setStatus() exists.
    switch (imm) {
        .tool_select => { state.tool.active = .select; state.setStatus("Select"); },
        .tool_move => { state.tool.active = .move; state.setStatus("Move"); },
        .tool_pan => { state.tool.active = .pan; state.setStatus("Pan"); },
        .tool_line => { state.tool.active = .line; state.setStatus("Line"); },
        .tool_rect => { state.tool.active = .rect; state.setStatus("Rect"); },
        .tool_polygon => { state.tool.active = .polygon; state.setStatus("Polygon"); },
        .tool_arc => { state.tool.active = .arc; state.setStatus("Arc"); },
        .tool_circle => { state.tool.active = .circle; state.setStatus("Circle"); },
        .tool_text => { state.tool.active = .text; state.setStatus("Text"); },
        else => {},
    }
}

pub fn handleDialog(imm: Immediate, state: anytype) void {
    switch (imm) {
        .open_find_dialog => { state.gui.cold.find_dialog.is_open = true; state.setStatus("Find"); },
        .open_props_dialog, .edit_properties => {
            // Count selected instances to decide single vs multi-props dialog.
            if (state.active()) |fio| {
                if (fio.selection.instances.bit_length > 0) {
                    var it = fio.selection.instances.iterator(.{});
                    var sel_count: usize = 0;
                    var first_idx: ?usize = null;
                    while (it.next()) |idx| {
                        if (idx < fio.sch.instances.len) {
                            if (first_idx == null) first_idx = idx;
                            sel_count += 1;
                        }
                    }
                    if (sel_count > 1) {
                        // Multi-selection: open batch edit dialog
                        const mpd = &state.gui.cold.multi_props_dialog;
                        mpd.populateFrom(fio.sch.instances, fio.sch.instances.len, &fio.selection.instances, fio.sch.props.items);
                        mpd.is_open = true;
                        state.setStatus("Batch edit properties");
                        return;
                    } else if (sel_count == 1) {
                        const pd = &state.gui.cold.props_dialog;
                        const idx = first_idx.?;
                        pd.inst_idx = idx;
                        pd.view_only = false;
                        pd.initialized = false;
                        pd.populateFrom(fio.sch.instances.get(idx), fio.sch.props.items);
                        pd.is_open = true;
                        state.setStatus("Properties");
                        return;
                    }
                }
            }
            // No selection: open empty single-props dialog
            state.gui.cold.props_dialog.is_open = true;
            state.setStatus("Properties");
        },
        .open_spice_code_dialog => { state.gui.cold.spice_code_dialog.is_open = true; state.setStatus("SPICE Code"); },
        .open_marketplace => { state.gui.cold.marketplace.visible = true; state.setStatus("Marketplace"); },
        .open_new_prim_dialog => { state.gui.cold.new_prim_dialog.is_open = true; state.setStatus("New Primitive"); },
        else => {},
    }
}

pub fn handleConfig(imm: Immediate, state: anytype) void {
    switch (imm) {
        .open_preferences => state.setStatus("Preferences"),
        .reload_config => {
            state.loadConfig() catch { state.setStatus("Config reload failed"); return; };
            state.setStatus("Config reloaded");
        },
        else => {},
    }
}

pub fn handleSelection(imm: Immediate, state: anytype) void {
    switch (imm) {
        .select_all => state.selectAll(),
        .select_none => { if (state.active()) |fio| fio.selection.clear(); },
        .invert_selection => {
            const fio = state.active() orelse return;
            const a = state.allocator();
            fio.selection.ensureCapacity(a, fio.sch.instances.len, fio.sch.wires.len, false) catch return;
            fio.selection.instances.toggleAll();
            fio.selection.wires.toggleAll();
            state.setStatus("Selection inverted");
        },
        .find_select_dialog => state.setStatus("Find: type query then Enter"),
        .highlight_selected_nets => {
            const fio = state.active() orelse return;
            const alloc = state.allocator();
            state.highlighted_nets.resize(alloc, fio.sch.wires.len, false) catch return;
            fio.selection.wires.resize(alloc, fio.sch.wires.len, false) catch return;
            state.highlighted_nets.setUnion(fio.selection.wires);
            state.setStatus("Nets highlighted");
        },
        .unhighlight_all => {
            state.highlighted_nets.unsetAll();
            state.setStatus("All highlights cleared");
        },
        .select_attached_nets => selectAttachedNets(state),
        else => {},
    }
}

fn selectAttachedNets(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    if (sch.instances.len == 0 or sch.wires.len == 0) return;
    const alloc = state.allocator();
    fio.selection.ensureCapacity(alloc, sch.instances.len, sch.wires.len, false) catch return;

    const ix = sch.instances.items(.x);
    const iy = sch.instances.items(.y);
    const iflags = sch.instances.items(.flags);
    const wx0 = sch.wires.items(.x0);
    const wy0 = sch.wires.items(.y0);
    const wx1 = sch.wires.items(.x1);
    const wy1 = sch.wires.items(.y1);

    var count: usize = 0;
    for (0..sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        if (i >= sch.sym_data.items.len) continue;
        const sd = sch.sym_data.items[i];
        for (sd.pins) |pin| {
            // Inline applyRotFlip logic
            const rot = iflags[i].rot;
            const flip = iflags[i].flip;
            const fpx: i32 = if (flip) -pin.x else pin.x;
            const abs_x = ix[i] + switch (rot) {
                0 => fpx, 1 => -pin.y, 2 => -fpx, 3 => pin.y,
            };
            const abs_y = iy[i] + switch (rot) {
                0 => pin.y, 1 => fpx, 2 => -pin.y, 3 => -fpx,
            };
            for (0..sch.wires.len) |wi| {
                if ((abs_x == wx0[wi] and abs_y == wy0[wi]) or
                    (abs_x == wx1[wi] and abs_y == wy1[wi]))
                {
                    fio.selection.wires.set(wi);
                    count += 1;
                }
            }
        }
    }
    if (count > 0) {
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Selected {d} attached net(s)", .{count}) catch "Nets selected";
        state.setStatusBuf(msg);
    } else {
        state.setStatus("No attached nets found");
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Clipboard
// ═══════════════════════════════════════════════════════════════════════════════

pub fn handleClipboard(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .clipboard_copy => copyToClipboard(state),
        .clipboard_cut => {
            copyToClipboard(state);
            try handleEdit(.delete_selected, state);
            state.setStatus("Cut to clipboard");
        },
        .clipboard_paste => pasteFromClipboard(state),
        else => {},
    }
}

fn copyToClipboard(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const alloc = state.allocator();
    state.clipboard.clear();
    for (0..sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        var copy = sch.instances.get(i);
        copy.name = alloc.dupe(u8, copy.name) catch copy.name;
        copy.symbol = alloc.dupe(u8, copy.symbol) catch copy.symbol;
        copy.prop_start = 0;
        copy.prop_count = 0;
        state.clipboard.instances.append(alloc, copy) catch {};
    }
    for (0..sch.wires.len) |i| {
        if (!selWire(fio, i)) continue;
        var copy = sch.wires.get(i);
        copy.net_name = if (copy.net_name) |n| alloc.dupe(u8, n) catch n else null;
        state.clipboard.wires.append(alloc, copy) catch {};
    }
    state.setStatus("Copied to clipboard");
}

fn pasteFromClipboard(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const sa = fio.alloc;
    fio.selection.clear();
    const paste_off: Point = .{ 20, 20 };
    for (state.clipboard.instances.items) |inst| {
        var copy = inst;
        copy.x += paste_off[0];
        copy.y += paste_off[1];
        copy.name = sa.dupe(u8, inst.name) catch inst.name;
        copy.symbol = sa.dupe(u8, inst.symbol) catch inst.symbol;
        copy.prop_start = 0;
        copy.prop_count = 0;
        sch.instances.append(sa, copy) catch continue;
    }
    for (state.clipboard.wires.items) |w| {
        var copy = w;
        copy.x0 += paste_off[0];
        copy.y0 += paste_off[1];
        copy.x1 += paste_off[0];
        copy.y1 += paste_off[1];
        copy.net_name = if (w.net_name) |n| sa.dupe(u8, n) catch n else null;
        sch.wires.append(sa, copy) catch continue;
    }
    fio.dirty = true;
    state.setStatus("Pasted from clipboard");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Edit (undoable mutations)
// ═══════════════════════════════════════════════════════════════════════════════

pub fn handleEdit(und: Undoable, state: anytype) Error!void {
    switch (und) {
        // ── Transforms ───────────────────────────────────────────────────────
        .rotate_cw => rotateSelected(state, 1),
        .rotate_ccw => rotateSelected(state, 3),
        .flip_horizontal => flipSelectedH(state),
        .flip_vertical => flipSelectedV(state),

        .nudge_left => nudgeSelected(state, -10, 0),
        .nudge_right => nudgeSelected(state, 10, 0),
        .nudge_up => nudgeSelected(state, 0, -10),
        .nudge_down => nudgeSelected(state, 0, 10),

        .align_to_grid => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const snap = state.tool.snap_size;
            const xs = sch.instances.items(.x);
            const ys = sch.instances.items(.y);
            var changed = false;
            for (0..sch.instances.len) |i| {
                if (!selInst(fio, i)) continue;
                const fpos: @Vector(2, f32) = .{ @floatFromInt(xs[i]), @floatFromInt(ys[i]) };
                const sv: @Vector(2, f32) = @splat(snap);
                const rounded = @round(fpos / sv) * sv;
                xs[i] = @intFromFloat(rounded[0]);
                ys[i] = @intFromFloat(rounded[1]);
                changed = true;
            }
            if (changed) { fio.dirty = true; state.setStatus("Aligned to grid"); } else state.setStatus("Nothing selected to align");
        },

        // ── Delete / Duplicate ───────────────────────────────────────────────
        .delete_selected => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            // Remove selected wires in reverse order.
            var wi = sch.wires.len;
            while (wi > 0) { wi -= 1; if (selWire(fio, wi)) sch.wires.orderedRemove(wi); }
            // Remove selected instances in reverse order.
            var ii = sch.instances.len;
            while (ii > 0) { ii -= 1; if (selInst(fio, ii)) sch.instances.orderedRemove(ii); }
            fio.selection.clear();
            fio.dirty = true;
        },

        .duplicate_selected => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            const sa = fio.alloc;
            const before_len = sch.instances.len;
            for (0..before_len) |i| {
                if (!selInst(fio, i)) continue;
                var copy = sch.instances.get(i);
                copy.x += 20;
                copy.y += 20;
                sch.instances.append(sa, copy) catch continue;
            }
            fio.dirty = true;
            _ = sch.instances.len - before_len;
        },

        // ── Place device / wire / prop ───────────────────────────────────────
        .place_device => |p| {
            const fio = state.active() orelse return;
            _ = try fio.placeSymbol(p.sym_path, p.name, .{ p.x, p.y });
        },

        .add_wire => |p| {
            const fio = state.active() orelse return;
            try fio.addWireSeg(.{ p.x0, p.y0 }, .{ p.x1, p.y1 }, p.net_name);
        },

        .set_instance_prop => |p| {
            const fio = state.active() orelse return;
            if (p.idx >= fio.sch.instances.len) {
                state.setStatus("Invalid instance index");
                return;
            }
            const sa = fio.alloc;
            const prop_starts = fio.sch.instances.items(.prop_start);
            const prop_counts = fio.sch.instances.items(.prop_count);
            const start: usize = prop_starts[p.idx];
            const count: usize = prop_counts[p.idx];
            // Search existing properties for matching key
            for (fio.sch.props.items[start .. start + count]) |*prop| {
                if (std.mem.eql(u8, prop.key, p.key)) {
                    prop.val = sa.dupe(u8, p.val) catch p.val;
                    fio.dirty = true;
                    state.setStatus("Property updated");
                    return;
                }
            }
            // New property — relocate to end if not already there, then append
            const end: usize = fio.sch.props.items.len;
            if (start + count != end) {
                const new_start: u32 = @intCast(end);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    // Re-index each iteration since append may reallocate
                    const prop = fio.sch.props.items[start + i];
                    fio.sch.props.append(sa, prop) catch {
                        state.setStatus("Failed to add property");
                        return;
                    };
                }
                prop_starts[p.idx] = new_start;
            }
            fio.sch.props.append(sa, .{
                .key = sa.dupe(u8, p.key) catch p.key,
                .val = sa.dupe(u8, p.val) catch p.val,
            }) catch {
                state.setStatus("Failed to add property");
                return;
            };
            prop_counts[p.idx] += 1;
            fio.dirty = true;
            state.setStatus("Property set");
        },

        .delete_instance => |p| {
            const fio = state.active() orelse return;
            fio.deleteInstanceAt(@as(usize, p.idx));
        },

        .delete_wire => |p| {
            const fio = state.active() orelse return;
            fio.deleteWireAt(@as(usize, p.idx));
        },

        .move_instance => |p| {
            const fio = state.active() orelse return;
            fio.moveInstanceBy(@as(usize, p.idx), p.dx, p.dy);
        },

        .move_wire => |p| {
            const fio = state.active() orelse return;
            if (p.idx < fio.sch.wires.len) {
                fio.sch.wires.items(.x0)[p.idx] += p.dx;
                fio.sch.wires.items(.y0)[p.idx] += p.dy;
                fio.sch.wires.items(.x1)[p.idx] += p.dx;
                fio.sch.wires.items(.y1)[p.idx] += p.dy;
                fio.dirty = true;
            }
        },

        .rename_instance => |p| {
            const fio = state.active() orelse return;
            if (p.idx >= fio.sch.instances.len) {
                state.setStatus("Invalid instance index");
                return;
            }
            fio.sch.instances.items(.name)[p.idx] = fio.alloc.dupe(u8, p.new_name) catch p.new_name;
            fio.dirty = true;
            state.setStatus("Instance renamed");
        },

        .rename_net => |p| {
            const fio = state.active() orelse return;
            if (p.wire_idx >= fio.sch.wires.len) {
                state.setStatus("Invalid wire index");
                return;
            }
            fio.sch.wires.items(.net_name)[p.wire_idx] = fio.alloc.dupe(u8, p.new_name) catch p.new_name;
            fio.dirty = true;
            state.setStatus("Net renamed");
        },

        .set_spice_code => |p| {
            const fio = state.active() orelse return;
            fio.sch.spice_body = fio.alloc.dupe(u8, p.code) catch p.code;
            fio.dirty = true;
            state.setStatus("SPICE code updated");
        },

        // Handled by dispatchUndoable in Dispatch.zig directly.
        .run_sim, .plugin_mutation => {},
    }
}

fn rotateSelected(state: anytype, comptime increment: u2) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const flags = sch.instances.items(.flags);

    var sum_x: i64 = 0;
    var sum_y: i64 = 0;
    var count: i64 = 0;
    for (0..sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        sum_x += xs[i];
        sum_y += ys[i];
        count += 1;
    }
    if (count == 0) return;

    if (count == 1) {
        for (0..flags.len) |i| {
            if (!selInst(fio, i)) continue;
            flags[i].rot = flags[i].rot +% increment;
        }
    } else {
        const cx: i32 = @intCast(@divTrunc(sum_x, count));
        const cy: i32 = @intCast(@divTrunc(sum_y, count));
        const snap: i32 = @intFromFloat(state.tool.snap_size);
        const gcx = if (snap > 0) @divTrunc(cx + @divTrunc(snap, 2), snap) * snap else cx;
        const gcy = if (snap > 0) @divTrunc(cy + @divTrunc(snap, 2), snap) * snap else cy;

        for (0..sch.instances.len) |i| {
            if (!selInst(fio, i)) continue;
            const dx = xs[i] - gcx;
            const dy = ys[i] - gcy;
            if (increment == 1) {
                xs[i] = gcx + dy;
                ys[i] = gcy - dx;
            } else {
                xs[i] = gcx - dy;
                ys[i] = gcy + dx;
            }
            flags[i].rot = flags[i].rot +% increment;
        }
    }
    fio.dirty = true;
}

fn flipSelectedH(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const xs = sch.instances.items(.x);
    const flags = sch.instances.items(.flags);

    var sum_x: i64 = 0;
    var count: i64 = 0;
    for (0..sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        sum_x += xs[i];
        count += 1;
    }
    if (count == 0) return;

    if (count == 1) {
        for (0..flags.len) |i| {
            if (!selInst(fio, i)) continue;
            flags[i].flip = !flags[i].flip;
        }
    } else {
        const cx: i32 = @intCast(@divTrunc(sum_x, count));
        for (0..sch.instances.len) |i| {
            if (!selInst(fio, i)) continue;
            xs[i] = 2 * cx - xs[i];
            flags[i].flip = !flags[i].flip;
        }
    }
    fio.dirty = true;
}

fn flipSelectedV(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const ys = sch.instances.items(.y);
    const flags = sch.instances.items(.flags);

    var sum_y: i64 = 0;
    var count: i64 = 0;
    for (0..sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        sum_y += ys[i];
        count += 1;
    }
    if (count == 0) return;

    if (count == 1) {
        for (0..flags.len) |i| {
            if (!selInst(fio, i)) continue;
            flags[i].flip = !flags[i].flip;
            flags[i].rot = flags[i].rot +% 2;
        }
    } else {
        const cy: i32 = @intCast(@divTrunc(sum_y, count));
        for (0..sch.instances.len) |i| {
            if (!selInst(fio, i)) continue;
            ys[i] = 2 * cy - ys[i];
            flags[i].flip = !flags[i].flip;
            flags[i].rot = flags[i].rot +% 2;
        }
    }
    fio.dirty = true;
}

fn nudgeSelected(state: anytype, dx: i32, dy: i32) void {
    const fio = state.active() orelse return;
    const xs = fio.sch.instances.items(.x);
    const ys = fio.sch.instances.items(.y);
    var changed = false;
    for (0..fio.sch.instances.len) |i| {
        if (!selInst(fio, i)) continue;
        xs[i] += dx;
        ys[i] += dy;
        changed = true;
    }
    if (changed) fio.dirty = true;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Wire mode
// ═══════════════════════════════════════════════════════════════════════════════

pub fn handleStartWire(state: anytype) void {
    state.tool.wire_start = null;
    state.tool.active = .wire;
    state.setStatus("Wire mode — click to start");
}

pub fn handleEscapeMode(state: anytype) void {
    state.tool.wire_start = null;
    state.tool.active = .select;
    if (state.active()) |fio| fio.selection.clear();
    state.setStatus("Ready");
}

pub fn handleInsertPrimitive(kind: types.PrimitiveKind, state: anytype) void {
    const fio = state.active() orelse return;
    const pos = state.gui.hot.canvas.cursor_world;
    const kind_name = kind.kindName();
    const pfx = kind.prefix();

    // Count existing instances with same prefix to generate unique name
    var counter: u32 = 1;
    const names = fio.sch.instances.items(.name);
    for (0..fio.sch.instances.len) |i| {
        if (names[i].len > 0 and names[i][0] == pfx) counter += 1;
    }

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{c}{d}", .{ pfx, counter }) catch "X1";

    _ = fio.sch.addInstance(fio.alloc, name, kind_name, pos[0], pos[1]) catch {
        state.setStatus("Failed to insert primitive");
        return;
    };
    fio.dirty = true;
    state.setStatus("Inserted primitive");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  File / Tab
// ═══════════════════════════════════════════════════════════════════════════════

pub fn handleFile(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .file_new, .new_tab => {
            var buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "untitled_{d}.comp", .{state.documents.items.len + 1}) catch "untitled.comp";
            state.newFile(name) catch {
                state.setStatus("Failed to create new tab");
                return;
            };
        },
        .close_tab => {
            if (state.documents.items.len <= 1) { state.setStatus("Cannot close last tab"); return; }
            const idx = state.active_idx;
            state.documents.items[idx].deinit();
            _ = state.documents.orderedRemove(idx);
            if (@as(usize, state.active_idx) >= state.documents.items.len)
                state.active_idx = @intCast(state.documents.items.len - 1);
            if (state.active()) |fd| fd.selection.clear();
            state.setStatus("Tab closed");
        },
        .next_tab => {
            if (state.documents.items.len > 0) {
                state.active_idx = @intCast((@as(usize, state.active_idx) + 1) % state.documents.items.len);
                state.setStatus("Next tab");
            }
        },
        .prev_tab => {
            if (state.documents.items.len > 0) {
                state.active_idx = if (state.active_idx == 0)
                    @intCast(state.documents.items.len - 1)
                else
                    state.active_idx - 1;
                state.setStatus("Previous tab");
            }
        },
        .file_open => { state.open_file_explorer = true; state.setStatus("Open file"); },
        .file_save_as => state.setStatus("Save as (use :saveas <path>)"),
        .file_save_all => state.setStatus("Save all"),
        .reopen_closed_tab => {
            if (state.closed_tabs.popLast()) |path| {
                state.openPath(path) catch { state.setStatus("Reopen failed"); return; };
                state.allocator().free(path);
                state.setStatus("Reopened tab");
            } else state.setStatus("No closed tabs");
        },
        .file_save => {
            const fio = state.active() orelse { state.setStatus("No active document"); return; };
            const path = switch (fio.origin) {
                .chn_file => |p| p,
                else => { state.setStatus("Save as (use :saveas <path>)"); return; },
            };
            state.saveActiveTo(path) catch {
                state.setStatus("Save failed");
                return;
            };
            state.setStatus("Saved");
        },
        .reload_from_disk => {
            const fio = state.active() orelse return;
            const reload_path: ?[]const u8 = switch (fio.origin) {
                .chn_file => |p| p,
                .buffer, .unsaved => null,
            };
            if (reload_path) |p| {
                state.openPath(p) catch {
                    state.setStatus("Reload failed");
                };
            } else state.setStatus("No disk path to reload from");
        },
        else => {},
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Hierarchy
// ═══════════════════════════════════════════════════════════════════════════════

pub fn handleHierarchy(imm: Immediate, state: anytype) void {
    switch (imm) {
        .descend_schematic => descendInto(state, ".chn", "schematic"),
        .descend_symbol => descendInto(state, ".chn_prim", "symbol"),
        .ascend => {
            const entry = state.hierarchy_stack.pop() orelse {
                state.setStatus("Already at top level");
                return;
            };
            if (entry.doc_idx < state.documents.items.len) {
                state.active_idx = @intCast(entry.doc_idx);
                if (state.active()) |fd| fd.selection.clear();
                state.setStatus("Ascended to parent");
            } else state.setStatus("Parent document no longer open");
        },
        .edit_in_new_tab => {
            const idx = firstSelectedInst(state) orelse {
                state.setStatus("Select an instance first");
                return;
            };
            const fio = state.active() orelse return;
            const inst = fio.sch.instances.get(idx);
            var buf: [512]u8 = undefined;
            const path = resolveSymbolFile(state, fio, inst.symbol, ".chn", &buf) orelse
                resolveSymbolFile(state, fio, inst.symbol, ".chn_prim", &buf) orelse {
                state.setStatus("No file found for this symbol");
                return;
            };
            state.openPath(path) catch { state.setStatus("Failed to open in new tab"); return; };
            state.setStatus("Opened in new tab");
        },
        .insert_from_library => { state.open_library_browser = true; },
        .open_file_explorer => { state.open_file_explorer = !state.open_file_explorer; },
        .make_symbol_from_schematic => makeSymbolFromSchematic(state),
        .make_schematic_from_symbol => makeSchematicFromSymbol(state),
        else => {},
    }
}

fn firstSelectedInst(state: anytype) ?usize {
    const fio = state.active() orelse return null;
    if (fio.selection.instances.bit_length == 0) return null;
    var it = fio.selection.instances.iterator(.{});
    return it.next();
}

fn descendInto(state: anytype, comptime ext: []const u8, comptime kind: []const u8) void {
    const idx = firstSelectedInst(state) orelse {
        state.setStatus("Select an instance to descend into");
        return;
    };
    const fio = state.active() orelse return;
    const inst = fio.sch.instances.get(idx);
    var buf: [512]u8 = undefined;
    const path = resolveSymbolFile(state, fio, inst.symbol, ext, &buf) orelse {
        state.setStatus("No " ++ kind ++ " found for this symbol");
        return;
    };
    state.hierarchy_stack.append(state.allocator(), .{
        .doc_idx = state.active_idx,
        .instance_idx = idx,
    }) catch { state.setStatus("Hierarchy stack full"); return; };
    state.openPath(path) catch {
        _ = state.hierarchy_stack.pop();
        state.setStatus("Failed to open " ++ kind);
        return;
    };
    state.setStatus("Descended into " ++ kind);
}

fn makeSymbolFromSchematic(state: anytype) void {
    if (is_wasm) { state.setStatus("Not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const sch = &fio.sch;

    // Derive output path from current file: foo.chn -> foo.chn_prim
    const base_path: []const u8 = switch (fio.origin) {
        .chn_file => |p| p,
        else => { state.setStatus("Save the schematic first"); return; },
    };
    var path_buf: [512]u8 = undefined;
    const prim_path = std.fmt.bufPrint(&path_buf, "{s}_prim", .{base_path}) catch {
        state.setStatus("Path too long");
        return;
    };

    // Collect I/O pin instances → symbol pins
    const ikind = sch.instances.items(.kind);
    const iname = sch.instances.items(.name);
    const ixx = sch.instances.items(.x);
    const iyy = sch.instances.items(.y);

    // Count I/O pins
    var pin_count: usize = 0;
    for (0..sch.instances.len) |i| if (ikind[i].isLabel()) { pin_count += 1; };
    if (pin_count == 0) { state.setStatus("No I/O pins found in schematic"); return; }

    // Build symbol content
    const alloc = state.allocator();
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    // Derive cell name from path
    const stem = std.fs.path.stem(base_path);

    w.writeAll("chn_prim 1\n\nSYMBOL ") catch { state.setStatus("Out of memory"); return; };
    w.writeAll(stem) catch return;
    w.writeByte('\n') catch return;
    w.writeAll("  desc: Auto-generated symbol\n") catch return;

    // Compute bounding box of pin instances for drawing
    var lo_x: i32 = std.math.maxInt(i32);
    var lo_y: i32 = std.math.maxInt(i32);
    var hi_x: i32 = std.math.minInt(i32);
    var hi_y: i32 = std.math.minInt(i32);
    for (0..sch.instances.len) |i| {
        if (!ikind[i].isLabel()) continue;
        lo_x = @min(lo_x, ixx[i]);
        lo_y = @min(lo_y, iyy[i]);
        hi_x = @max(hi_x, ixx[i]);
        hi_y = @max(hi_y, iyy[i]);
    }
    // Add padding
    lo_x -= 40;
    lo_y -= 40;
    hi_x += 40;
    hi_y += 40;

    // Write pins
    w.writeAll("  pins:\n") catch return;
    for (0..sch.instances.len) |i| {
        if (!ikind[i].isLabel()) continue;
        const dir_str: []const u8 = switch (ikind[i]) {
            .input_pin => "in",
            .output_pin => "out",
            .inout_pin => "inout",
            .lab_pin => "inout",
            else => "inout",
        };
        w.print("    {s}  {s}  x={d}  y={d}\n", .{
            iname[i], dir_str, ixx[i], iyy[i],
        }) catch return;
    }

    // Write bounding box drawing
    w.print("  drawing:\n    rect {d} {d} {d} {d}\n", .{ lo_x, lo_y, hi_x, hi_y }) catch return;

    @import("dvui").fs.cwd().writeFile(.{ .sub_path = prim_path, .data = buf.items }) catch {
        state.setStatus("Failed to write symbol file");
        return;
    };
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Symbol created: {s}", .{prim_path}) catch "Symbol created";
    state.setStatusBuf(msg);
}

fn makeSchematicFromSymbol(state: anytype) void {
    if (is_wasm) { state.setStatus("Not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const sch = &fio.sch;

    if (sch.pins.len == 0) { state.setStatus("No pins defined in this symbol"); return; }

    // Derive output path: foo.chn_prim -> foo.chn (or foo.chn -> foo_impl.chn)
    const base_path: []const u8 = switch (fio.origin) {
        .chn_file => |p| p,
        else => { state.setStatus("Save the symbol first"); return; },
    };
    var path_buf: [512]u8 = undefined;
    const sch_path = if (std.mem.endsWith(u8, base_path, ".chn_prim"))
        std.fmt.bufPrint(&path_buf, "{s}.chn", .{base_path[0 .. base_path.len - "_prim".len]}) catch {
            state.setStatus("Path too long");
            return;
        }
    else
        std.fmt.bufPrint(&path_buf, "{s}_impl.chn", .{base_path[0 .. base_path.len - ".chn".len]}) catch {
            state.setStatus("Path too long");
            return;
        };

    // Don't overwrite existing files
    if (pathExists(sch_path)) {
        state.setStatus("Schematic file already exists");
        return;
    }

    const alloc = state.allocator();
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    const stem = std.fs.path.stem(base_path);
    w.writeAll("chn 1\n\nSYMBOL ") catch { state.setStatus("Out of memory"); return; };
    w.writeAll(stem) catch return;
    w.writeByte('\n') catch return;

    // Copy pins from the symbol
    const pn = sch.pins.items(.name);
    const pd = sch.pins.items(.dir);
    const px = sch.pins.items(.x);
    const py = sch.pins.items(.y);
    if (sch.pins.len > 0) {
        w.writeAll("  pins:\n") catch return;
        for (0..sch.pins.len) |i| {
            const dir_str: []const u8 = switch (pd[i]) {
                .input => "in", .output => "out", .inout => "inout",
                .power => "inout", .ground => "inout",
            };
            w.print("    {s}  {s}  x={d}  y={d}\n", .{ pn[i], dir_str, px[i], py[i] }) catch return;
        }
    }

    // Create schematic section with pin instances placed at corresponding positions
    w.writeAll("\nSCHEMATIC\n  instances:\n") catch return;
    for (0..sch.pins.len) |i| {
        const kind_str: []const u8 = switch (pd[i]) {
            .input => "ipin", .output => "opin", .inout => "iopin",
            .power => "ipin", .ground => "ipin",
        };
        w.print("    {s}  {s}  x={d}  y={d}\n", .{
            pn[i], kind_str, px[i], py[i],
        }) catch return;
    }

    @import("dvui").fs.cwd().writeFile(.{ .sub_path = sch_path, .data = buf.items }) catch {
        state.setStatus("Failed to write schematic file");
        return;
    };

    // Open the newly created schematic
    state.openPath(sch_path) catch {
        state.setStatus("Schematic created but failed to open");
        return;
    };
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Schematic created: {s}", .{sch_path}) catch "Schematic created";
    state.setStatusBuf(msg);
}

fn pathExists(path: []const u8) bool {
    @import("dvui").fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn exportSvgFile(sch: anytype, path: []const u8) !void {
    const dvui = @import("dvui");
    const core = @import("core");
    const primitives = core.devices.primitives;
    const file = try dvui.fs.cwd().createFile(path, .{});
    defer file.close();

    // Compute bounding box over all geometry.
    var lo_x: i32 = std.math.maxInt(i32);
    var lo_y: i32 = std.math.maxInt(i32);
    var hi_x: i32 = std.math.minInt(i32);
    var hi_y: i32 = std.math.minInt(i32);
    for (0..sch.wires.len) |i| {
        const w = sch.wires.get(i);
        lo_x = @min(lo_x, @min(w.x0, w.x1));
        lo_y = @min(lo_y, @min(w.y0, w.y1));
        hi_x = @max(hi_x, @max(w.x0, w.x1));
        hi_y = @max(hi_y, @max(w.y0, w.y1));
    }
    const inst_x = sch.instances.items(.x);
    const inst_y = sch.instances.items(.y);
    const inst_kind = sch.instances.items(.kind);
    const inst_flags = sch.instances.items(.flags);
    const inst_name = sch.instances.items(.name);
    for (0..sch.instances.len) |i| {
        // Expand bounds by ~50 around each instance to account for symbol size.
        lo_x = @min(lo_x, inst_x[i] - 50);
        lo_y = @min(lo_y, inst_y[i] - 50);
        hi_x = @max(hi_x, inst_x[i] + 50);
        hi_y = @max(hi_y, inst_y[i] + 50);
    }
    if (lo_x > hi_x) { lo_x = 0; lo_y = 0; hi_x = 100; hi_y = 100; }
    const pad: i32 = 30;
    lo_x -= pad; lo_y -= pad; hi_x += pad; hi_y += pad;

    var buf: [512]u8 = undefined;
    var len: usize = 0;

    // SVG header.
    len = (std.fmt.bufPrint(&buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{d} {d} {d} {d}\">\n", .{ lo_x, lo_y, hi_x - lo_x, hi_y - lo_y }) catch &buf).len;
    try file.writeAll(buf[0..len]);
    try file.writeAll("<style>\n");
    try file.writeAll("  line.w{stroke:#58d2ff;stroke-width:2;stroke-linecap:round}\n");
    try file.writeAll("  .sym{stroke:#88ccff;stroke-width:1.5;fill:none;stroke-linecap:round;stroke-linejoin:round}\n");
    try file.writeAll("  .box{stroke:#88ccff;stroke-width:1.2;fill:none}\n");
    try file.writeAll("  text.n{font:9px monospace;fill:#7888a0}\n");
    try file.writeAll("  text.p{font:8px monospace;fill:#667788}\n");
    try file.writeAll("  circle.dot{fill:#58d2ff}\n");
    try file.writeAll("</style>\n");
    try file.writeAll("<rect width=\"100%\" height=\"100%\" fill=\"#16161c\"/>\n");

    // Wires.
    for (0..sch.wires.len) |i| {
        const w = sch.wires.get(i);
        len = (std.fmt.bufPrint(&buf, "<line class=\"w\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ w.x0, w.y0, w.x1, w.y1 }) catch &buf).len;
        try file.writeAll(buf[0..len]);
    }

    // Wire junction dots (endpoints shared by 3+ wires).
    try svgWriteJunctions(sch, file);

    // Instances.
    for (0..sch.instances.len) |i| {
        const ox = inst_x[i];
        const oy = inst_y[i];
        const rot = inst_flags[i].rot;
        const flip = inst_flags[i].flip;

        const prim: ?*const primitives.PrimEntry = primitives.findByNameRuntime(@tagName(inst_kind[i]));
        if (prim) |entry| {
            try svgWritePrim(entry, ox, oy, rot, flip, file, &buf);
        } else {
            // Generic subcircuit box.
            const sd = if (i < sch.sym_data.items.len) sch.sym_data.items[i] else core.types.SymData{};
            try svgWriteGenericBox(sd, ox, oy, rot, flip, file, &buf);
        }

        // Instance name label.
        if (inst_name[i].len > 0) {
            const rf = svgRotFlip(25, -20, rot, flip);
            len = (std.fmt.bufPrint(&buf, "<text class=\"n\" x=\"{d}\" y=\"{d}\">{s}</text>\n", .{ ox + rf[0], oy + rf[1], inst_name[i] }) catch &buf).len;
            try file.writeAll(buf[0..len]);
        }
    }

    try file.writeAll("</svg>\n");
}

fn svgRotFlip(px: i32, py: i32, rot: u2, flip: bool) [2]i32 {
    const x: i32 = if (flip) -px else px;
    return switch (rot) {
        0 => .{ x, py },
        1 => .{ -py, x },
        2 => .{ -x, -py },
        3 => .{ py, -x },
    };
}

fn svgWritePrim(entry: anytype, ox: i32, oy: i32, rot: u2, flip: bool, file: anytype, buf: *[512]u8) !void {
    var len: usize = 0;

    // Line segments.
    for (entry.segs()) |seg| {
        const a = svgRotFlip(seg.x0, seg.y0, rot, flip);
        const b = svgRotFlip(seg.x1, seg.y1, rot, flip);
        len = (std.fmt.bufPrint(buf, "<line class=\"sym\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ ox + a[0], oy + a[1], ox + b[0], oy + b[1] }) catch buf).len;
        try file.writeAll(buf[0..len]);
    }

    // Rectangles.
    for (entry.drawRects()) |rect| {
        const a = svgRotFlip(rect.x0, rect.y0, rot, flip);
        const b = svgRotFlip(rect.x1, rect.y1, rot, flip);
        const rx = @min(ox + a[0], ox + b[0]);
        const ry = @min(oy + a[1], oy + b[1]);
        const rw = @max(a[0], b[0]) - @min(a[0], b[0]);
        const rh = @max(a[1], b[1]) - @min(a[1], b[1]);
        len = (std.fmt.bufPrint(buf, "<rect class=\"sym\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\"/>\n", .{ rx, ry, rw, rh }) catch buf).len;
        try file.writeAll(buf[0..len]);
    }

    // Circles.
    for (entry.drawCircles()) |circ| {
        const c = svgRotFlip(circ.cx, circ.cy, rot, flip);
        len = (std.fmt.bufPrint(buf, "<circle class=\"sym\" cx=\"{d}\" cy=\"{d}\" r=\"{d}\"/>\n", .{ ox + c[0], oy + c[1], circ.r }) catch buf).len;
        try file.writeAll(buf[0..len]);
    }

    // Arcs.
    for (entry.drawArcs()) |arc| {
        const c = svgRotFlip(arc.cx, arc.cy, rot, flip);
        try svgWriteArc(ox + c[0], oy + c[1], arc.r, arc.start, arc.sweep, rot, flip, file, buf);
    }

    // Pin dots.
    for (entry.pinPositions()) |pp| {
        if (entry.non_electrical and pp.x == 0 and pp.y == 0) continue;
        const p = svgRotFlip(pp.x, pp.y, rot, flip);
        len = (std.fmt.bufPrint(buf, "<circle class=\"dot\" cx=\"{d}\" cy=\"{d}\" r=\"2\"/>\n", .{ ox + p[0], oy + p[1] }) catch buf).len;
        try file.writeAll(buf[0..len]);
    }
}

fn svgWriteGenericBox(sd: anytype, ox: i32, oy: i32, rot: u2, flip: bool, file: anytype, buf: *[512]u8) !void {
    var len: usize = 0;
    const half_w: i32 = 25;
    const half_h: i32 = 25;

    if (sd.pins.len == 0) {
        // Simple box.
        const corners = [4][2]i32{ .{ -half_w, -half_h }, .{ half_w, -half_h }, .{ half_w, half_h }, .{ -half_w, half_h } };
        for (0..4) |ci| {
            const a = svgRotFlip(corners[ci][0], corners[ci][1], rot, flip);
            const b = svgRotFlip(corners[(ci + 1) % 4][0], corners[(ci + 1) % 4][1], rot, flip);
            len = (std.fmt.bufPrint(buf, "<line class=\"box\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ ox + a[0], oy + a[1], ox + b[0], oy + b[1] }) catch buf).len;
            try file.writeAll(buf[0..len]);
        }
        return;
    }

    // Compute box extents from pin positions.
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    for (sd.pins) |pin| {
        min_x = @min(min_x, pin.x); min_y = @min(min_y, pin.y);
        max_x = @max(max_x, pin.x); max_y = @max(max_y, pin.y);
    }
    const bpad: i32 = 10;
    const bhw: i32 = @max(@divTrunc(max_x - min_x, 2) + bpad, half_w);
    const bhh: i32 = @max(@divTrunc(max_y - min_y, 2) + bpad, half_h);

    const box_corners = [4][2]i32{ .{ -bhw, -bhh }, .{ bhw, -bhh }, .{ bhw, bhh }, .{ -bhw, bhh } };
    for (0..4) |ci| {
        const a = svgRotFlip(box_corners[ci][0], box_corners[ci][1], rot, flip);
        const b = svgRotFlip(box_corners[(ci + 1) % 4][0], box_corners[(ci + 1) % 4][1], rot, flip);
        len = (std.fmt.bufPrint(buf, "<line class=\"box\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ ox + a[0], oy + a[1], ox + b[0], oy + b[1] }) catch buf).len;
        try file.writeAll(buf[0..len]);
    }

    // Pin stubs + labels.
    for (sd.pins) |pin| {
        const edge_x: i32 = if (pin.x < 0) -bhw else bhw;
        const pp = svgRotFlip(pin.x, pin.y, rot, flip);
        const ep = svgRotFlip(edge_x, pin.y, rot, flip);
        len = (std.fmt.bufPrint(buf, "<line class=\"box\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ ox + ep[0], oy + ep[1], ox + pp[0], oy + pp[1] }) catch buf).len;
        try file.writeAll(buf[0..len]);
        if (pin.name.len > 0) {
            const lx = if (pin.x < 0) ox + ep[0] + 3 else ox + ep[0] - @as(i32, @intCast(pin.name.len)) * 6 - 3;
            len = (std.fmt.bufPrint(buf, "<text class=\"p\" x=\"{d}\" y=\"{d}\">{s}</text>\n", .{ lx, oy + ep[1] - 2, pin.name }) catch buf).len;
            try file.writeAll(buf[0..len]);
        }
    }
}

fn svgWriteArc(cx: i32, cy: i32, r: i16, start: i16, sweep: i16, rot: u2, flip: bool, file: anytype, buf: *[512]u8) !void {
    // Convert start/sweep angles to SVG arc path.
    var sa: i16 = start;
    const sw: i16 = sweep;
    if (flip) sa = 180 - sa - sw;
    sa += @as(i16, @intCast(rot)) * 90;

    const pi = std.math.pi;
    const start_rad: f64 = @as(f64, @floatFromInt(sa)) * pi / 180.0;
    const end_rad: f64 = @as(f64, @floatFromInt(sa + sw)) * pi / 180.0;
    const rf: f64 = @floatFromInt(r);

    const x1f = @as(f64, @floatFromInt(cx)) + rf * @cos(start_rad);
    const y1f = @as(f64, @floatFromInt(cy)) - rf * @sin(start_rad);
    const x2f = @as(f64, @floatFromInt(cx)) + rf * @cos(end_rad);
    const y2f = @as(f64, @floatFromInt(cy)) - rf * @sin(end_rad);

    const x1: i32 = @intFromFloat(@round(x1f));
    const y1: i32 = @intFromFloat(@round(y1f));
    const x2: i32 = @intFromFloat(@round(x2f));
    const y2: i32 = @intFromFloat(@round(y2f));
    const large_arc: u1 = if (@abs(sw) > 180) 1 else 0;
    const sweep_flag: u1 = if (sw < 0) 1 else 0;

    const len = (std.fmt.bufPrint(buf, "<path class=\"sym\" d=\"M{d},{d} A{d},{d} 0 {d} {d} {d},{d}\"/>\n", .{ x1, y1, r, r, large_arc, sweep_flag, x2, y2 }) catch buf).len;
    try file.writeAll(buf[0..len]);
}

fn svgWriteJunctions(sch: anytype, file: anytype) !void {
    // Count how many wire endpoints share each point.
    // Points with 3+ connections get a junction dot.
    var buf: [128]u8 = undefined;
    const wires_len = sch.wires.len;
    if (wires_len < 2) return;

    const wx0 = sch.wires.items(.x0);
    const wy0 = sch.wires.items(.y0);
    const wx1 = sch.wires.items(.x1);
    const wy1 = sch.wires.items(.y1);

    // Simple O(n^2) check — fine for SVG export.
    for (0..wires_len) |i| {
        const points = [2][2]i32{ .{ wx0[i], wy0[i] }, .{ wx1[i], wy1[i] } };
        for (points) |pt| {
            var count: u32 = 0;
            for (0..wires_len) |j| {
                if ((wx0[j] == pt[0] and wy0[j] == pt[1]) or (wx1[j] == pt[0] and wy1[j] == pt[1]))
                    count += 1;
            }
            if (count >= 3) {
                const len = (std.fmt.bufPrint(&buf, "<circle class=\"dot\" cx=\"{d}\" cy=\"{d}\" r=\"3\"/>\n", .{ pt[0], pt[1] }) catch &buf).len;
                try file.writeAll(buf[0..len]);
            }
        }
    }
}

fn resolveSymbolFile(state: anytype, fio: anytype, symbol: []const u8, ext: []const u8, buf: *[512]u8) ?[]const u8 {
    if (std.mem.endsWith(u8, symbol, ext)) {
        if (pathExists(symbol)) return symbol;
    }
    const dir: []const u8 = switch (fio.origin) {
        .chn_file => |p| std.fs.path.dirname(p) orelse ".",
        else => ".",
    };
    if (std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ dir, symbol, ext })) |path| {
        if (pathExists(path)) return path;
    } else |_| {}
    if (std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ state.project_dir, symbol, ext })) |path| {
        if (pathExists(path)) return path;
    } else |_| {}
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Netlist
// ═══════════════════════════════════════════════════════════════════════════════

pub fn handleNetlist(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .netlist_hierarchical => {
            state.setStatus("Generating hierarchical netlist...");
            generateNetlist(state, "Netlist written") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        .netlist_top_only => {
            state.setStatus("Generating top-level netlist...");
            generateNetlist(state, "Top-level netlist written") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        .netlist_flat => {
            state.setStatus("Generating flat netlist...");
            generateNetlist(state, "Flat netlist written") catch {
                state.setStatus("Netlist generation failed");
            };
        },
        else => {},
    }
}

fn generateNetlist(state: anytype, ok_msg: []const u8) !void {
    const fio = state.active() orelse return;
    const alloc = state.allocator();

    const spice = try fio.createNetlist(.ngspice);
    defer alloc.free(spice);

    if (spice.len > state.last_netlist.len) {
        if (state.last_netlist.len > 0) alloc.free(state.last_netlist);
        state.last_netlist = alloc.alloc(u8, spice.len) catch &.{};
    }
    if (state.last_netlist.len >= spice.len) {
        @memcpy(state.last_netlist[0..spice.len], spice);
        state.last_netlist_len = spice.len;
    }
    state.setStatus(ok_msg);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Simulation
// ═══════════════════════════════════════════════════════════════════════════════

pub fn handleRunSim(p: types.RunSim, state: anytype) void {
    if (is_wasm) { state.setStatus("Simulation not available in browser"); return; }
    _ = p;
    const fio = state.active() orelse return;
    _ = fio;
    state.setStatus("Simulation launched");
}

fn tryLaunchViewer(alloc: std.mem.Allocator, bin: []const u8, path: []const u8) bool {
    var child = std.process.Child.init(&.{ bin, path }, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    return true;
}

pub fn handleOpenWaveformViewer(state: anytype) void {
    if (is_wasm) { state.setStatus("Waveform viewer not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const base_name: []const u8 = switch (fio.origin) {
        .chn_file => |p| std.fs.path.stem(p),
        else => { state.setStatus("Save the file first"); return; },
    };

    // Look for the .raw file produced by simulation
    var raw_buf: [512]u8 = undefined;
    const raw_path = std.fmt.bufPrint(&raw_buf, "/tmp/{s}.raw", .{base_name}) catch {
        state.setStatus("Path too long");
        return;
    };
    if (!pathExists(raw_path)) {
        state.setStatus("No simulation results found — run a simulation first");
        return;
    }

    // Try gaw first, then gtkwave, then fallback to ngspice
    if (tryLaunchViewer(state.allocator(), "gaw", raw_path) or
        tryLaunchViewer(state.allocator(), "gtkwave", raw_path))
    {
        state.setStatus("Waveform viewer opened");
        return;
    }
    // Fallback: open raw file in xterm with ngspice
    var cmd_buf: [1024]u8 = undefined;
    const cmd_str = std.fmt.bufPrint(&cmd_buf, "ngspice \"{s}\"; echo '--- Press Enter to close ---'; read", .{raw_path}) catch {
        state.setStatus("Path too long for viewer command");
        return;
    };
    var child = std.process.Child.init(
        &.{ "xterm", "-T", "Schemify Waveforms", "-e", "sh", "-c", cmd_str },
        state.allocator(),
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        state.setStatus("Failed to launch waveform viewer");
        return;
    };
    state.setStatus("Waveform viewer opened (ngspice)");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Undo / Redo
// ═══════════════════════════════════════════════════════════════════════════════

/// Undo/redo history backed by a fixed ring buffer.
pub const History = struct {
    pub const CAP = 64;

    entries: [CAP]Undoable = undefined,
    head: u8 = 0,
    len: u8 = 0,

    pub fn push(self: *History, cmd: Undoable) void {
        self.entries[self.head] = cmd;
        self.head = (self.head +% 1) % CAP;
        if (self.len < CAP) self.len += 1;
    }

    pub fn pop(self: *History) ?Undoable {
        if (self.len == 0) return null;
        self.head = if (self.head == 0) CAP - 1 else self.head - 1;
        self.len -= 1;
        return self.entries[self.head];
    }

    pub fn clear(self: *History) void {
        self.len = 0;
        self.head = 0;
    }
};

/// Compute the inverse of an undoable command, if possible.
/// Returns null for commands that require captured state to invert.
pub fn invertCommand(cmd: Undoable) ?Undoable {
    return switch (cmd) {
        .rotate_cw => .rotate_ccw,
        .rotate_ccw => .rotate_cw,
        .flip_horizontal => .flip_horizontal,
        .flip_vertical => .flip_vertical,
        .nudge_left => .nudge_right,
        .nudge_right => .nudge_left,
        .nudge_up => .nudge_down,
        .nudge_down => .nudge_up,
        .move_instance => |p| .{ .move_instance = .{ .idx = p.idx, .dx = -p.dx, .dy = -p.dy } },
        .move_wire => |p| .{ .move_wire = .{ .idx = p.idx, .dx = -p.dx, .dy = -p.dy } },
        else => null,
    };
}

pub fn handleUndo(state: anytype) Error!void {
    const fio = state.active() orelse { state.setStatus("Nothing to undo"); return; };
    const cmd = fio.undo_history.pop() orelse { state.setStatus("Nothing to undo"); return; };
    const inverse = invertCommand(cmd) orelse {
        fio.undo_history.push(cmd);
        state.setStatus("Cannot undo this action");
        return;
    };
    try handleEdit(inverse, state);
    fio.redo_history.push(cmd);
    state.setStatus("Undone");
}

pub fn handleRedo(state: anytype) Error!void {
    const fio = state.active() orelse { state.setStatus("Nothing to redo"); return; };
    const cmd = fio.redo_history.pop() orelse { state.setStatus("Nothing to redo"); return; };
    try handleEdit(cmd, state);
    fio.undo_history.push(cmd);
    state.setStatus("Redone");
}
