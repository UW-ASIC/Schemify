// reader.zig - XSchem .sch/.sym file parser with tag-dispatch line parsing.
//
// Parses all element types (L, B, P, A, T, N, C) into the DOD Schematic.
// K-block properties (type, format, template) extracted for .sym files.
// Multi-line blocks handled via brace_depth tracking.
// Strict error returns on malformed input per D-06.
// Written from scratch per D-01.

const std = @import("std");
const types = @import("types.zig");
const props_mod = @import("props.zig");

const XSchemFiles = types.XSchemFiles;
const ParseError = types.ParseError;

/// Parse an XSchem .sch or .sym file from raw bytes into an XSchemFiles.
/// All allocations go into the XSchemFiles arena.
pub fn parse(backing: std.mem.Allocator, data: []const u8) ParseError!XSchemFiles {
    var schem = XSchemFiles.init(backing);
    errdefer schem.deinit();
    const arena = schem.arena.allocator();
    var brace_depth: i32 = 0;
    var accum: std.ArrayListUnmanaged(u8) = .{};
    var pending_tag: u8 = 0;

    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |raw_line| {
        const line = trimCr(raw_line);
        // Multi-line continuation: accumulate until braces balance.
        if (brace_depth > 0) {
            accum.appendSlice(arena, line) catch return error.MalformedComponent;
            accum.append(arena, '\n') catch return error.MalformedComponent;
            brace_depth += countBraces(line);
            if (brace_depth <= 0) {
                brace_depth = 0;
                const full = accum.items;
                switch (pending_tag) {
                    'v', 'V', 'E' => {},
                    'S' => parseSBlock(arena, full, &schem),
                    'G' => parseGBlock(arena, full, &schem) catch return error.MalformedComponent,
                    'K' => parseKBlock(arena, full, &schem) catch return error.MalformedComponent,
                    'C' => parseComponent(arena, full, &schem) catch return error.MalformedComponent,
                    'T' => parseText(arena, full, &schem) catch return error.MalformedText,
                    'N' => parseWire(arena, full, &schem) catch return error.MalformedWire,
                    'B' => try parseRect(arena, full, &schem),
                    'L' => try parseLineShape(arena, full, &schem),
                    'A' => try parseArc(arena, full, &schem),
                    'P' => {}, // Polygons deferred
                    'F' => {},
                    else => return error.UnknownElementTag,
                }
                accum.clearRetainingCapacity();
                pending_tag = 0;
            }
            continue;
        }
        if (line.len == 0 or line[0] == '*') continue;
        // Check for unbalanced braces (multi-line block start).
        const braces = countBraces(line);
        if (braces > 0) {
            brace_depth = braces;
            pending_tag = line[0];
            accum.clearRetainingCapacity();
            accum.appendSlice(arena, line) catch return error.MalformedComponent;
            accum.append(arena, '\n') catch return error.MalformedComponent;
            continue;
        }
        try dispatchLine(arena, line, &schem);
    }
    return schem;
}

// ── Line dispatch ───────────────────────────────────────────────────────

fn dispatchLine(arena: std.mem.Allocator, line: []const u8, schem: *XSchemFiles) ParseError!void {
    if (line.len == 0) return;
    switch (line[0]) {
        'v', 'V', 'E', '*', 'F' => {},
        'S' => parseSBlock(arena, line, schem),
        'G' => parseGBlock(arena, line, schem) catch return error.MalformedComponent,
        'K' => parseKBlock(arena, line, schem) catch return error.MalformedComponent,
        'L' => try parseLineShape(arena, line, schem),
        'B' => try parseRect(arena, line, schem),
        'P' => {}, // Polygons deferred to Phase 4
        'A' => try parseArc(arena, line, schem),
        'T' => parseText(arena, line, schem) catch return error.MalformedText,
        'N' => try parseWire(arena, line, schem),
        'C' => parseComponent(arena, line, schem) catch return error.MalformedComponent,
        else => return error.UnknownElementTag,
    }
}

// ── Element parsers ─────────────────────────────────────────────────────

