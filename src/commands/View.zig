//! View command handlers.

const std = @import("std");
const Immediate = @import("command.zig").Immediate;
const dvui = @import("dvui");

pub const Error = error{};

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .zoom_in    => state.view.zoomIn(),
        .zoom_out   => state.view.zoomOut(),
        .zoom_fit   => zoomFitAll(state),
        .zoom_reset => state.view.zoomReset(),

        .zoom_fit_selected => {
            if (state.selection.isEmpty()) { zoomFitAll(state); return; }
            const fio = state.active() orelse return;
            const sch = fio.schematic();
            var bb    = BBox.init();
            var found = false;
            for (sch.instances.items, 0..) |inst, i| {
                if (!selInst(state, i)) continue;
                bb.expand(pointToVec(inst.pos));
                found = true;
            }
            for (sch.wires.items, 0..) |w, i| {
                if (!selWire(state, i)) continue;
                bb.expand(pointToVec(w.start));
                bb.expand(pointToVec(w.end));
                found = true;
            }
            if (found) applyZoomFit(state, bb);
        },

        .toggle_fullscreen => {
            state.cmd_flags.fullscreen = !state.cmd_flags.fullscreen;
            state.setStatus(if (state.cmd_flags.fullscreen) "Fullscreen on (no runtime API)" else "Fullscreen off");
        },
        .toggle_colorscheme => {
            state.cmd_flags.dark_mode = !state.cmd_flags.dark_mode;
            dvui.themeSet(if (state.cmd_flags.dark_mode)
                dvui.Theme.builtin.adwaita_dark
            else
                dvui.Theme.builtin.adwaita_light);
            state.setStatus(if (state.cmd_flags.dark_mode) "Dark mode on" else "Dark mode off");
        },

        .toggle_fill_rects         => toggleFlag(state, "fill_rects",        "Fill rects"),
        .toggle_text_in_symbols    => toggleFlag(state, "text_in_symbols",   "Text in symbols"),
        .toggle_symbol_details     => toggleFlag(state, "symbol_details",    "Symbol details"),
        .toggle_crosshair          => toggleFlag(state, "crosshair",         "Crosshair"),
        .toggle_show_netlist       => toggleFlag(state, "show_netlist",      "Netlist view"),

        .show_all_layers         => { state.cmd_flags.show_all_layers = true;  state.setStatus("Showing all layers (stub)"); },
        .show_only_current_layer => { state.cmd_flags.show_all_layers = false; state.setStatus("Showing current layer only (stub)"); },
        .increase_line_width     => { state.cmd_flags.line_width = @min(10, state.cmd_flags.line_width + 1); state.setStatus("Increased line width (stub)"); },
        .decrease_line_width     => { state.cmd_flags.line_width = @max(1,  state.cmd_flags.line_width - 1); state.setStatus("Decreased line width (stub)"); },

        .snap_halve  => { state.tool.snap_size = @max(1.0,   state.tool.snap_size / 2.0); state.setStatus("Snap halved"); },
        .snap_double => { state.tool.snap_size = @min(100.0, state.tool.snap_size * 2.0); state.setStatus("Snap doubled"); },

        .show_keybinds     => state.setStatus("Keybinds window opened (stub)"),
        .pan_interactive   => { state.tool.active = .pan; state.setStatus("Pan mode (stub)"); },
        .show_context_menu => state.setStatus("Context menu (stub)"),
        .export_pdf        => state.setStatus("Export PDF (stub)"),
        .export_png        => state.setStatus("Export PNG (stub)"),
        .export_svg        => state.setStatus("Export SVG (stub)"),
        .screenshot_area   => state.setStatus("Screenshot (stub)"),
        else => unreachable,
    }
}

// ── Private helpers ──────────────────────────────────────────────────────────

const V2 = @Vector(2, f32);

inline fn selInst(state: anytype, i: usize) bool {
    return i < state.selection.instances.bit_length and state.selection.instances.isSet(i);
}
inline fn selWire(state: anytype, i: usize) bool {
    return i < state.selection.wires.bit_length and state.selection.wires.isSet(i);
}

/// Convert an integer CT.Point to f32 vector.
inline fn pointToVec(p: anytype) V2 {
    return .{ @floatFromInt(p[0]), @floatFromInt(p[1]) };
}

/// Axis-aligned bounding box stored as two `@Vector(2,f32)` — min and max.
const BBox = struct {
    lo: V2,
    hi: V2,

    fn init() BBox {
        const inf = std.math.floatMax(f32);
        return .{ .lo = @splat(inf), .hi = @splat(-inf) };
    }

    inline fn expand(self: *BBox, p: V2) void {
        self.lo = @min(self.lo, p);
        self.hi = @max(self.hi, p);
    }

    inline fn center(self: BBox) V2   { return (self.lo + self.hi) * @as(V2, @splat(0.5)); }
    inline fn size(self: BBox)   V2   { return self.hi - self.lo + @as(V2, @splat(1.0));   }
};

fn zoomFitAll(state: anytype) void {
    const fio = state.active() orelse { state.view.zoomReset(); return; };
    const sch = fio.schematic();
    if (sch.instances.items.len == 0 and sch.wires.items.len == 0) { state.view.zoomReset(); return; }
    var bb = BBox.init();
    for (sch.instances.items) |inst| bb.expand(pointToVec(inst.pos));
    for (sch.wires.items)     |w|    { bb.expand(pointToVec(w.start)); bb.expand(pointToVec(w.end)); }
    applyZoomFit(state, bb);
}

fn applyZoomFit(state: anytype, bb: BBox) void {
    const sz       = bb.size();
    const canvas:  V2 = .{ state.canvas_w, state.canvas_h };
    const fit_zoom = @reduce(.Min, canvas / sz) * 0.9;
    state.view.zoom = @max(0.01, @min(50.0, fit_zoom));
    const c = bb.center();
    state.view.pan = .{ c[0], c[1] };
}

fn toggleFlag(state: anytype, comptime field: []const u8, comptime label: []const u8) void {
    const ptr = &@field(state.cmd_flags, field);
    ptr.* = !ptr.*;
    // Both branches are comptime string literals so status_msg is never dangling.
    state.setStatus(if (ptr.*) label ++ " on (stub)" else label ++ " off (stub)");
}
