//! primitives.zig — Comptime .chn_prim parser
//!
//! Embeds every standard .chn_prim file via @embedFile, parses them at
//! comptime, and exposes a flat table of PrimEntry structs with geometry
//! + pin positions for built-in symbols (resistor, capacitor, etc.).

const std = @import("std");

const MAX_PINS = 8;
const MAX_PARAMS = 16;
const MAX_SEGS = 48;
const MAX_CIRCLES = 8;
const MAX_ARCS = 8;
const MAX_RECTS = 4;
const MAX_PIN_POS = 8;
const MAX_PIN_NAME = 8;

// ── Drawing data types ──────────────────────────────────────────────────── //

pub const DrawSeg = struct { x0: i16, y0: i16, x1: i16, y1: i16 };
pub const DrawCircle = struct { cx: i16, cy: i16, r: i16 };
pub const DrawArc = struct { cx: i16, cy: i16, r: i16, start: i16, sweep: i16 };
pub const DrawRect = struct { x0: i16, y0: i16, x1: i16, y1: i16 };

pub const PinPos = struct {
    name: [MAX_PIN_NAME]u8 = [_]u8{0} ** MAX_PIN_NAME,
    name_len: u8 = 0,
    x: i16 = 0,
    y: i16 = 0,

    pub fn nameSlice(self: *const PinPos) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const ParamPair = struct { key: []const u8 = "", val: []const u8 = "" };

pub const PrimEntry = struct {
    kind_name: []const u8 = "",
    prefix: u8 = 0,
    pin_storage: [MAX_PINS][]const u8 = [_][]const u8{""} ** MAX_PINS,
    pin_count: usize = 0,
    param_storage: [MAX_PARAMS]ParamPair = [_]ParamPair{.{}} ** MAX_PARAMS,
    param_count: usize = 0,
    model_keyword: ?[]const u8 = null,
    spice_format: ?[]const u8 = null,
    block_type: []const u8 = "",
    non_electrical: bool = false,
    injected_net: ?[]const u8 = null,

    segments: [MAX_SEGS]DrawSeg = [_]DrawSeg{.{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 }} ** MAX_SEGS,
    segment_count: u8 = 0,
    circles: [MAX_CIRCLES]DrawCircle = [_]DrawCircle{.{ .cx = 0, .cy = 0, .r = 0 }} ** MAX_CIRCLES,
    circle_count: u8 = 0,
    arcs: [MAX_ARCS]DrawArc = [_]DrawArc{.{ .cx = 0, .cy = 0, .r = 0, .start = 0, .sweep = 0 }} ** MAX_ARCS,
    arc_count: u8 = 0,
    rects: [MAX_RECTS]DrawRect = [_]DrawRect{.{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 }} ** MAX_RECTS,
    rect_count: u8 = 0,
    pin_positions: [MAX_PIN_POS]PinPos = [_]PinPos{.{}} ** MAX_PIN_POS,
    pin_pos_count: u8 = 0,

    pub fn pins(self: *const PrimEntry) []const []const u8 { return self.pin_storage[0..self.pin_count]; }
    pub fn params(self: *const PrimEntry) []const ParamPair { return self.param_storage[0..self.param_count]; }
    pub fn segs(self: *const PrimEntry) []const DrawSeg { return self.segments[0..self.segment_count]; }
    pub fn drawCircles(self: *const PrimEntry) []const DrawCircle { return self.circles[0..self.circle_count]; }
    pub fn drawArcs(self: *const PrimEntry) []const DrawArc { return self.arcs[0..self.arc_count]; }
    pub fn drawRects(self: *const PrimEntry) []const DrawRect { return self.rects[0..self.rect_count]; }
    pub fn pinPositions(self: *const PrimEntry) []const PinPos { return self.pin_positions[0..self.pin_pos_count]; }
    pub fn hasDrawing(self: *const PrimEntry) bool {
        return self.segment_count > 0 or self.circle_count > 0 or self.arc_count > 0 or self.rect_count > 0;
    }
};

// ── Embedded .chn_prim sources ──────────────────────────────────────────── //

const EmbeddedPrim = struct {
    file: []const u8,
    kind_override: ?[]const u8 = null,
    non_electrical: bool = false,
    injected_net: ?[]const u8 = null,
};

const embedded_files = [_]EmbeddedPrim{
    // Passives
    .{ .file = @embedFile("primitives/resistor.chn_prim") },
    .{ .file = @embedFile("primitives/resistor3.chn_prim") },
    .{ .file = @embedFile("primitives/capacitor.chn_prim") },
    .{ .file = @embedFile("primitives/inductor.chn_prim") },
    // Diodes
    .{ .file = @embedFile("primitives/diode.chn_prim") },
    .{ .file = @embedFile("primitives/zener.chn_prim") },
    // MOSFETs
    .{ .file = @embedFile("primitives/nmos3.chn_prim") },
    .{ .file = @embedFile("primitives/pmos3.chn_prim") },
    .{ .file = @embedFile("primitives/nmos.chn_prim"), .kind_override = "nmos4" },
    .{ .file = @embedFile("primitives/pmos.chn_prim"), .kind_override = "pmos4" },
    // BJTs
    .{ .file = @embedFile("primitives/npn.chn_prim") },
    .{ .file = @embedFile("primitives/pnp.chn_prim") },
    // JFETs
    .{ .file = @embedFile("primitives/njfet.chn_prim") },
    .{ .file = @embedFile("primitives/pjfet.chn_prim") },
    // Independent sources
    .{ .file = @embedFile("primitives/vsource.chn_prim") },
    .{ .file = @embedFile("primitives/isource.chn_prim") },
    .{ .file = @embedFile("primitives/ammeter.chn_prim") },
    .{ .file = @embedFile("primitives/behavioral.chn_prim") },
    // Controlled sources
    .{ .file = @embedFile("primitives/vcvs.chn_prim") },
    .{ .file = @embedFile("primitives/vccs.chn_prim") },
    .{ .file = @embedFile("primitives/ccvs.chn_prim") },
    .{ .file = @embedFile("primitives/cccs.chn_prim") },
    // Switches
    .{ .file = @embedFile("primitives/vswitch.chn_prim") },
    .{ .file = @embedFile("primitives/iswitch.chn_prim") },
    // Transmission line / coupling
    .{ .file = @embedFile("primitives/tline.chn_prim") },
    .{ .file = @embedFile("primitives/coupling.chn_prim") },
    // Non-electrical / UI
    .{ .file = @embedFile("primitives/gnd.chn_prim"), .non_electrical = true, .injected_net = "0" },
    .{ .file = @embedFile("primitives/vdd.chn_prim"), .non_electrical = true, .injected_net = "VDD" },
    .{ .file = @embedFile("primitives/lab_pin.chn_prim"), .non_electrical = true },
    .{ .file = @embedFile("primitives/input_pin.chn_prim"), .non_electrical = true },
    .{ .file = @embedFile("primitives/output_pin.chn_prim"), .non_electrical = true },
    .{ .file = @embedFile("primitives/inout_pin.chn_prim"), .non_electrical = true },
    .{ .file = @embedFile("primitives/probe.chn_prim"), .non_electrical = true },
    // Digital / HDL blocks
    .{ .file = @embedFile("primitives/digital_block.chn_prim") },
    .{ .file = @embedFile("primitives/verilog_a_block.chn_prim") },
    .{ .file = @embedFile("primitives/spice_block.chn_prim") },
};

// ── Comptime parser helpers ─────────────────────────────────────────────── //

fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r')) a += 1;
    var b: usize = s.len;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\r')) b -= 1;
    return s[a..b];
}
fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.mem.eql(u8, haystack[0..needle.len], needle);
}
fn afterPrefix(line: []const u8, pfx: []const u8) []const u8 { return trim(line[pfx.len..]); }
fn firstToken(line: []const u8) []const u8 {
    var e: usize = 0;
    while (e < line.len and line[e] != ' ' and line[e] != '\t') e += 1;
    return line[0..e];
}
fn indexOf(s: []const u8, c: u8) ?usize {
    for (s, 0..) |ch, i| if (ch == c) return i;
    return null;
}

