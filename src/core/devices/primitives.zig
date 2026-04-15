const std = @import("std");

// ============================================================
// Comptime .chn_prim Parser
//
// Embeds every standard .chn_prim file via @embedFile, parses
// them at comptime, and exposes a flat table identical in shape
// to the old hand-written `device_table`.  Also parses the
// `drawing:` section so renderers can use the canonical symbol
// geometry instead of hard-coded segment tables.
// ============================================================

const MAX_PINS = 8;
const MAX_PARAMS = 16;
const MAX_SEGS = 48;
const MAX_CIRCLES = 8;
const MAX_ARCS = 8;
const MAX_RECTS = 4;
const MAX_PIN_POS = 8;
const MAX_PIN_NAME = 8;

// ── Drawing data types ──────────────────────────────────────────────────── //

/// A line segment in symbol-local coordinates.
pub const DrawSeg = struct { x0: i16, y0: i16, x1: i16, y1: i16 };

/// A circle in symbol-local coordinates.
pub const DrawCircle = struct { cx: i16, cy: i16, r: i16 };

/// An arc in symbol-local coordinates.
pub const DrawArc = struct { cx: i16, cy: i16, r: i16, start: i16, sweep: i16 };

/// A rectangle in symbol-local coordinates (top-left to bottom-right).
pub const DrawRect = struct { x0: i16, y0: i16, x1: i16, y1: i16 };

