//! View handlers — zoom, grid, toggles, and export dispatch.

const std = @import("std");
const h = @import("helpers.zig");
const is_wasm = h.is_wasm;
const Immediate = h.Immediate;
const toggleFlag = h.toggleFlag;
const exp = @import("export.zig");

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
                if (!h.selInst(fio, i)) continue;
                const inst = sch.instances.get(i);
                bb.expand(pointToVec([2]i32{ inst.x, inst.y }));
                found = true;
            }
            for (0..sch.wires.len) |i| {
                if (!h.selWire(fio, i)) continue;
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
        .export_svg => exp.exportAs(state, "svg", null),
        .export_png => exp.exportAs(state, "png", .png),
        .screenshot => { state.pending_screenshot = .full; state.setStatus("Screenshot queued..."); },
        .screenshot_canvas => { state.pending_screenshot = .canvas; state.setStatus("Canvas screenshot queued..."); },
        .export_pdf => exp.exportAs(state, "pdf", .pdf),
        .export_netlist => state.setStatus("Use :netlist command or --netlist CLI flag"),
        .export_verilog => exp.exportVerilog(state),
        .print_schematic => state.setStatus("Print not yet available"),
        else => {},
    }
}
