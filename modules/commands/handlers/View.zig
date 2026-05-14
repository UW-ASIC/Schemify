const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const types = @import("../types.zig");
const Immediate = types.Immediate;

// ── Bounding box / vector helpers ────────────────────────────────────────────

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

inline fn selInst(fio: anytype, i: usize) bool {
    return i < fio.selection.instances.bit_length and fio.selection.instances.isSet(i);
}

inline fn selWire(fio: anytype, i: usize) bool {
    return i < fio.selection.wires.bit_length and fio.selection.wires.isSet(i);
}

inline fn toggleFlag(state: anytype, comptime field: []const u8, comptime label: []const u8) void {
    const ptr = &@field(state.cmd_flags, field);
    ptr.* = !ptr.*;
    state.setStatus(if (ptr.*) label ++ " on" else label ++ " off");
}

// ── Public handler ───────────────────────────────────────────────────────────

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

// ── Private helpers ──────────────────────────────────────────────────────────

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

// ── SVG export ───────────────────────────────────────────────────────────────

fn exportSvgFile(sch: anytype, path: []const u8) !void {
    const schematic = @import("schematic");
    const primitives = schematic.devices.primitives;
    const file = try @import("utility").platform.fs.cwd().createFile(path, .{});
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

    // Wire junction dots.
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
            const sd = if (i < sch.sym_data.items.len) sch.sym_data.items[i] else @import("schematic").types.SymData{};
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

    for (entry.segs()) |seg| {
        const a = svgRotFlip(seg.x0, seg.y0, rot, flip);
        const b = svgRotFlip(seg.x1, seg.y1, rot, flip);
        len = (std.fmt.bufPrint(buf, "<line class=\"sym\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ ox + a[0], oy + a[1], ox + b[0], oy + b[1] }) catch buf).len;
        try file.writeAll(buf[0..len]);
    }

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

    for (entry.drawCircles()) |circ| {
        const c = svgRotFlip(circ.cx, circ.cy, rot, flip);
        len = (std.fmt.bufPrint(buf, "<circle class=\"sym\" cx=\"{d}\" cy=\"{d}\" r=\"{d}\"/>\n", .{ ox + c[0], oy + c[1], circ.r }) catch buf).len;
        try file.writeAll(buf[0..len]);
    }

    for (entry.drawArcs()) |arc| {
        const c = svgRotFlip(arc.cx, arc.cy, rot, flip);
        try svgWriteArc(ox + c[0], oy + c[1], arc.r, arc.start, arc.sweep, rot, flip, file, buf);
    }

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
        const corners = [4][2]i32{ .{ -half_w, -half_h }, .{ half_w, -half_h }, .{ half_w, half_h }, .{ -half_w, half_h } };
        for (0..4) |ci| {
            const a = svgRotFlip(corners[ci][0], corners[ci][1], rot, flip);
            const b = svgRotFlip(corners[(ci + 1) % 4][0], corners[(ci + 1) % 4][1], rot, flip);
            len = (std.fmt.bufPrint(buf, "<line class=\"box\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ ox + a[0], oy + a[1], ox + b[0], oy + b[1] }) catch buf).len;
            try file.writeAll(buf[0..len]);
        }
        return;
    }

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
    var buf: [128]u8 = undefined;
    const wires_len = sch.wires.len;
    if (wires_len < 2) return;

    const wx0 = sch.wires.items(.x0);
    const wy0 = sch.wires.items(.y0);
    const wx1 = sch.wires.items(.x1);
    const wy1 = sch.wires.items(.y1);

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