/// A pin's visual position on the symbol.
pub const PinPos = struct {
    name: [MAX_PIN_NAME]u8 = [_]u8{0} ** MAX_PIN_NAME,
    name_len: u8 = 0,
    x: i16 = 0,
    y: i16 = 0,

    pub fn nameSlice(self: *const PinPos) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// A single parsed primitive entry.  Uses fixed-capacity arrays so the struct
/// can live in comptime-const storage (no references to comptime var).
pub const PrimEntry = struct {
    kind_name: []const u8 = "",
    prefix: u8 = 0,
    pin_storage: [MAX_PINS][]const u8 = [_][]const u8{""} ** MAX_PINS,
    pin_count: usize = 0,
    param_storage: [MAX_PARAMS]ParamPair = [_]ParamPair{.{ .key = "", .val = "" }} ** MAX_PARAMS,
    param_count: usize = 0,
    model_keyword: ?[]const u8 = null,
    spice_format: ?[]const u8 = null,
    block_type: []const u8 = "",
    non_electrical: bool = false,
    injected_net: ?[]const u8 = null,

    // ── Drawing data ────────────────────────────────────────────────── //
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

    /// Return pins as a slice (at comptime or runtime).
    pub fn pins(self: *const PrimEntry) []const []const u8 {
        return self.pin_storage[0..self.pin_count];
    }

    /// Return params as a slice (at comptime or runtime).
    pub fn params(self: *const PrimEntry) []const ParamPair {
        return self.param_storage[0..self.param_count];
    }

    /// Return drawing line segments as a slice.
    pub fn segs(self: *const PrimEntry) []const DrawSeg {
        return self.segments[0..self.segment_count];
    }

    /// Return drawing circles as a slice.
    pub fn drawCircles(self: *const PrimEntry) []const DrawCircle {
        return self.circles[0..self.circle_count];
    }

    /// Return drawing arcs as a slice.
    pub fn drawArcs(self: *const PrimEntry) []const DrawArc {
        return self.arcs[0..self.arc_count];
    }

    /// Return drawing rects as a slice.
    pub fn drawRects(self: *const PrimEntry) []const DrawRect {
        return self.rects[0..self.rect_count];
    }

    /// Return pin positions as a slice.
    pub fn pinPositions(self: *const PrimEntry) []const PinPos {
        return self.pin_positions[0..self.pin_pos_count];
    }

    /// True if this primitive has any drawing data at all.
    pub fn hasDrawing(self: *const PrimEntry) bool {
        return self.segment_count > 0 or self.circle_count > 0 or
            self.arc_count > 0 or self.rect_count > 0;
    }
};

pub const ParamPair = struct {
    key: []const u8 = "",
    val: []const u8 = "",
};

// ============================================================
// Embedded .chn_prim sources
// ============================================================

const EmbeddedPrim = struct {
    file: []const u8,
    /// Extra metadata not present in the .chn_prim file itself,
    /// carried over from the old device_table.
    kind_override: ?[]const u8 = null,
    non_electrical: bool = false,
    injected_net: ?[]const u8 = null,
};

/// All standard primitives.  Order determines position in `parsed_prims`.
const embedded_files = [_]EmbeddedPrim{
    // ── Passives ──
    .{ .file = @embedFile("primitives/resistor.chn_prim") },
    .{ .file = @embedFile("primitives/resistor3.chn_prim") },
    .{ .file = @embedFile("primitives/capacitor.chn_prim") },
    .{ .file = @embedFile("primitives/inductor.chn_prim") },

    // ── Diodes ──
    .{ .file = @embedFile("primitives/diode.chn_prim") },
    .{ .file = @embedFile("primitives/zener.chn_prim") },

    // ── MOSFETs ──
    .{ .file = @embedFile("primitives/nmos3.chn_prim") },
    .{ .file = @embedFile("primitives/pmos3.chn_prim") },
    .{ .file = @embedFile("primitives/nmos.chn_prim"), .kind_override = "nmos4" },
    .{ .file = @embedFile("primitives/pmos.chn_prim"), .kind_override = "pmos4" },

    // ── BJTs ──
    .{ .file = @embedFile("primitives/npn.chn_prim") },
    .{ .file = @embedFile("primitives/pnp.chn_prim") },

    // ── JFETs ──
    .{ .file = @embedFile("primitives/njfet.chn_prim") },
    .{ .file = @embedFile("primitives/pjfet.chn_prim") },

    // ── Independent sources ──
    .{ .file = @embedFile("primitives/vsource.chn_prim") },
    .{ .file = @embedFile("primitives/isource.chn_prim") },
    .{ .file = @embedFile("primitives/ammeter.chn_prim") },
    .{ .file = @embedFile("primitives/behavioral.chn_prim") },

    // ── Controlled sources ──
    .{ .file = @embedFile("primitives/vcvs.chn_prim") },
    .{ .file = @embedFile("primitives/vccs.chn_prim") },
    .{ .file = @embedFile("primitives/ccvs.chn_prim") },
    .{ .file = @embedFile("primitives/cccs.chn_prim") },

    // ── Switches ──
    .{ .file = @embedFile("primitives/vswitch.chn_prim") },
    .{ .file = @embedFile("primitives/iswitch.chn_prim") },

    // ── Transmission line / coupling ──
    .{ .file = @embedFile("primitives/tline.chn_prim") },
    .{ .file = @embedFile("primitives/coupling.chn_prim") },

    // ── Non-electrical / UI ──
    .{ .file = @embedFile("primitives/gnd.chn_prim"), .non_electrical = true, .injected_net = "0" },
    .{ .file = @embedFile("primitives/vdd.chn_prim"), .non_electrical = true, .injected_net = "VDD" },
    .{ .file = @embedFile("primitives/lab_pin.chn_prim"), .non_electrical = true },
    .{ .file = @embedFile("primitives/input_pin.chn_prim"), .non_electrical = true },
    .{ .file = @embedFile("primitives/output_pin.chn_prim"), .non_electrical = true },
    .{ .file = @embedFile("primitives/inout_pin.chn_prim"), .non_electrical = true },
    .{ .file = @embedFile("primitives/probe.chn_prim"), .non_electrical = true },

    // ── Digital / HDL blocks ──
    .{ .file = @embedFile("primitives/digital_block.chn_prim") },
    .{ .file = @embedFile("primitives/verilog_a_block.chn_prim") },
    .{ .file = @embedFile("primitives/spice_block.chn_prim") },
};

// ============================================================
// Comptime parser helpers
// ============================================================

fn comptimeTrim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r')) start += 1;
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

fn comptimeStartsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.mem.eql(u8, haystack[0..needle.len], needle);
}

fn comptimeAfterPrefix(line: []const u8, pfx: []const u8) []const u8 {
    return comptimeTrim(line[pfx.len..]);
}

fn comptimeIndexOfScalar(s: []const u8, c: u8) ?usize {
    for (s, 0..) |ch, i| {
        if (ch == c) return i;
    }
    return null;
}

fn comptimeFirstToken(line: []const u8) []const u8 {
    var end: usize = 0;
    while (end < line.len and line[end] != ' ' and line[end] != '\t') end += 1;
    return line[0..end];
}

