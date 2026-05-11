//! Selection and highlighting handlers.

const std = @import("std");
const core = @import("core");
const h = @import("helpers.zig");
const Immediate = h.Immediate;
const selInst = h.selInst;
const selWire = h.selWire;
const resolveSymbolFile = h.resolveSymbolFile;

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
        .edit_properties_readonly => {
            const pd = &state.gui.cold.props_dialog;
            if (state.active()) |fio| {
                if (fio.selection.instances.bit_length > 0) {
                    var it = fio.selection.instances.iterator(.{});
                    if (it.next()) |idx| {
                        if (idx < fio.sch.instances.len) {
                            pd.inst_idx = idx;
                            pd.view_only = true;
                            pd.initialized = false;
                            pd.populateFrom(fio.sch.instances.get(idx), fio.sch.props.items);
                        }
                    }
                }
            }
            pd.is_open = true;
            state.setStatus("Properties (read-only)");
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

