//! Export handlers — SVG, PNG, PDF, Verilog output.

const std = @import("std");
const core = @import("core");
const h = @import("helpers.zig");
const is_wasm = h.is_wasm;

pub const ExportFormat = enum { png, pdf };

/// Unified export helper for SVG, PNG, and PDF.
/// When `convert` is null the SVG is the final output; otherwise an intermediate
/// SVG is written to a temp file, converted via `convertSvg`, then cleaned up.
pub fn exportAs(state: anytype, comptime ext: []const u8, convert: ?ExportFormat) void {
    if (is_wasm) { state.setStatus("Export not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const path: []const u8 = switch (fio.origin) {
        .chn_file => |p| p,
        else => { state.setStatus("Save the file first to export " ++ comptime toUpper(ext)); return; },
    };
    var out_buf: [512]u8 = undefined;
    const stem_end = std.mem.lastIndexOf(u8, path, ".") orelse path.len;
    const out_path = std.fmt.bufPrint(&out_buf, "{s}." ++ ext, .{path[0..stem_end]}) catch {
        state.setStatus("Path too long for " ++ comptime toUpper(ext) ++ " export");
        return;
    };
    if (convert) |fmt| {
        // Need intermediate SVG for conversion.
        var tmp_buf: [512]u8 = undefined;
        const tmp_svg = std.fmt.bufPrint(&tmp_buf, "{s}._export_tmp.svg", .{path[0..stem_end]}) catch {
            state.setStatus("Path too long for " ++ comptime toUpper(ext) ++ " export");
            return;
        };
        exportSvgFile(&fio.sch, tmp_svg) catch {
            state.setStatus(comptime toUpper(ext) ++ " export failed (SVG generation)");
            return;
        };
        defer std.fs.cwd().deleteFile(tmp_svg) catch {};
        if (!convertSvg(state.allocator(), tmp_svg, out_path, fmt)) {
            state.setStatus(comptime toUpper(ext) ++ " export failed \xe2\x80\x94 install rsvg-convert or inkscape");
            return;
        }
    } else {
        // Direct SVG export.
        exportSvgFile(&fio.sch, out_path) catch {
            state.setStatus(comptime toUpper(ext) ++ " export failed");
            return;
        };
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Exported: {s}", .{out_path}) catch comptime toUpper(ext) ++ " exported";
    state.setStatusBuf(msg);
}

pub fn exportVerilog(state: anytype) void {
    if (is_wasm) { state.setStatus("Export not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const path: []const u8 = switch (fio.origin) {
        .chn_file => |p| p,
        else => { state.setStatus("Save the file first to export Verilog"); return; },
    };
    var path_buf: [512]u8 = undefined;
    const stem_end = std.mem.lastIndexOf(u8, path, ".") orelse path.len;
    const v_path = std.fmt.bufPrint(&path_buf, "{s}.v", .{path[0..stem_end]}) catch {
        state.setStatus("Path too long for Verilog export");
        return;
    };
    const verilog = fio.sch.emitVerilog(state.allocator()) catch {
        state.setStatus("Verilog netlist generation failed");
        return;
    };
    defer state.allocator().free(verilog);
    const file = std.fs.cwd().createFile(v_path, .{}) catch {
        state.setStatus("Cannot create Verilog file");
        return;
    };
    defer file.close();
    file.writeAll(verilog) catch {
        state.setStatus("Verilog write failed");
        return;
    };
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Exported: {s}", .{v_path}) catch "Verilog exported";
    state.setStatusBuf(msg);
}

fn toUpper(comptime s: []const u8) []const u8 {
    comptime {
        var buf: [s.len]u8 = undefined;
        for (s, 0..) |c, i| {
            buf[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        const result = buf;
        return &result;
    }
}

/// Convert an SVG file to PNG or PDF via external tools.
/// Tries rsvg-convert first, then falls back to inkscape.
/// Returns true on success, false if no converter is available.
fn convertSvg(alloc: std.mem.Allocator, svg_path: []const u8, output_path: []const u8, format: ExportFormat) bool {
    const fmt_flag: []const u8 = switch (format) { .png => "png", .pdf => "pdf" };

    // Try rsvg-convert first.
    {
        var argv_buf: [8][]const u8 = undefined;
        var argc: usize = 0;
        const base: [4][]const u8 = .{ "rsvg-convert", "-f", fmt_flag, "-o" };
        for (base) |a| { argv_buf[argc] = a; argc += 1; }
        if (format == .png) { argv_buf[argc] = "-d"; argc += 1; argv_buf[argc] = "300"; argc += 1; }
        argv_buf[argc] = output_path; argc += 1;
        argv_buf[argc] = svg_path; argc += 1;
        var child = std.process.Child.init(argv_buf[0..argc], alloc);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {
            // rsvg-convert not found, try inkscape below.
            return convertSvgInkscape(alloc, svg_path, output_path, fmt_flag, format);
        };
        const term = child.wait() catch {
            return convertSvgInkscape(alloc, svg_path, output_path, fmt_flag, format);
        };
        if (term == .Exited and term.Exited == 0) return true;
        // Non-zero exit, try inkscape.
        return convertSvgInkscape(alloc, svg_path, output_path, fmt_flag, format);
    }
}

fn convertSvgInkscape(alloc: std.mem.Allocator, svg_path: []const u8, output_path: []const u8, fmt_flag: []const u8, format: ExportFormat) bool {
    var argv_buf: [7][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "inkscape"; argc += 1;
    argv_buf[argc] = svg_path; argc += 1;
    argv_buf[argc] = "--export-type"; argc += 1;  // inkscape 1.x uses = but also accepts space
    argv_buf[argc] = fmt_flag; argc += 1;
    argv_buf[argc] = "--export-filename"; argc += 1;
    argv_buf[argc] = output_path; argc += 1;
    if (format == .png) { argv_buf[argc] = "--export-dpi=300"; argc += 1; }
    var child = std.process.Child.init(argv_buf[0..argc], alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return term == .Exited and term.Exited == 0;
}

fn exportSvgFile(sch: anytype, path: []const u8) !void {
    const primitives = core.devices.primitives;
    const file = try std.fs.cwd().createFile(path, .{});
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