/// Measure leading spaces in a raw (untrimmed) line.
fn indentLevel(raw: []const u8) usize {
    var n: usize = 0;
    while (n < raw.len and raw[n] == ' ') n += 1;
    return n;
}

// ============================================================
// Comptime parser
// ============================================================

/// Parse a single .chn_prim file at comptime.
///
/// The .chn_prim format has this structure:
///   chn_prim 1.0              (0-indent)
///   SYMBOL name               (0-indent)
///     desc: ...               (2-indent, section-level)
///     pins [N]:               (2-indent, section keyword)
///       pin_name  dir         (4-indent, data item)
///     params [N]:             (2-indent, section keyword)
///       key = val             (4-indent, data item)
///     spice_prefix: X         (2-indent, section-level)
///     spice_format: ...       (2-indent, section-level)
///     drawing:                (2-indent, section keyword)
///       lines:                (4-indent, drawing sub-section)
///         (x0,y0) (x1,y1)    (6-indent, line data)
///       circle: (cx,cy) r=N  (4-indent, circle data)
///       arc: (cx,cy) r=N start=S sweep=W
///       rect: (x0,y0) (x1,y1)
///       text: (x,y) "label"
///       pin_positions:        (4-indent, pin position sub-section)
///         name: (x,y)        (6-indent, pin pos data)
///
/// Strategy: process trimmed lines as keywords first.  Only fall through
/// to data-item parsing if the line didn't match any keyword.
fn parsePrim(comptime src: []const u8, comptime meta: EmbeddedPrim) PrimEntry {
    @setEvalBranchQuota(500_000);
    var result: PrimEntry = .{
        .non_electrical = meta.non_electrical,
        .injected_net = meta.injected_net,
    };

    const State = enum { top, pins, params, drawing, drawing_lines, drawing_pin_pos };
    var state: State = .top;

    var pos: usize = 0;
    while (pos < src.len) {
        var eol = pos;
        while (eol < src.len and src[eol] != '\n') eol += 1;
        const raw = src[pos..eol];
        pos = if (eol < src.len) eol + 1 else eol;

        const line = comptimeTrim(raw);
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // ── Global keyword matching (any state) ──
        // These keywords always transition state, regardless of current state.
        if (comptimeStartsWith(line, "chn_prim")) {
            state = .top;
            continue;
        }
        if (comptimeStartsWith(line, "SYMBOL ")) {
            state = .top;
            const name = comptimeAfterPrefix(line, "SYMBOL ");
            result.kind_name = if (meta.kind_override) |ov| ov else name;
            continue;
        }
        if (comptimeStartsWith(line, "desc:")) {
            continue;
        }
        if (comptimeStartsWith(line, "pins ") or comptimeStartsWith(line, "pins[")) {
            state = .pins;
            continue;
        }
        if (comptimeStartsWith(line, "params ") or comptimeStartsWith(line, "params[")) {
            state = .params;
            continue;
        }
        if (comptimeStartsWith(line, "spice_prefix:")) {
            state = .top;
            const val = comptimeAfterPrefix(line, "spice_prefix:");
            if (val.len > 0) result.prefix = val[0];
            continue;
        }
        if (comptimeStartsWith(line, "spice_format:")) {
            state = .top;
            result.spice_format = comptimeAfterPrefix(line, "spice_format:");
            continue;
        }
        if (comptimeStartsWith(line, "block_type:")) {
            state = .top;
            result.block_type = comptimeAfterPrefix(line, "block_type:");
            continue;
        }
        if (comptimeStartsWith(line, "spice_lib:")) {
            state = .top;
            continue;
        }
        if (comptimeStartsWith(line, "drawing:")) {
            state = .drawing;
            continue;
        }

        // ── Drawing sub-section keywords ──
        // These only apply when already inside a drawing: section.
        if (state == .drawing or state == .drawing_lines or state == .drawing_pin_pos) {
            if (comptimeStartsWith(line, "lines:")) {
                state = .drawing_lines;
                continue;
            }
            if (comptimeStartsWith(line, "pin_positions:")) {
                state = .drawing_pin_pos;
                continue;
            }
            // Inline circle:  "circle: (cx,cy) r=N"
            if (comptimeStartsWith(line, "circle:")) {
                const rest = comptimeAfterPrefix(line, "circle:");
                if (parseCircle(rest)) |circ| {
                    if (result.circle_count < MAX_CIRCLES) {
                        result.circles[result.circle_count] = circ;
                        result.circle_count += 1;
                    }
                }
                state = .drawing;
                continue;
            }
            // Inline arc:  "arc: (cx,cy) r=N start=S sweep=W"
            if (comptimeStartsWith(line, "arc:")) {
                const rest = comptimeAfterPrefix(line, "arc:");
                if (parseArc(rest)) |arc| {
                    if (result.arc_count < MAX_ARCS) {
                        result.arcs[result.arc_count] = arc;
                        result.arc_count += 1;
                    }
                }
                state = .drawing;
                continue;
            }
            // Inline rect:  "rect: (x0,y0) (x1,y1)"
            if (comptimeStartsWith(line, "rect:")) {
                const rest = comptimeAfterPrefix(line, "rect:");
                if (parseTwoPoints(rest)) |pts| {
                    if (result.rect_count < MAX_RECTS) {
                        result.rects[result.rect_count] = .{
                            .x0 = pts[0],
                            .y0 = pts[1],
                            .x1 = pts[2],
                            .y1 = pts[3],
                        };
                        result.rect_count += 1;
                    }
                }
                state = .drawing;
                continue;
            }
            // Inline text:  "text: (x,y) ..." — skip (labels are runtime)
            if (comptimeStartsWith(line, "text:")) {
                state = .drawing;
                continue;
            }
        }

        // ── Data item parsing (state-dependent) ──
        switch (state) {
            .top, .drawing => {
                // Unknown line, skip
            },
            .pins => {
                const tok = comptimeFirstToken(line);
                if (tok.len > 0 and result.pin_count < MAX_PINS) {
                    result.pin_storage[result.pin_count] = tok;
                    result.pin_count += 1;
                }
            },
            .params => {
                if (comptimeIndexOfScalar(line, '=')) |eq| {
                    const key = comptimeTrim(line[0..eq]);
                    const val = comptimeTrim(line[eq + 1 ..]);
                    if (key.len > 0 and result.param_count < MAX_PARAMS) {
                        result.param_storage[result.param_count] = .{ .key = key, .val = val };
                        result.param_count += 1;
                    }
                }
            },
            .drawing_lines => {
                // Each line: "(x0,y0) (x1,y1)"
                if (parseTwoPoints(line)) |pts| {
                    if (result.segment_count < MAX_SEGS) {
                        result.segments[result.segment_count] = .{
                            .x0 = pts[0],
                            .y0 = pts[1],
                            .x1 = pts[2],
                            .y1 = pts[3],
                        };
                        result.segment_count += 1;
                    }
                }
            },
            .drawing_pin_pos => {
                // Each line: "name: (x,y)"
                if (comptimeIndexOfScalar(line, ':')) |colon| {
                    const name = comptimeTrim(line[0..colon]);
                    const rest = comptimeTrim(line[colon + 1 ..]);
                    if (parseOnePoint(rest)) |pt| {
                        if (result.pin_pos_count < MAX_PIN_POS and name.len > 0) {
                            var pp: PinPos = .{ .x = pt[0], .y = pt[1] };
                            const copy_len = @min(name.len, MAX_PIN_NAME);
                            for (0..copy_len) |ci| {
                                pp.name[ci] = name[ci];
                            }
                            pp.name_len = @intCast(copy_len);
                            result.pin_positions[result.pin_pos_count] = pp;
                            result.pin_pos_count += 1;
                        }
                    }
                }
            },
        }
    }

    // Derive model_keyword from the "model" param default value if present
    for (result.param_storage[0..result.param_count]) |p| {
        if (std.mem.eql(u8, p.key, "model")) {
            result.model_keyword = p.val;
            break;
        }
    }

    return result;
}

