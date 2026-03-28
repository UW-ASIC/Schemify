//! View command handlers.

const std = @import("std");
const Immediate = @import("command.zig").Immediate;
const dvui = @import("dvui");
const h = @import("helpers.zig");
const selInst = h.selInst;
const selWire = h.selWire;

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
            const sch = &fio.sch;
            var bb    = BBox.init();
            var found = false;
            for (0..sch.instances.len) |i| {
                if (!selInst(state, i)) continue;
                const inst = sch.instances.get(i);
                bb.expand(pointToVec([2]i32{ inst.x, inst.y }));
                found = true;
            }
            for (0..sch.wires.len) |i| {
                if (!selWire(state, i)) continue;
                const w = sch.wires.get(i);
                bb.expand(pointToVec([2]i32{ w.x0, w.y0 }));
                bb.expand(pointToVec([2]i32{ w.x1, w.y1 }));
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

        .show_all_layers         => { state.cmd_flags.show_all_layers = true;  state.setStatus("Showing all layers"); },
        .show_only_current_layer => { state.cmd_flags.show_all_layers = false; state.setStatus("Showing current layer only"); },
        .increase_line_width     => { state.cmd_flags.line_width = @min(10, state.cmd_flags.line_width + 1); state.setStatus("Line width increased"); },
        .decrease_line_width     => { state.cmd_flags.line_width = @max(1,  state.cmd_flags.line_width - 1); state.setStatus("Line width decreased"); },

        .snap_halve  => { state.tool.snap_size = @max(1.0,   state.tool.snap_size / 2.0); state.setStatus("Snap halved"); },
        .snap_double => { state.tool.snap_size = @min(100.0, state.tool.snap_size * 2.0); state.setStatus("Snap doubled"); },

        .show_keybinds     => { state.gui.keybinds_open = true; state.setStatus("Keybinds"); },
        .pan_interactive   => { state.tool.active = .pan; state.setStatus("Pan mode"); },
        .show_context_menu => { state.gui.ctx_menu.open = true; state.setStatus("Context menu"); },
        .export_svg => doExport(state, ".svg", null),
        .export_png => doExport(state, ".png", &.{ "rsvg-convert", "-o" }),
        .export_pdf => doExport(state, ".pdf", &.{ "rsvg-convert", "-f", "pdf", "-o" }),
        .screenshot_area => {
            // TODO: let the user rubber-band select a screen region before exporting.
            // Currently exports the full schematic as PNG, same as export_png.
            doExport(state, ".png", &.{ "rsvg-convert", "-o" });
        },
        else => unreachable,
    }
}

// ── Private helpers ──────────────────────────────────────────────────────────

const V2 = @Vector(2, f32);

/// Convert an integer Point to f32 vector.
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
    const sch = &fio.sch;
    if (sch.instances.len == 0 and sch.wires.len == 0) { state.view.zoomReset(); return; }
    var bb = BBox.init();
    for (0..sch.instances.len) |i| { const inst = sch.instances.get(i); bb.expand(pointToVec([2]i32{ inst.x, inst.y })); }
    for (0..sch.wires.len)     |i| { const w = sch.wires.get(i); bb.expand(pointToVec([2]i32{ w.x0, w.y0 })); bb.expand(pointToVec([2]i32{ w.x1, w.y1 })); }
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
    state.setStatus(if (ptr.*) label ++ " on" else label ++ " off");
}

// ── Export helpers ────────────────────────────────────────────────────────────

const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;