// ── Coordinate parsers ──────────────────────────────────────────────────── //

fn parseI16(s: []const u8, start: usize) ?struct { val: i16, end: usize } {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i >= s.len) return null;
    var neg = false;
    if (s[i] == '-') { neg = true; i += 1; } else if (s[i] == '+') i += 1;
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
    var v: i32 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') { v = v * 10 + (s[i] - '0'); i += 1; }
    if (neg) v = -v;
    return .{ .val = @intCast(v), .end = i };
}

fn parseOnePoint(s: []const u8) ?[2]i16 {
    var i: usize = 0;
    while (i < s.len and s[i] != '(') i += 1;
    if (i >= s.len) return null;
    i += 1;
    const xr = parseI16(s, i) orelse return null;
    i = xr.end;
    while (i < s.len and (s[i] == ',' or s[i] == ' ')) i += 1;
    const yr = parseI16(s, i) orelse return null;
    return .{ xr.val, yr.val };
}

fn parseTwoPoints(s: []const u8) ?[4]i16 {
    var i: usize = 0;
    while (i < s.len and s[i] != '(') i += 1;
    if (i >= s.len) return null;
    i += 1;
    const x0 = parseI16(s, i) orelse return null; i = x0.end;
    while (i < s.len and (s[i] == ',' or s[i] == ' ')) i += 1;
    const y0 = parseI16(s, i) orelse return null; i = y0.end;
    while (i < s.len and s[i] != '(') i += 1;
    if (i >= s.len) return null;
    i += 1;
    const x1 = parseI16(s, i) orelse return null; i = x1.end;
    while (i < s.len and (s[i] == ',' or s[i] == ' ')) i += 1;
    const y1 = parseI16(s, i) orelse return null;
    return .{ x0.val, y0.val, x1.val, y1.val };
}