/// Parse L: `L layer x0 y0 x1 y1 {attrs}`
fn parseLineShape(arena: std.mem.Allocator, line: []const u8, schem: *XSchemFiles) ParseError!void {
    var tok = tokenize(line);
    _ = tok.next(); // skip 'L'
    const layer = parseI32(tok.next()) orelse return error.MalformedLine;
    const x0 = parseF64(tok.next()) orelse return error.MalformedLine;
    const y0 = parseF64(tok.next()) orelse return error.MalformedLine;
    const x1 = parseF64(tok.next()) orelse return error.MalformedLine;
    const y1 = parseF64(tok.next()) orelse return error.MalformedLine;
    schem.lines.append(arena, .{ .layer = layer, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }) catch
        return error.MalformedLine;
}

/// Parse B: `B layer x0 y0 x1 y1 {attrs}` -- layer 5 = pin
fn parseRect(arena: std.mem.Allocator, line: []const u8, schem: *XSchemFiles) ParseError!void {
    var tok = tokenize(line);
    _ = tok.next();
    const layer = parseI32(tok.next()) orelse return error.MalformedRect;
    const x0 = parseF64(tok.next()) orelse return error.MalformedRect;
    const y0 = parseF64(tok.next()) orelse return error.MalformedRect;
    const x1 = parseF64(tok.next()) orelse return error.MalformedRect;
    const y1 = parseF64(tok.next()) orelse return error.MalformedRect;
    schem.rects.append(arena, .{ .layer = layer, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }) catch
        return error.MalformedRect;
    if (layer == 5) {
        const attrs = extractBraceContent(line);
        var pin_name: []const u8 = "";
        var pin_dir: types.PinDirection = .inout;
        var pin_number: ?u32 = null;
        if (attrs.len > 0) {
            var ptok = props_mod.PropertyTokenizer.init(attrs);
            while (ptok.next()) |prop| {
                if (std.mem.eql(u8, prop.key, "name") and pin_name.len == 0)
                    pin_name = arena.dupe(u8, prop.value) catch return error.MalformedRect
                else if (std.mem.eql(u8, prop.key, "dir"))
                    pin_dir = types.pinDirectionFromStr(prop.value)
                else if (std.mem.eql(u8, prop.key, "pinnumber"))
                    pin_number = std.fmt.parseInt(u32, prop.value, 10) catch null;
            }
        }
        schem.pins.append(arena, .{
            .name = if (pin_name.len > 0) pin_name else arena.dupe(u8, "") catch return error.MalformedRect,
            .x = (x0 + x1) / 2.0, .y = (y0 + y1) / 2.0,
            .direction = pin_dir, .number = pin_number,
        }) catch return error.MalformedRect;
    }
}

/// Parse A: `A layer cx cy radius start sweep {attrs}`
fn parseArc(arena: std.mem.Allocator, line: []const u8, schem: *XSchemFiles) ParseError!void {
    var tok = tokenize(line);
    _ = tok.next();
    const layer = parseI32(tok.next()) orelse return error.MalformedArc;
    const cx = parseF64(tok.next()) orelse return error.MalformedArc;
    const cy = parseF64(tok.next()) orelse return error.MalformedArc;
    const radius = parseF64(tok.next()) orelse return error.MalformedArc;
    const start = parseF64(tok.next()) orelse return error.MalformedArc;
    const sweep = parseF64(tok.next()) orelse return error.MalformedArc;
    schem.arcs.append(arena, .{
        .layer = layer, .cx = cx, .cy = cy,
        .radius = radius, .start_angle = start, .sweep_angle = sweep,
    }) catch return error.MalformedArc;
}