// ============================================================
// Drawing coordinate parsers (all comptime)
// ============================================================

/// Parse a signed integer from the string at `s[start..]`, returning the
/// value and the position just past the last digit.
fn comptimeParseI16(s: []const u8, start: usize) ?struct { val: i16, end: usize } {
    var i = start;
    // Skip whitespace
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i >= s.len) return null;

    var neg: bool = false;
    if (s[i] == '-') {
        neg = true;
        i += 1;
    } else if (s[i] == '+') {
        i += 1;
    }
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;

    var val: i32 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') {
        val = val * 10 + (s[i] - '0');
        i += 1;
    }
    if (neg) val = -val;
    return .{ .val = @intCast(val), .end = i };
}

/// Parse "(x,y)" returning [2]i16 or null.
fn parseOnePoint(s: []const u8) ?[2]i16 {
    // Find opening paren
    var i: usize = 0;
    while (i < s.len and s[i] != '(') i += 1;
    if (i >= s.len) return null;
    i += 1; // skip '('

    const xr = comptimeParseI16(s, i) orelse return null;
    i = xr.end;
    // Skip comma
    while (i < s.len and (s[i] == ',' or s[i] == ' ')) i += 1;
    const yr = comptimeParseI16(s, i) orelse return null;

    return .{ xr.val, yr.val };
}