fn findNamedI16(s: []const u8, key: []const u8) ?i16 {
    var i: usize = 0;
    while (i + key.len <= s.len) : (i += 1) {
        if (std.mem.eql(u8, s[i..][0..key.len], key)) {
            const rv = parseI16(s, i + key.len) orelse return null;
            return rv.val;
        }
    }
    return null;
}

fn parseCircle(s: []const u8) ?DrawCircle {
    const pt = parseOnePoint(s) orelse return null;
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == 'r' and i + 1 < s.len and s[i + 1] == '=') {
            const rv = parseI16(s, i + 2) orelse return null;
            return .{ .cx = pt[0], .cy = pt[1], .r = rv.val };
        }
        if (s[i] == 'r' and i + 1 < s.len and s[i + 1] == ' ') {
            var j = i + 1;
            while (j < s.len and s[j] == ' ') j += 1;
            if (j < s.len and s[j] == '=') {
                const rv = parseI16(s, j + 1) orelse return null;
                return .{ .cx = pt[0], .cy = pt[1], .r = rv.val };
            }
        }
    }
    return null;
}

fn parseArc(s: []const u8) ?DrawArc {
    const pt = parseOnePoint(s) orelse return null;
    return .{
        .cx = pt[0], .cy = pt[1],
        .r = findNamedI16(s, "r=") orelse return null,
        .start = findNamedI16(s, "start=") orelse return null,
        .sweep = findNamedI16(s, "sweep=") orelse return null,
    };
}

// ── Main comptime parser ────────────────────────────────────────────────── //

fn parsePrim(comptime src: []const u8, comptime meta: EmbeddedPrim) PrimEntry {
    @setEvalBranchQuota(500_000);
    var r: PrimEntry = .{ .non_electrical = meta.non_electrical, .injected_net = meta.injected_net };
    const State = enum { top, pins, params, drawing, drawing_lines, drawing_pin_pos };
    var state: State = .top;
    var pos: usize = 0;

    while (pos < src.len) {
        var eol = pos;
        while (eol < src.len and src[eol] != '\n') eol += 1;
        const raw = src[pos..eol];
        pos = if (eol < src.len) eol + 1 else eol;
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;

        // Global keyword transitions
        if (startsWith(line, "chn_prim")) { state = .top; continue; }
        if (startsWith(line, "SYMBOL ")) { state = .top; r.kind_name = if (meta.kind_override) |ov| ov else afterPrefix(line, "SYMBOL "); continue; }
        if (startsWith(line, "desc:")) continue;
        if (startsWith(line, "pins ") or startsWith(line, "pins[")) { state = .pins; continue; }
        if (startsWith(line, "params ") or startsWith(line, "params[")) { state = .params; continue; }
        if (startsWith(line, "spice_prefix:")) { state = .top; const v = afterPrefix(line, "spice_prefix:"); if (v.len > 0) r.prefix = v[0]; continue; }
        if (startsWith(line, "spice_format:")) { state = .top; r.spice_format = afterPrefix(line, "spice_format:"); continue; }
        if (startsWith(line, "block_type:")) { state = .top; r.block_type = afterPrefix(line, "block_type:"); continue; }
        if (startsWith(line, "spice_lib:")) { state = .top; continue; }
        if (startsWith(line, "drawing:")) { state = .drawing; continue; }

        // Drawing sub-section keywords
        if (state == .drawing or state == .drawing_lines or state == .drawing_pin_pos) {
            if (startsWith(line, "lines:")) { state = .drawing_lines; continue; }
            if (startsWith(line, "pin_positions:")) { state = .drawing_pin_pos; continue; }
            if (startsWith(line, "circle:")) {
                if (parseCircle(afterPrefix(line, "circle:"))) |circ| if (r.circle_count < MAX_CIRCLES) { r.circles[r.circle_count] = circ; r.circle_count += 1; };
                state = .drawing; continue;
            }
            if (startsWith(line, "arc:")) {
                if (parseArc(afterPrefix(line, "arc:"))) |arc| if (r.arc_count < MAX_ARCS) { r.arcs[r.arc_count] = arc; r.arc_count += 1; };
                state = .drawing; continue;
            }
            if (startsWith(line, "rect:")) {
                if (parseTwoPoints(afterPrefix(line, "rect:"))) |pts| if (r.rect_count < MAX_RECTS) { r.rects[r.rect_count] = .{ .x0 = pts[0], .y0 = pts[1], .x1 = pts[2], .y1 = pts[3] }; r.rect_count += 1; };
                state = .drawing; continue;
            }
            if (startsWith(line, "text:")) { state = .drawing; continue; }
        }

        // Data item parsing
        switch (state) {
            .top, .drawing => {},
            .pins => {
                const tok = firstToken(line);
                if (tok.len > 0 and r.pin_count < MAX_PINS) { r.pin_storage[r.pin_count] = tok; r.pin_count += 1; }
            },
            .params => {
                if (indexOf(line, '=')) |eq| {
                    const k = trim(line[0..eq]);
                    const v = trim(line[eq + 1 ..]);
                    if (k.len > 0 and r.param_count < MAX_PARAMS) { r.param_storage[r.param_count] = .{ .key = k, .val = v }; r.param_count += 1; }
                }
            },
            .drawing_lines => {
                if (parseTwoPoints(line)) |pts| if (r.segment_count < MAX_SEGS) { r.segments[r.segment_count] = .{ .x0 = pts[0], .y0 = pts[1], .x1 = pts[2], .y1 = pts[3] }; r.segment_count += 1; };
            },
            .drawing_pin_pos => {
                if (indexOf(line, ':')) |colon| {
                    const name = trim(line[0..colon]);
                    if (parseOnePoint(trim(line[colon + 1 ..]))) |pt| {
                        if (r.pin_pos_count < MAX_PIN_POS and name.len > 0) {
                            var pp: PinPos = .{ .x = pt[0], .y = pt[1] };
                            const cl = @min(name.len, MAX_PIN_NAME);
                            for (0..cl) |ci| pp.name[ci] = name[ci];
                            pp.name_len = @intCast(cl);
                            r.pin_positions[r.pin_pos_count] = pp;
                            r.pin_pos_count += 1;
                        }
                    }
                }
            },
        }
    }

    // Derive model_keyword from "model" param
    for (r.param_storage[0..r.param_count]) |p| {
        if (std.mem.eql(u8, p.key, "model")) { r.model_keyword = p.val; break; }
    }
    return r;
}