/// Parse T: `T {content} x y rot mirror hsize vsize {attrs}`
fn parseText(arena: std.mem.Allocator, line: []const u8, schem: *XSchemFiles) ParseError!void {
    const after_t = if (line.len > 2) line[2..] else return error.MalformedText;
    const cs = std.mem.indexOfScalar(u8, after_t, '{') orelse return error.MalformedText;
    const ce = findMatchingBrace(after_t, cs) orelse return error.MalformedText;
    const content = after_t[cs + 1 .. ce];
    const rest = if (ce + 1 < after_t.len) std.mem.trimLeft(u8, after_t[ce + 1 ..], " \t") else "";
    var tok_rest = std.mem.tokenizeAny(u8, rest, " \t");
    const x = parseF64(tok_rest.next()) orelse 0;
    const y = parseF64(tok_rest.next()) orelse 0;
    const rot = parseI32(tok_rest.next()) orelse 0;
    _ = tok_rest.next(); // mirror
    const hsize = parseF64(tok_rest.next()) orelse 0.4;
    _ = tok_rest.next(); // vsize
    var layer: i32 = 4;
    const trailing_attrs = extractBraceContent(rest);
    if (trailing_attrs.len > 0) {
        var ptok = props_mod.PropertyTokenizer.init(trailing_attrs);
        while (ptok.next()) |prop| {
            if (std.mem.eql(u8, prop.key, "layer"))
                layer = std.fmt.parseInt(i32, prop.value, 10) catch 4;
        }
    }
    schem.texts.append(arena, .{
        .content = arena.dupe(u8, content) catch return error.MalformedText,
        .x = x, .y = y, .layer = layer, .size = hsize, .rotation = rot,
    }) catch return error.MalformedText;
}

/// Parse N: `N x0 y0 x1 y1 {attrs}` -- extracts lab= as net_name
fn parseWire(arena: std.mem.Allocator, line: []const u8, schem: *XSchemFiles) ParseError!void {
    var tok = tokenize(line);
    _ = tok.next();
    const x0 = parseF64(tok.next()) orelse return error.MalformedWire;
    const y0 = parseF64(tok.next()) orelse return error.MalformedWire;
    const x1 = parseF64(tok.next()) orelse return error.MalformedWire;
    const y1 = parseF64(tok.next()) orelse return error.MalformedWire;
    var net_name: ?[]const u8 = null;
    const attrs = extractBraceContent(line);
    if (attrs.len > 0) {
        var ptok = props_mod.PropertyTokenizer.init(attrs);
        while (ptok.next()) |prop| {
            if (std.mem.eql(u8, prop.key, "lab")) {
                // XSchem uses '#' prefix for private/auto-generated net names;
                // strip it for SPICE netlist output (e.g. #net1 → net1).
                const lab_raw = prop.value;
                const lab_clean = if (lab_raw.len > 0 and lab_raw[0] == '#') lab_raw[1..] else lab_raw;
                net_name = arena.dupe(u8, lab_clean) catch return error.MalformedWire;
            }
        }
    }
    schem.wires.append(arena, .{
        .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .net_name = net_name,
    }) catch return error.MalformedWire;
}

/// Parse C: `C {symbol} x y rot flip {attrs}` -- props indexed via prop_start/count
fn parseComponent(arena: std.mem.Allocator, line: []const u8, schem: *XSchemFiles) ParseError!void {
    const after_c = if (line.len > 2) line[2..] else return error.MalformedComponent;
    const ss = std.mem.indexOfScalar(u8, after_c, '{') orelse return error.MalformedComponent;
    const se = std.mem.indexOfScalar(u8, after_c[ss + 1 ..], '}') orelse return error.MalformedComponent;
    const symbol = arena.dupe(u8, after_c[ss + 1 .. ss + 1 + se]) catch return error.MalformedComponent;
    const rs = ss + 1 + se + 1;
    const rest = if (rs < after_c.len) std.mem.trimLeft(u8, after_c[rs..], " \t") else "";
    var tok_rest = std.mem.tokenizeAny(u8, rest, " \t\n");
    const x = parseF64(tok_rest.next()) orelse return error.MalformedComponent;
    const y = parseF64(tok_rest.next()) orelse return error.MalformedComponent;
    const rot = parseI32(tok_rest.next()) orelse 0;
    const flip_val = parseI32(tok_rest.next()) orelse 0;
    const prop_start: u32 = @intCast(schem.props.items.len);
    const attrs = extractBraceContent(rest);
    var prop_count: u16 = 0;
    var inst_name: []const u8 = "";
    if (attrs.len > 0) {
        const result = props_mod.parseProps(arena, attrs) catch return error.MalformedComponent;
        for (result.props) |prop| schem.props.append(arena, prop) catch return error.MalformedComponent;
        prop_count = result.count;
        for (result.props) |prop| {
            if (std.mem.eql(u8, prop.key, "name")) { inst_name = prop.value; break; }
        }
    }
    schem.instances.append(arena, .{
        .name = if (inst_name.len > 0) inst_name else arena.dupe(u8, "") catch return error.MalformedComponent,
        .symbol = symbol, .x = x, .y = y, .rot = rot, .flip = flip_val != 0,
        .prop_start = prop_start, .prop_count = prop_count,
    }) catch return error.MalformedComponent;
}