/// Parse "(x0,y0) (x1,y1)" returning [4]i16 or null.
fn parseTwoPoints(s: []const u8) ?[4]i16 {
    // Find first '('
    var i: usize = 0;
    while (i < s.len and s[i] != '(') i += 1;
    if (i >= s.len) return null;
    i += 1;

    const x0r = comptimeParseI16(s, i) orelse return null;
    i = x0r.end;
    while (i < s.len and (s[i] == ',' or s[i] == ' ')) i += 1;
    const y0r = comptimeParseI16(s, i) orelse return null;
    i = y0r.end;

    // Find second '('
    while (i < s.len and s[i] != '(') i += 1;
    if (i >= s.len) return null;
    i += 1;

    const x1r = comptimeParseI16(s, i) orelse return null;
    i = x1r.end;
    while (i < s.len and (s[i] == ',' or s[i] == ' ')) i += 1;
    const y1r = comptimeParseI16(s, i) orelse return null;

    return .{ x0r.val, y0r.val, x1r.val, y1r.val };
}

/// Parse "circle: (cx,cy) r=N"
fn parseCircle(s: []const u8) ?DrawCircle {
    const pt = parseOnePoint(s) orelse return null;
    // Find "r=" or "r ="
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == 'r' and (i + 1 < s.len and s[i + 1] == '=')) {
            const rv = comptimeParseI16(s, i + 2) orelse return null;
            return .{ .cx = pt[0], .cy = pt[1], .r = rv.val };
        }
        if (s[i] == 'r' and (i + 1 < s.len and s[i + 1] == ' ')) {
            // Try "r = N"
            var j = i + 1;
            while (j < s.len and s[j] == ' ') j += 1;
            if (j < s.len and s[j] == '=') {
                const rv = comptimeParseI16(s, j + 1) orelse return null;
                return .{ .cx = pt[0], .cy = pt[1], .r = rv.val };
            }
        }
    }
    return null;
}

/// Parse "arc: (cx,cy) r=N start=S sweep=W"
fn parseArc(s: []const u8) ?DrawArc {
    const pt = parseOnePoint(s) orelse return null;
    const r_val = findNamedI16(s, "r=") orelse return null;
    const start_val = findNamedI16(s, "start=") orelse return null;
    const sweep_val = findNamedI16(s, "sweep=") orelse return null;
    return .{ .cx = pt[0], .cy = pt[1], .r = r_val, .start = start_val, .sweep = sweep_val };
}

/// Find "key=value" in a string, parsing value as i16.
fn findNamedI16(s: []const u8, key: []const u8) ?i16 {
    var i: usize = 0;
    while (i + key.len <= s.len) : (i += 1) {
        if (std.mem.eql(u8, s[i..][0..key.len], key)) {
            const rv = comptimeParseI16(s, i + key.len) orelse return null;
            return rv.val;
        }
    }
    return null;
}

/// The fully parsed primitives table, built at comptime from .chn_prim files.
pub const parsed_prims: [embedded_files.len]PrimEntry = blk: {
    @setEvalBranchQuota(20_000_000);
    var table: [embedded_files.len]PrimEntry = undefined;
    for (embedded_files, 0..) |ef, i| {
        table[i] = parsePrim(ef.file, ef);
    }
    break :blk table;
};

/// Number of primitives parsed from .chn_prim files.
pub const prim_count = embedded_files.len;

/// Look up a PrimEntry by its kind_name (comptime version).  Returns null if not found.
pub fn findByName(comptime name: []const u8) ?*const PrimEntry {
    for (&parsed_prims) |*p| {
        if (std.mem.eql(u8, p.kind_name, name)) return p;
    }
    return null;
}

