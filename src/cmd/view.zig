//! View command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const cmd = @import("../command.zig");
const Command = cmd.Command;
const dvui = @import("dvui");

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .zoom_in => state.view.zoomIn(),
        .zoom_out => state.view.zoomOut(),
        .zoom_fit => zoomFitAll(state),
        .zoom_reset => state.view.zoomReset(),
        .zoom_fit_selected => zoomFitSelection(state),
        .toggle_fullscreen => {
            state.cmd_flags.fullscreen = !state.cmd_flags.fullscreen;
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
        .snap_halve => {
            state.tool.snap_size = @max(1.0, state.tool.snap_size / 2.0);
            state.setStatus("Snap halved");
        },
        .snap_double => {
            state.tool.snap_size = @min(100.0, state.tool.snap_size * 2.0);
            state.setStatus("Snap doubled");
        },
        .show_keybinds => {
            state.setStatus("Keybinds window opened (stub)");
        },
        .pan_interactive => {
            state.tool.active = .pan;
            state.setStatus("Pan mode (stub)");
        },
        .show_context_menu => state.setStatus("Context menu (stub)"),
        .export_pdf => state.setStatus("Export PDF (stub)"),
        .export_png => state.setStatus("Export PNG (stub)"),
        .export_svg => state.setStatus("Export SVG (stub)"),
        .screenshot_area => state.setStatus("Screenshot (stub)"),
        else => unreachable,
    }
}

// ── Zoom fit helpers ──────────────────────────────────────────────────────────

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