/// Export the active schematic. Always writes SVG first; if `converter` is
/// non-null, spawns it to produce the final format (PNG/PDF).
fn doExport(state: anytype, comptime ext: []const u8, converter: ?[]const []const u8) void {
    if (is_wasm) { state.setStatus("Export not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const base_path = switch (fio.origin) {
        .chn_file => |p| p,
        else => { state.setStatus("Save the schematic first"); return; },
    };
    const stem_end = std.mem.lastIndexOf(u8, base_path, ".") orelse base_path.len;

    // Always write the SVG intermediate.
    var svg_buf: [512]u8 = undefined;
    const svg_path = std.fmt.bufPrint(&svg_buf, "{s}.svg", .{base_path[0..stem_end]}) catch {
        state.setStatusErr("Path too long"); return;
    };
    writeSvgFile(&fio.sch, svg_path) catch {
        state.setStatusErr("SVG export failed"); return;
    };

    if (converter) |argv_prefix| {
        // Build: <converter...> <out_path> <svg_path>
        var out_buf: [512]u8 = undefined;
        const out_path = std.fmt.bufPrint(&out_buf, "{s}{s}", .{ base_path[0..stem_end], ext }) catch {
            state.setStatusErr("Path too long"); return;
        };
        var argv_storage: [8][]const u8 = undefined;
        var argc: usize = 0;
        for (argv_prefix) |a| {
            if (argc >= argv_storage.len) break;
            argv_storage[argc] = a;
            argc += 1;
        }
        if (argc < argv_storage.len) { argv_storage[argc] = out_path; argc += 1; }
        if (argc < argv_storage.len) { argv_storage[argc] = svg_path; argc += 1; }
        var child = std.process.Child.init(argv_storage[0..argc], state.allocator());
        child.spawn() catch {
            state.setStatus("Exported SVG (install rsvg-convert for " ++ ext ++ ")");
            return;
        };
        _ = child.wait() catch {};
        state.setStatus("Exported " ++ ext);
    } else {
        state.setStatus("Exported SVG");
    }
}

fn writeSvgFile(sch: anytype, path: []const u8) !void {
    const Vfs = @import("utility").Vfs;

    // Compute bounding box.
    var lo: @Vector(2, i32) = @splat(std.math.maxInt(i32));
    var hi: @Vector(2, i32) = @splat(std.math.minInt(i32));
    for (0..sch.wires.len) |i| {
        const wire = sch.wires.get(i);
        const ws = @Vector(2, i32){ wire.x0, wire.y0 };
        const we = @Vector(2, i32){ wire.x1, wire.y1 };
        lo = @min(lo, @min(ws, we));
        hi = @max(hi, @max(ws, we));
    }
    for (0..sch.instances.len) |i| {
        const inst = sch.instances.get(i);
        const ip = @Vector(2, i32){ inst.x, inst.y };
        lo = @min(lo, ip);
        hi = @max(hi, ip);
    }
    if (lo[0] > hi[0]) { lo = @splat(0); hi = @splat(100); }
    const margin: @Vector(2, i32) = @splat(50);
    lo -= margin;
    hi += margin;

    // Buffer the SVG into a growable list, then write via Vfs.
    const alloc = std.heap.page_allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    const w = out.writer(alloc);

    try w.print("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{d} {d} {d} {d}\">\n", .{ lo[0], lo[1], hi[0] - lo[0], hi[1] - lo[1] });
    try w.writeAll("<style>line.w{stroke:#58d2ff;stroke-width:2}text{font:10px monospace;fill:#ccc}rect.i{fill:none;stroke:#8cf;stroke-width:1}</style>\n");
    try w.writeAll("<rect width=\"100%\" height=\"100%\" fill=\"#16161c\"/>\n");

    for (0..sch.wires.len) |i| {
        const wire = sch.wires.get(i);
        try w.print("<line class=\"w\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ wire.x0, wire.y0, wire.x1, wire.y1 });
    }
    for (0..sch.instances.len) |i| {
        const inst = sch.instances.get(i);
        try w.print("<g><rect class=\"i\" x=\"{d}\" y=\"{d}\" width=\"30\" height=\"30\" rx=\"3\"/>", .{ inst.x - 15, inst.y - 15 });
        try w.print("<text x=\"{d}\" y=\"{d}\">{s}</text></g>\n", .{ inst.x - 12, inst.y + 3, inst.name });
    }
    try w.writeAll("</svg>\n");

    try Vfs.writeAll(path, out.items);
}