/// Look up a PrimEntry by kind_name at runtime.  Returns null if not found.
pub fn findByNameRuntime(name: []const u8) ?*const PrimEntry {
    for (&parsed_prims) |*p| {
        if (std.mem.eql(u8, p.kind_name, name)) return p;
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

test "parsed_prims count" {
    try std.testing.expectEqual(@as(usize, 36), prim_count);
}

test "nmos4 parsed correctly" {
    const nmos = findByName("nmos4") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u8, 'M'), nmos.prefix);
    try std.testing.expectEqual(@as(usize, 4), nmos.pin_count);
    const p = nmos.pins();
    try std.testing.expectEqualStrings("d", p[0]);
    try std.testing.expectEqualStrings("g", p[1]);
    try std.testing.expectEqualStrings("s", p[2]);
    try std.testing.expectEqualStrings("b", p[3]);
    try std.testing.expect(nmos.model_keyword != null);
    try std.testing.expectEqualStrings("nch", nmos.model_keyword.?);
    try std.testing.expect(!nmos.non_electrical);
}

test "resistor parsed correctly" {
    const r = findByName("resistor") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u8, 'R'), r.prefix);
    try std.testing.expectEqual(@as(usize, 2), r.pin_count);
    const p = r.pins();
    try std.testing.expectEqualStrings("p", p[0]);
    try std.testing.expectEqualStrings("n", p[1]);
    try std.testing.expect(r.model_keyword == null);
}

test "gnd is non-electrical with injected net" {
    const g = findByName("gnd") orelse return error.NotFound;
    try std.testing.expect(g.non_electrical);
    try std.testing.expect(g.injected_net != null);
    try std.testing.expectEqualStrings("0", g.injected_net.?);
    try std.testing.expectEqual(@as(u8, 0), g.prefix);
}

test "vcvs has 4 pins" {
    const e = findByName("vcvs") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u8, 'E'), e.prefix);
    try std.testing.expectEqual(@as(usize, 4), e.pin_count);
}

test "coupling has 0 pins" {
    const k = findByName("coupling") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u8, 'K'), k.prefix);
    try std.testing.expectEqual(@as(usize, 0), k.pin_count);
}

test "all prims have kind_name set" {
    for (&parsed_prims) |*p| {
        try std.testing.expect(p.kind_name.len > 0);
    }
}

// ── Drawing data tests ──────────────────────────────────────────────── //

test "resistor has drawing segments" {
    const r = findByName("resistor") orelse return error.NotFound;
    // resistor.chn_prim has 11 lines in drawing
    try std.testing.expect(r.segment_count >= 7);
    try std.testing.expect(r.hasDrawing());

    // First segment is the top lead: (0,-30) (0,-20)
    const s0 = r.segs()[0];
    try std.testing.expectEqual(@as(i16, 0), s0.x0);
    try std.testing.expectEqual(@as(i16, -30), s0.y0);
    try std.testing.expectEqual(@as(i16, 0), s0.x1);
    try std.testing.expectEqual(@as(i16, -20), s0.y1);

    // Pin positions
    try std.testing.expectEqual(@as(u8, 2), r.pin_pos_count);
    const pp = r.pinPositions();
    try std.testing.expectEqualStrings("p", pp[0].nameSlice());
    try std.testing.expectEqual(@as(i16, 0), pp[0].x);
    try std.testing.expectEqual(@as(i16, -30), pp[0].y);
    try std.testing.expectEqualStrings("n", pp[1].nameSlice());
    try std.testing.expectEqual(@as(i16, 0), pp[1].x);
    try std.testing.expectEqual(@as(i16, 30), pp[1].y);
}

test "vsource has circle" {
    const v = findByName("vsource") orelse return error.NotFound;
    try std.testing.expect(v.circle_count >= 1);
    const c = v.drawCircles()[0];
    try std.testing.expectEqual(@as(i16, 0), c.cx);
    try std.testing.expectEqual(@as(i16, 0), c.cy);
    try std.testing.expectEqual(@as(i16, 15), c.r);
}