/// Parse G block (old format) -- may contain type/format/template.
fn parseGBlock(arena: std.mem.Allocator, line: []const u8, schem: *XSchemFiles) !void {
    const content = extractBraceContent(line);
    if (content.len == 0) return;
    parseSymbolProperties(arena, content, schem);
}

/// Parse K block -- sets file_type=.symbol, extracts type/format/template/extra.
fn parseKBlock(arena: std.mem.Allocator, line: []const u8, schem: *XSchemFiles) !void {
    const content = extractBraceContent(line);
    if (content.len == 0) return;
    schem.file_type = .symbol;
    parseSymbolProperties(arena, content, schem);
}

/// Parse S block — raw SPICE body.  Stores the trimmed content in s_block.
fn parseSBlock(arena: std.mem.Allocator, line: []const u8, schem: *XSchemFiles) void {
    const content = extractBraceContent(line);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return;
    schem.s_block = arena.dupe(u8, trimmed) catch null;
}

/// Extract type, format, template, extra from a symbol property block.
fn parseSymbolProperties(arena: std.mem.Allocator, content: []const u8, schem: *XSchemFiles) void {
    var ptok = props_mod.PropertyTokenizer.init(content);
    while (ptok.next()) |prop| {
        if (std.mem.eql(u8, prop.key, "type")) {
            schem.k_type = arena.dupe(u8, prop.value) catch null;
            if (schem.k_type != null) schem.file_type = .symbol;
        } else if (std.mem.eql(u8, prop.key, "format"))
            schem.k_format = arena.dupe(u8, prop.value) catch null
        else if (std.mem.eql(u8, prop.key, "template"))
            schem.k_template = arena.dupe(u8, prop.value) catch null
        else if (std.mem.eql(u8, prop.key, "extra"))
            schem.k_extra = arena.dupe(u8, prop.value) catch null
        else if (std.mem.eql(u8, prop.key, "global"))
            schem.k_global = std.mem.eql(u8, prop.value, "true")
        else if (std.mem.eql(u8, prop.key, "spice_sym_def"))
            schem.k_spice_sym_def = arena.dupe(u8, prop.value) catch null;
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn trimCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn countBraces(line: []const u8) i32 {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) { i += 1; continue; }
        if (line[i] == '{') depth += 1;
        if (line[i] == '}') depth -= 1;
    }
    return depth;
}

fn extractBraceContent(s: []const u8) []const u8 {
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return "";
    const end = std.mem.lastIndexOfScalar(u8, s, '}') orelse return "";
    return if (end > start) s[start + 1 .. end] else "";
}

fn findMatchingBrace(s: []const u8, open_pos: usize) ?usize {
    var depth: i32 = 0;
    var i = open_pos;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) { i += 1; continue; }
        if (s[i] == '{') depth += 1;
        if (s[i] == '}') { depth -= 1; if (depth == 0) return i; }
    }
    return null;
}

fn tokenize(line: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, line, " \t");
}

fn parseF64(token: ?[]const u8) ?f64 {
    const t = token orelse return null;
    const clean = if (std.mem.indexOfScalar(u8, t, '{')) |idx| t[0..idx] else t;
    return if (clean.len == 0) null else std.fmt.parseFloat(f64, clean) catch null;
}

fn parseI32(token: ?[]const u8) ?i32 {
    const t = token orelse return null;
    const clean = if (std.mem.indexOfScalar(u8, t, '{')) |idx| t[0..idx] else t;
    return if (clean.len == 0) null else std.fmt.parseInt(i32, clean, 10) catch null;
}