// ── Public comptime table ───────────────────────────────────────────────── //

pub const parsed_prims: [embedded_files.len]PrimEntry = blk: {
    @setEvalBranchQuota(20_000_000);
    var table: [embedded_files.len]PrimEntry = undefined;
    for (embedded_files, 0..) |ef, i| table[i] = parsePrim(ef.file, ef);
    break :blk table;
};

pub const prim_count = embedded_files.len;

pub fn findByName(comptime name: []const u8) ?*const PrimEntry {
    for (&parsed_prims) |*p| if (std.mem.eql(u8, p.kind_name, name)) return p;
    return null;
}

pub fn findByNameRuntime(name: []const u8) ?*const PrimEntry {
    for (&parsed_prims) |*p| if (std.mem.eql(u8, p.kind_name, name)) return p;
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────── //

test "parsed_prims count" {
    try std.testing.expectEqual(@as(usize, 36), prim_count);
}

test "nmos4 parsed correctly" {
    const nmos = findByName("nmos4") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u8, 'M'), nmos.prefix);
    try std.testing.expectEqual(@as(usize, 4), nmos.pin_count);
    try std.testing.expectEqualStrings("d", nmos.pins()[0]);
    try std.testing.expect(nmos.model_keyword != null);
    try std.testing.expectEqualStrings("nch", nmos.model_keyword.?);
}

test "resistor parsed correctly" {
    const r = findByName("resistor") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u8, 'R'), r.prefix);
    try std.testing.expectEqual(@as(usize, 2), r.pin_count);
    try std.testing.expectEqualStrings("p", r.pins()[0]);
}

test "gnd is non-electrical with injected net" {
    const g = findByName("gnd") orelse return error.NotFound;
    try std.testing.expect(g.non_electrical);
    try std.testing.expectEqualStrings("0", g.injected_net.?);
}

test "resistor has drawing segments" {
    const r = findByName("resistor") orelse return error.NotFound;
    try std.testing.expect(r.segment_count >= 7);
    try std.testing.expect(r.hasDrawing());
    try std.testing.expectEqual(@as(u8, 2), r.pin_pos_count);
}

test "all prims have kind_name set" {
    for (&parsed_prims) |*p| try std.testing.expect(p.kind_name.len > 0);
}

test "all prims have drawing" {
    for (&parsed_prims) |*p| try std.testing.expect(p.hasDrawing());
}