test "inductor has arcs" {
    const l = findByName("inductor") orelse return error.NotFound;
    try std.testing.expect(l.arc_count >= 3);
    const a0 = l.drawArcs()[0];
    try std.testing.expectEqual(@as(i16, 0), a0.cx);
    try std.testing.expectEqual(@as(i16, -15), a0.cy);
    try std.testing.expectEqual(@as(i16, 8), a0.r);
    try std.testing.expectEqual(@as(i16, 90), a0.start);
    try std.testing.expectEqual(@as(i16, 180), a0.sweep);
}

test "behavioral has rect" {
    const b = findByName("behavioral") orelse return error.NotFound;
    try std.testing.expect(b.rect_count >= 1);
    const r0 = b.drawRects()[0];
    try std.testing.expectEqual(@as(i16, -12), r0.x0);
    try std.testing.expectEqual(@as(i16, -15), r0.y0);
    try std.testing.expectEqual(@as(i16, 12), r0.x1);
    try std.testing.expectEqual(@as(i16, 15), r0.y1);
}

test "nmos4 has drawing data with 4 pin positions" {
    const nmos = findByName("nmos4") orelse return error.NotFound;
    try std.testing.expect(nmos.hasDrawing());
    try std.testing.expect(nmos.segment_count >= 9);
    try std.testing.expectEqual(@as(u8, 4), nmos.pin_pos_count);
}

test "gnd has drawing segments and 1 pin position" {
    const g = findByName("gnd") orelse return error.NotFound;
    try std.testing.expect(g.hasDrawing());
    try std.testing.expectEqual(@as(u8, 1), g.pin_pos_count);
    try std.testing.expectEqualStrings("gnd", g.pinPositions()[0].nameSlice());
}

test "all prims with drawing have segments or circles or arcs or rects" {
    // Every primitive should have at least some drawing data
    for (&parsed_prims) |*p| {
        try std.testing.expect(p.hasDrawing());
    }
}

test "input_pin has 6 segments and 1 pin position" {
    const p = findByName("input_pin") orelse return error.NotFound;
    try std.testing.expect(p.non_electrical);
    try std.testing.expectEqual(@as(u8, 6), p.segment_count);
    try std.testing.expectEqual(@as(u8, 1), p.pin_pos_count);
    try std.testing.expectEqualStrings("p", p.pinPositions()[0].nameSlice());
    try std.testing.expectEqual(@as(i16, 0), p.pinPositions()[0].x);
    try std.testing.expectEqual(@as(i16, 0), p.pinPositions()[0].y);
}

test "output_pin has 6 segments and 1 pin position" {
    const p = findByName("output_pin") orelse return error.NotFound;
    try std.testing.expect(p.non_electrical);
    try std.testing.expectEqual(@as(u8, 6), p.segment_count);
    try std.testing.expectEqual(@as(u8, 1), p.pin_pos_count);
}

test "inout_pin has 7 segments and 1 pin position" {
    const p = findByName("inout_pin") orelse return error.NotFound;
    try std.testing.expect(p.non_electrical);
    try std.testing.expectEqual(@as(u8, 7), p.segment_count);
    try std.testing.expectEqual(@as(u8, 1), p.pin_pos_count);
}

test "lab_pin has 5 segments, 1 circle, and 1 pin position" {
    const p = findByName("lab_pin") orelse return error.NotFound;
    try std.testing.expect(p.non_electrical);
    try std.testing.expectEqual(@as(u8, 5), p.segment_count);
    try std.testing.expectEqual(@as(u8, 1), p.circle_count);
    try std.testing.expectEqual(@as(u8, 1), p.pin_pos_count);
}

test "digital_block has block_type digital" {
    const db = findByName("digital_block") orelse return error.NotFound;
    try std.testing.expectEqualStrings("digital", db.block_type);
}

test "verilog_a_block has block_type verilog_a" {
    const va = findByName("verilog_a_block") orelse return error.NotFound;
    try std.testing.expectEqualStrings("verilog_a", va.block_type);
}

test "spice_block has block_type lib" {
    const sb = findByName("spice_block") orelse return error.NotFound;
    try std.testing.expectEqualStrings("lib", sb.block_type);
}

test "existing primitives have empty block_type" {
    const r = findByName("resistor") orelse return error.NotFound;
    try std.testing.expectEqualStrings("", r.block_type);
    const nmos = findByName("nmos4") orelse return error.NotFound;
    try std.testing.expectEqualStrings("", nmos.block_type);
}
