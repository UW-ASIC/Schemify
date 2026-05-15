// writer.zig - XSchem .sch/.sym file serializer.

const std = @import("std");
const types = @import("../types.zig");
const utils = @import("utils.zig");

const XSchemFiles = types.XSchemFiles;
const Prop = types.Prop;
const PinDirection = types.PinDirection;
const pinDirectionToStr = types.pinDirectionToStr;

/// Serialize XSchemFiles to a .sch or .sym file and write to path.
pub fn writeFile(xs: *const XSchemFiles, path: []const u8) !void {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(null);
    const aa = buf.allocator();

    try serialize(xs, aa, &buf);

    try std.fs.cwd().writeFile(path, buf.items);
}

/// Serialize XSchemFiles to an allocated string.
pub fn serialize(xs: *const XSchemFiles, aa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
    // K block for symbols
    if (xs.file_type == .symbol) {
        try buf.appendSlice(aa, "K {");
        var first = true;
        if (xs.k_type) |t| {
            try buf.appendSlice(aa, "type=");
            try escapePropValue(aa, buf, t);
            first = false;
        }
        if (xs.k_format) |f| {
            if (!first) try buf.append(aa, ' ');
            try buf.appendSlice(aa, "format=");
            try escapePropValue(aa, buf, f);
            first = false;
        }
        if (xs.k_template) |tmpl| {
            if (!first) try buf.append(aa, ' ');
            try buf.appendSlice(aa, "template=");
            try escapePropValue(aa, buf, tmpl);
            first = false;
        }
        if (xs.k_extra) |ex| {
            if (!first) try buf.append(aa, ' ');
            try buf.appendSlice(aa, "extra=");
            try escapePropValue(aa, buf, ex);
            first = false;
        }
        if (xs.k_global) {
            if (!first) try buf.append(aa, ' ');
            try buf.appendSlice(aa, "global=true");
        }
        if (xs.k_spice_sym_def) |ssd| {
            if (!first) try buf.append(aa, ' ');
            try buf.appendSlice(aa, "spice_sym_def=");
            try escapePropValue(aa, buf, ssd);
        }
        try buf.appendSlice(aa, "}\n");
    }

    // S block for spice body
    if (xs.s_block) |sb| {
        try buf.appendSlice(aa, "S {");
        try buf.appendSlice(aa, sb);
        try buf.appendSlice(aa, "}\n");
    }

    // Lines
    const lines = xs.lines.slice();
    for (0..xs.lines.len) |i| {
        try buf.append(aa, 'L');
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtI32(aa, lines.items(.layer)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, lines.items(.x0)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, lines.items(.y0)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, lines.items(.x1)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, lines.items(.y1)[i]));
        try buf.appendSlice(aa, " {}\n");
    }

    // Rects
    const rects = xs.rects.slice();
    for (0..xs.rects.len) |i| {
        try buf.append(aa, 'B');
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtI32(aa, rects.items(.layer)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, rects.items(.x0)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, rects.items(.y0)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, rects.items(.x1)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, rects.items(.y1)[i]));
        if (rects.items(.layer)[i] == 5) {
            // Pin rect — emit pinnumber/name attrs
            try buf.appendSlice(aa, " {name=");
            // name would come from separate pin array; emit placeholder
            try buf.appendSlice(aa, "}");
        } else {
            try buf.appendSlice(aa, " {}");
        }
        try buf.append(aa, '\n');
    }

    // Arcs
    const arcs = xs.arcs.slice();
    for (0..xs.arcs.len) |i| {
        try buf.append(aa, 'A');
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtI32(aa, arcs.items(.layer)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, arcs.items(.cx)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, arcs.items(.cy)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, arcs.items(.radius)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, arcs.items(.start_angle)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, arcs.items(.sweep_angle)[i]));
        try buf.appendSlice(aa, " {}\n");
    }

    // Wires
    const wires = xs.wires.slice();
    for (0..xs.wires.len) |i| {
        try buf.append(aa, 'N');
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, wires.items(.x0)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, wires.items(.y0)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, wires.items(.x1)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, wires.items(.y1)[i]));
        if (wires.items(.net_name)[i]) |nn| {
            try buf.appendSlice(aa, " {lab=");
            try escapePropValue(aa, buf, nn);
            try buf.append(aa, '}');
        } else {
            try buf.appendSlice(aa, " {}");
        }
        try buf.append(aa, '\n');
    }

    // Texts
    const texts = xs.texts.slice();
    for (0..xs.texts.len) |i| {
        try buf.append(aa, 'T');
        try buf.append(aa, ' ');
        try buf.append(aa, '{');
        try escapeTextContent(aa, buf, texts.items(.content)[i]);
        try buf.append(aa, '}');
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, texts.items(.x)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, texts.items(.y)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtI32(aa, texts.items(.rotation)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, "0 "); // mirror
        try buf.appendSlice(aa, try fmtF64(aa, texts.items(.size)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, texts.items(.size)[i]));
        try buf.appendSlice(aa, " {layer=");
        try buf.appendSlice(aa, try fmtI32(aa, texts.items(.layer)[i]));
        try buf.append(aa, '}');
        try buf.append(aa, '\n');
    }

    // Pins (B 5 rects come from symbol pins — emit here for symbols)
    if (xs.file_type == .symbol) {
        const pins = xs.pins.slice();
        for (0..xs.pins.len) |i| {
            const px = pins.items(.x)[i];
            const py = pins.items(.y)[i];
            // Emit as B 5 (pin layer) rect at the pin position
            try buf.appendSlice(aa, "B 5 ");
            try buf.appendSlice(aa, try fmtF64(aa, px));
            try buf.append(aa, ' ');
            try buf.appendSlice(aa, try fmtF64(aa, py));
            try buf.append(aa, ' ');
            // Small rect around pin point
            const pin_size: f64 = 0.1;
            try buf.appendSlice(aa, try fmtF64(aa, px - pin_size));
            try buf.append(aa, ' ');
            try buf.appendSlice(aa, try fmtF64(aa, py - pin_size));
            try buf.appendSlice(aa, " {name=");
            try escapePropValue(aa, buf, pins.items(.name)[i]);
            try buf.appendSlice(aa, " dir=");
            try buf.appendSlice(aa, pinDirectionToStr(pins.items(.direction)[i]));
            if (pins.items(.number)[i]) |num| {
                try buf.appendSlice(aa, " pinnumber=");
                try buf.appendSlice(aa, try fmtU32(aa, num));
            }
            try buf.appendSlice(aa, "}\n");
        }
    }

    // Instances
    const instances = xs.instances.slice();
    for (0..xs.instances.len) |i| {
        try buf.append(aa, 'C');
        try buf.append(aa, ' ');
        try buf.append(aa, '{');
        try buf.appendSlice(aa, instances.items(.symbol)[i]);
        try buf.append(aa, '}');
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, instances.items(.x)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtF64(aa, instances.items(.y)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, try fmtI32(aa, instances.items(.rot)[i]));
        try buf.append(aa, ' ');
        try buf.appendSlice(aa, if (instances.items(.flip)[i]) "1" else "0");
        const ps = instances.items(.prop_start)[i];
        const pc = instances.items(.prop_count)[i];
        const inst_props = xs.props.items[ps..][0..pc];
        if (inst_props.len > 0) {
            try buf.append(aa, ' ');
            try buf.append(aa, '{');
            var first_prop = true;
            for (inst_props) |prop| {
                if (!first_prop) try buf.append(aa, ' ');
                first_prop = false;
                try buf.appendSlice(aa, prop.key);
                try buf.append(aa, '=');
                try escapePropValue(aa, buf, prop.value);
            }
            try buf.append(aa, '}');
        } else {
            try buf.appendSlice(aa, " {}");
        }
        try buf.append(aa, '\n');
    }
}

// ── Formatting helpers ──────────────────────────────────────────────────

fn fmtF64(aa: std.mem.Allocator, v: f64) ![]const u8 {
    return std.fmt.allocPrint(aa, "{d}", .{v});
}

fn fmtI32(aa: std.mem.Allocator, v: i32) ![]const u8 {
    return std.fmt.allocPrint(aa, "{d}", .{v});
}

fn fmtU32(aa: std.mem.Allocator, v: u32) ![]const u8 {
    return std.fmt.allocPrint(aa, "{d}", .{v});
}

/// Escape a property value for XSchem format.
fn escapePropValue(aa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    var needs_braces = false;
    for (value) |c| {
        if (c == ' ' or c == '\t' or c == '"' or c == '\\' or c == '{' or c == '}') {
            needs_braces = true;
            break;
        }
    }
    if (needs_braces) {
        try buf.append(aa, '{');
        for (value) |c| {
            if (c == '{' or c == '}' or c == '\\') try buf.append(aa, '\\');
            try buf.append(aa, c);
        }
        try buf.append(aa, '}');
    } else {
        try buf.appendSlice(aa, value);
    }
}

/// Escape text content for T {} block.
fn escapeTextContent(aa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), content: []const u8) !void {
    for (content) |c| {
        if (c == '{' or c == '}' or c == '\\') try buf.append(aa, '\\');
        try buf.append(aa, c);
    }
}
