const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const sch = @import("Schemify.zig");
const Schemify = sch.Schemify;
const PinDir = sch.PinDir;
const HdlLanguage = sch.HdlLanguage;
const Devices = @import("Devices.zig");
const utility = @import("utility");
const simd = utility.simd;

pub const Reader = struct {
    pub fn readCHN(data: []const u8, backing: Allocator, logger: ?*utility.Logger) Schemify {
        var s = Schemify.init(backing);
        s.logger = logger;
        parseCHNImpl(&s, data);
        return s;
    }
};

// =============================================================================
// CHN v2 format parser (Arch.md spec)
// =============================================================================

/// Indent level of a line (number of leading 2-space pairs).
fn indentLevel(line: []const u8) u32 {
    var spaces: u32 = 0;
    for (line) |c| {
        if (c == ' ') spaces += 1 else break;
    }
    return spaces / 2;
}

/// Strip leading whitespace and trailing \r from a raw line.
fn trimLine(raw: []const u8) []const u8 {
    return std.mem.trimRight(u8, raw, " \t\r");
}

/// Parse the v2 file header and determine type. Returns the file type.
fn parseV2Header(hdr: []const u8) sch.SifyType {
    if (std.mem.startsWith(u8, hdr, "chn_testbench ")) return .testbench;
    if (std.mem.startsWith(u8, hdr, "chn_prim ")) return .primitive;
    return .component; // "chn 1.0"
}

/// Map a type-group name (e.g. "nmos", "pmos", "capacitors", "resistor") to a DeviceKind.
/// Falls back to .subckt for unknown type names (they reference .chn subcircuits).
fn typeGroupToKind(name: []const u8) Devices.DeviceKind {
    // Try direct enum match first (handles "nmos4", "pmos4", "resistor", etc.)
    const direct = Devices.DeviceKind.fromStr(name);
    if (direct != .unknown) return direct;

    // Plural/alias mappings from the Arch.md convention
    const Mapping = struct { key: []const u8, val: Devices.DeviceKind };
    const aliases = [_]Mapping{
        .{ .key = "nmos", .val = .nmos4 },
        .{ .key = "pmos", .val = .pmos4 },
        .{ .key = "capacitors", .val = .capacitor },
        .{ .key = "resistors", .val = .resistor },
        .{ .key = "inductors", .val = .inductor },
        .{ .key = "diodes", .val = .diode },
    };
    for (&aliases) |m| {
        if (std.mem.eql(u8, name, m.key)) return m.val;
    }
    return .subckt;
}

/// Extract the count N from a "[N]" or "[N]{...}" header token.
/// e.g. "[4]{name, w, l}:" -> 4, "[7]:" -> 7
fn parseCountFromBracket(tok: []const u8) ?u32 {
    if (tok.len < 3 or tok[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, tok, ']') orelse return null;
    return std.fmt.parseInt(u32, tok[1..close], 10) catch null;
}

/// Extract column names from a "{col1, col2, ...}:" header portion.
/// Returns a slice of column name slices. Caller owns nothing (views into input).
fn parseColumnNames(a: Allocator, header_rest: []const u8) ?[]const []const u8 {
    const open = std.mem.indexOfScalar(u8, header_rest, '{') orelse return null;
    const close = std.mem.indexOfScalar(u8, header_rest, '}') orelse return null;
    if (close <= open) return null;
    const cols_str = header_rest[open + 1 .. close];
    var cols = List([]const u8){};
    var col_it = std.mem.tokenizeAny(u8, cols_str, ", \t");
    while (col_it.next()) |col| {
        cols.append(a, col) catch return null;
    }
    return cols.toOwnedSlice(a) catch null;
}

/// Main v2 parse entry point.
fn parseCHNImpl(s: *Schemify, input: []const u8) void {
    const a = s.alloc();
    var it = simd.LineIterator.init(input);
    var tagged_conns = List(TaggedConn){};

    // Parse file header
    const hdr_raw = it.next() orelse return;
    const hdr = std.mem.trim(u8, hdr_raw, " \t\r");
    s.stype = parseV2Header(hdr);

    // Validate version
    var hdr_tok = std.mem.tokenizeAny(u8, hdr, " \t");
    _ = hdr_tok.next(); // skip "chn" / "chn_prim" / "chn_testbench"
    const ver = hdr_tok.next() orelse "";
    if (!std.mem.eql(u8, ver, "1.0")) {
        s.emit(.warn, "unsupported chn v2 version: {s}", .{ver});
    }

    // State machine for top-level sections
    const V2Section = enum { none, symbol, schematic, testbench };
    var section: V2Section = .none;

    // Sub-section state within SYMBOL/SCHEMATIC/TESTBENCH
    const SubSection = enum {
        none,
        pins,
        params,
        type_table,
        instances_kv,
        nets,
        wires,
        generate,
        annotations,
        drawing,
        drawing_lines,
        includes,
        analyses,
        measures,
        ann_op_points,
        ann_measures,
        ann_notes,
        ann_voltages,
        pin_positions,
        digital,
        digital_behavioral,
        digital_synthesized,
        digital_inline_source,
        digital_supply_map,
    };
    var subsection: SubSection = .none;

    // Annotation sub-section state
    var ann_op_cols: ?[]const []const u8 = null;
    var ann_note_idx: u32 = 0;

    // Digital section state
    var digital_inline_buf = List(u8){};
    var digital_indent_base: u32 = 0;

    // Type-table state
    var table_type_name: []const u8 = "";
    var table_kind: Devices.DeviceKind = .unknown;
    var table_cols: ?[]const []const u8 = null;
    var table_remaining: u32 = 0;

    // Generate state
    var gen_var: []const u8 = "";
    var gen_start: i32 = 0;
    var gen_end: i32 = 0;
    var gen_lines = List([]const u8){};

    while (it.next()) |raw| {
        const full_line = trimLine(raw);
        if (full_line.len == 0) continue;

        // Strip comments (but not inside strings — simple approach: only strip if # is preceded by whitespace or is at start)
        const line = blk: {
            var i: usize = 0;
            while (i < full_line.len) : (i += 1) {
                if (full_line[i] == '#' and (i == 0 or full_line[i - 1] == ' ' or full_line[i - 1] == '\t')) {
                    break :blk std.mem.trimRight(u8, full_line[0..i], " \t");
                }
            }
            break :blk full_line;
        };
        if (line.len == 0) continue;

        const indent = indentLevel(line);
        const trimmed = std.mem.trimLeft(u8, line, " ");

        // Top-level section markers (indent 0, ALL-CAPS)
        if (indent == 0) {
            // Reset sub-section state
            subsection = .none;
            table_cols = null;
            table_remaining = 0;

            // Flush any pending generate block
            if (gen_lines.items.len > 0) {
                flushGenerate(a, s, gen_var, gen_start, gen_end, gen_lines.items, &tagged_conns);
                gen_lines.items.len = 0;
            }

            if (std.mem.startsWith(u8, trimmed, "SYMBOL")) {
                section = .symbol;
                // Extract symbol name
                const rest = std.mem.trim(u8, trimmed[6..], " \t");
                if (rest.len > 0) {
                    s.name = a.dupe(u8, rest) catch "";
                }
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "SCHEMATIC")) {
                section = .schematic;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "TESTBENCH")) {
                section = .testbench;
                // Extract testbench name
                const rest = std.mem.trim(u8, trimmed[9..], " \t");
                if (rest.len > 0) {
                    s.name = a.dupe(u8, rest) catch "";
                }
                continue;
            }
            continue;
        }

        // Inside a generate block: collect lines for later expansion
        if (subsection == .generate and indent >= 2) {
            gen_lines.append(a, a.dupe(u8, line) catch continue) catch {};
            continue;
        }

        // Inside pin_positions sub-section of drawing
        if (subsection == .pin_positions) {
            // "pin_name: (x, y)" or "pin_name: x y"
            const ptrimmed = std.mem.trimLeft(u8, line, " ");
            if (std.mem.indexOfScalar(u8, ptrimmed, ':')) |colon| {
                const pin_name = std.mem.trim(u8, ptrimmed[0..colon], " \t");
                const coords = std.mem.trim(u8, ptrimmed[colon + 1 ..], " \t(),");
                if (pin_name.len > 0 and coords.len > 0) {
                    // Parse "x, y" or "x y"
                    var ctok = std.mem.tokenizeAny(u8, coords, ", \t");
                    const xs = ctok.next() orelse continue;
                    const ys = ctok.next() orelse continue;
                    const px2 = std.fmt.parseInt(i32, xs, 10) catch continue;
                    const py2 = std.fmt.parseInt(i32, ys, 10) catch continue;
                    // Update matching pin's position
                    const pnames = s.pins.items(.name);
                    const pxs = s.pins.items(.x);
                    const pys = s.pins.items(.y);
                    for (0..s.pins.len) |pi| {
                        if (std.mem.eql(u8, pnames[pi], pin_name)) {
                            pxs[pi] = px2;
                            pys[pi] = py2;
                            break;
                        }
                    }
                }
            }
            continue;
        }

        // Inside drawing_lines sub-section: "(x0,y0) (x1,y1)" format lines
        if (subsection == .drawing_lines) {
            const dtrimmed = std.mem.trimLeft(u8, line, " ");
            // Sub-section transitions take priority
            if (std.mem.startsWith(u8, dtrimmed, "pin_positions:")) {
                subsection = .pin_positions;
                continue;
            }
            if (std.mem.startsWith(u8, dtrimmed, "circle:")) {
                if (parseParenCircle(dtrimmed["circle:".len..])) |c| {
                    s.circles.append(a, .{ .layer = 0, .cx = c[0], .cy = c[1], .radius = c[2] }) catch {};
                }
                subsection = .drawing;
                continue;
            }
            if (std.mem.startsWith(u8, dtrimmed, "arc:")) {
                if (parseParenArc(dtrimmed["arc:".len..])) |arc| {
                    s.arcs.append(a, .{ .layer = 0, .cx = arc[0], .cy = arc[1], .radius = arc[2], .start_angle = @intCast(arc[3]), .sweep_angle = @intCast(arc[4]) }) catch {};
                }
                subsection = .drawing;
                continue;
            }
            if (std.mem.startsWith(u8, dtrimmed, "rect:")) {
                if (parseParenTwoPoints(dtrimmed["rect:".len..])) |pts| {
                    s.rects.append(a, .{ .layer = 0, .x0 = pts[0], .y0 = pts[1], .x1 = pts[2], .y1 = pts[3] }) catch {};
                }
                subsection = .drawing;
                continue;
            }
            if (std.mem.startsWith(u8, dtrimmed, "text:")) {
                subsection = .drawing;
                continue;
            }
            if (std.mem.startsWith(u8, dtrimmed, "lines:")) {
                // Already in drawing_lines, stay
                continue;
            }
            // Parse "(x0,y0) (x1,y1)" format
            if (parseParenTwoPoints(dtrimmed)) |pts| {
                s.lines.append(a, .{ .layer = 0, .x0 = pts[0], .y0 = pts[1], .x1 = pts[2], .y1 = pts[3] }) catch {};
            }
            continue;
        }

        // Inside drawing section: parse shape primitives for symbol view
        if (subsection == .drawing) {
            const dtrimmed = std.mem.trimLeft(u8, line, " ");
            // Check for sub-section transitions
            if (std.mem.startsWith(u8, dtrimmed, "pin_positions:")) {
                subsection = .pin_positions;
                continue;
            }
            // .chn_prim "lines:" sub-section with (x0,y0) (x1,y1) format
            if (std.mem.startsWith(u8, dtrimmed, "lines:")) {
                subsection = .drawing_lines;
                continue;
            }
            // .chn_prim "circle: (cx,cy) r=N" format
            if (std.mem.startsWith(u8, dtrimmed, "circle:")) {
                if (parseParenCircle(dtrimmed["circle:".len..])) |c| {
                    s.circles.append(a, .{ .layer = 0, .cx = c[0], .cy = c[1], .radius = c[2] }) catch {};
                }
                continue;
            }
            // .chn_prim "arc: (cx,cy) r=N start=S sweep=W" format
            if (std.mem.startsWith(u8, dtrimmed, "arc:")) {
                if (parseParenArc(dtrimmed["arc:".len..])) |arc| {
                    s.arcs.append(a, .{ .layer = 0, .cx = arc[0], .cy = arc[1], .radius = arc[2], .start_angle = @intCast(arc[3]), .sweep_angle = @intCast(arc[4]) }) catch {};
                }
                continue;
            }
            // .chn_prim "rect: (x0,y0) (x1,y1)" format
            if (std.mem.startsWith(u8, dtrimmed, "rect:")) {
                if (parseParenTwoPoints(dtrimmed["rect:".len..])) |pts| {
                    s.rects.append(a, .{ .layer = 0, .x0 = pts[0], .y0 = pts[1], .x1 = pts[2], .y1 = pts[3] }) catch {};
                }
                continue;
            }
            // .chn_prim "text: ..." — skip (labels are runtime/not geometry)
            if (std.mem.startsWith(u8, dtrimmed, "text:")) {
                continue;
            }
            // Original space-separated format: "line x0 y0 x1 y1"
            if (std.mem.startsWith(u8, dtrimmed, "line ")) {
                var dtok = std.mem.tokenizeAny(u8, dtrimmed[5..], " \t");
                const dx0 = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const dy0 = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const dx1 = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const dy1 = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                s.lines.append(a, .{ .layer = 0, .x0 = dx0, .y0 = dy0, .x1 = dx1, .y1 = dy1 }) catch {};
            } else if (std.mem.startsWith(u8, dtrimmed, "rect ")) {
                var dtok = std.mem.tokenizeAny(u8, dtrimmed[5..], " \t");
                const dx0 = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const dy0 = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const dx1 = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const dy1 = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                s.rects.append(a, .{ .layer = 0, .x0 = dx0, .y0 = dy0, .x1 = dx1, .y1 = dy1 }) catch {};
            } else if (std.mem.startsWith(u8, dtrimmed, "arc ")) {
                var dtok = std.mem.tokenizeAny(u8, dtrimmed[4..], " \t");
                const dcx = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const dcy = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const drad = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const dsa = std.fmt.parseInt(i16, dtok.next() orelse continue, 10) catch continue;
                const dsw = std.fmt.parseInt(i16, dtok.next() orelse continue, 10) catch continue;
                s.arcs.append(a, .{ .layer = 0, .cx = dcx, .cy = dcy, .radius = drad, .start_angle = dsa, .sweep_angle = dsw }) catch {};
            } else if (std.mem.startsWith(u8, dtrimmed, "circle ")) {
                var dtok = std.mem.tokenizeAny(u8, dtrimmed[7..], " \t");
                const dcx = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const dcy = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                const drad = std.fmt.parseInt(i32, dtok.next() orelse continue, 10) catch continue;
                s.circles.append(a, .{ .layer = 0, .cx = dcx, .cy = dcy, .radius = drad }) catch {};
            }
            // Unknown drawing primitives are silently skipped
            continue;
        }

        // Check for sub-section headers at indent level 1
        if (indent == 1 and (section == .symbol or section == .schematic or section == .testbench)) {
            // Flush pending generate
            if (subsection == .generate and gen_lines.items.len > 0) {
                flushGenerate(a, s, gen_var, gen_start, gen_end, gen_lines.items, &tagged_conns);
                gen_lines.items.len = 0;
            }

            // Reset table state on new sub-section
            table_remaining = 0;
            table_cols = null;

            if (std.mem.startsWith(u8, trimmed, "desc:")) {
                // desc: <one-line description> — store as sym_prop
                const val = std.mem.trim(u8, trimmed[5..], " \t");
                if (val.len > 0) {
                    s.sym_props.append(a, .{
                        .key = a.dupe(u8, "description") catch continue,
                        .val = a.dupe(u8, val) catch continue,
                    }) catch {};
                }
                subsection = .none;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "spice_prefix:")) {
                const val = std.mem.trim(u8, trimmed[13..], " \t");
                if (val.len > 0) {
                    s.sym_props.append(a, .{
                        .key = a.dupe(u8, "spice_prefix") catch continue,
                        .val = a.dupe(u8, val) catch continue,
                    }) catch {};
                }
                subsection = .none;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "spice_format:")) {
                const val = std.mem.trim(u8, trimmed[13..], " \t");
                if (val.len > 0) {
                    s.sym_props.append(a, .{
                        .key = a.dupe(u8, "spice_format") catch continue,
                        .val = a.dupe(u8, val) catch continue,
                    }) catch {};
                }
                subsection = .none;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "spice_lib:")) {
                const val = std.mem.trim(u8, trimmed[10..], " \t");
                if (val.len > 0) {
                    s.sym_props.append(a, .{
                        .key = a.dupe(u8, "spice_lib") catch continue,
                        .val = a.dupe(u8, val) catch continue,
                    }) catch {};
                }
                subsection = .none;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "pins ") or std.mem.startsWith(u8, trimmed, "pins[")) {
                subsection = .pins;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "params ") or std.mem.startsWith(u8, trimmed, "params[")) {
                subsection = .params;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "nets ") or std.mem.startsWith(u8, trimmed, "nets[") or std.mem.eql(u8, trimmed, "nets:")) {
                subsection = .nets;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "wires ") or std.mem.startsWith(u8, trimmed, "wires[")) {
                subsection = .wires;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "instances ") or std.mem.startsWith(u8, trimmed, "instances[")) {
                subsection = .instances_kv;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "generate ")) {
                subsection = .generate;
                parseGenerateHeader(trimmed, &gen_var, &gen_start, &gen_end);
                gen_lines.items.len = 0;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "annotations:") or std.mem.startsWith(u8, trimmed, "annotations ")) {
                subsection = .annotations;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "drawing:") or std.mem.startsWith(u8, trimmed, "drawing ")) {
                subsection = .drawing;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "shapes:") or std.mem.startsWith(u8, trimmed, "shapes ")) {
                subsection = .drawing;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "includes ") or std.mem.startsWith(u8, trimmed, "includes[")) {
                subsection = .includes;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "analyses ") or std.mem.startsWith(u8, trimmed, "analyses[")) {
                subsection = .analyses;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "measures ") or std.mem.startsWith(u8, trimmed, "measures[")) {
                subsection = .measures;
                continue;
            }
            if (std.mem.eql(u8, trimmed, "digital:") or std.mem.startsWith(u8, trimmed, "digital:")) {
                subsection = .digital;
                if (s.digital == null) s.digital = .{};
                continue;
            }

            // Type-grouped tabular block: e.g. "nmos [4]{name, w, l, nf, model}:"
            if (isTypeTableHeader(trimmed)) {
                subsection = .type_table;
                parseTypeTableHeader(a, trimmed, &table_type_name, &table_kind, &table_cols, &table_remaining);
                continue;
            }
        }

        // Parse content based on current sub-section (indent >= 2)
        if (indent >= 2) {
            // If we're inside an annotation sub-section, check for sub-section transitions
            switch (subsection) {
                .ann_op_points, .ann_measures, .ann_notes, .ann_voltages => {
                    if (std.mem.startsWith(u8, trimmed, "op_points ") or
                        std.mem.startsWith(u8, trimmed, "op_points[") or
                        std.mem.startsWith(u8, trimmed, "measures:") or
                        std.mem.startsWith(u8, trimmed, "notes:") or
                        std.mem.startsWith(u8, trimmed, "node_voltages:"))
                    {
                        subsection = .annotations;
                    }
                },
                else => {},
            }
            switch (subsection) {
                .pins => v2ParsePinRow(a, s, trimmed),
                .params => v2ParseParamRow(a, s, trimmed),
                .type_table => {
                    if (table_remaining > 0) {
                        v2ParseTypeTableRow(a, s, trimmed, table_type_name, table_kind, table_cols);
                        table_remaining -= 1;
                        if (table_remaining == 0) subsection = .none;
                    }
                },
                .instances_kv => v2ParseInstanceKV(a, s, trimmed),
                .nets => v2ParseNetRow(a, s, trimmed, &tagged_conns),
                .wires => {
                    // Wire row: "x0 y0 x1 y1 [net_name]"
                    var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
                    const x0s = tok.next() orelse continue;
                    const y0s = tok.next() orelse continue;
                    const x1s = tok.next() orelse continue;
                    const y1s = tok.next() orelse continue;
                    const net = tok.next();
                    s.wires.append(a, .{
                        .x0 = std.fmt.parseInt(i32, x0s, 10) catch continue,
                        .y0 = std.fmt.parseInt(i32, y0s, 10) catch continue,
                        .x1 = std.fmt.parseInt(i32, x1s, 10) catch continue,
                        .y1 = std.fmt.parseInt(i32, y1s, 10) catch continue,
                        .net_name = if (net) |n| (a.dupe(u8, n) catch null) else null,
                    }) catch {};
                },
                .annotations => {
                    // Sub-sections within annotations
                    if (std.mem.startsWith(u8, trimmed, "op_points ") or std.mem.startsWith(u8, trimmed, "op_points[")) {
                        subsection = .ann_op_points;
                        // Parse column names from header for op_points table
                        ann_op_cols = parseColumnNames(a, trimmed);
                        continue;
                    }
                    if (std.mem.startsWith(u8, trimmed, "measures:")) {
                        subsection = .ann_measures;
                        continue;
                    }
                    if (std.mem.startsWith(u8, trimmed, "notes:")) {
                        subsection = .ann_notes;
                        ann_note_idx = 0;
                        continue;
                    }
                    if (std.mem.startsWith(u8, trimmed, "node_voltages:")) {
                        subsection = .ann_voltages;
                        continue;
                    }
                    // Store status, timestamp, etc. as sym_props with "ann." prefix
                    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                        if (key.len > 0 and val.len > 0) {
                            const prefixed_key = std.fmt.allocPrint(a, "ann.{s}", .{key}) catch continue;
                            s.sym_props.append(a, .{
                                .key = prefixed_key,
                                .val = a.dupe(u8, val) catch continue,
                            }) catch {};
                        }
                    }
                },
                .ann_op_points => {
                    // Tabular op_point rows: "M0  0.612  0.611  52.3u  ..."
                    if (ann_op_cols) |cols| {
                        var tok2 = std.mem.tokenizeAny(u8, trimmed, " \t");
                        const inst_name2 = tok2.next() orelse continue;
                        var ci: usize = 1; // skip "inst" column (col 0 = instance name)
                        while (ci < cols.len) : (ci += 1) {
                            const val = tok2.next() orelse break;
                            const key = std.fmt.allocPrint(a, "ann.op.{s}.{s}", .{ inst_name2, cols[ci] }) catch continue;
                            s.sym_props.append(a, .{
                                .key = key,
                                .val = a.dupe(u8, val) catch continue,
                            }) catch {};
                        }
                    }
                },
                .ann_measures => {
                    // Key-value: "dc_gain:  42.3 dB"
                    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                        if (key.len > 0 and val.len > 0) {
                            const pk = std.fmt.allocPrint(a, "ann.measure.{s}", .{key}) catch continue;
                            s.sym_props.append(a, .{
                                .key = pk,
                                .val = a.dupe(u8, val) catch continue,
                            }) catch {};
                        }
                    }
                },
                .ann_notes => {
                    // List entries: '- "some note"' or just '- some note'
                    var note = trimmed;
                    if (std.mem.startsWith(u8, note, "- ")) note = note[2..];
                    // Strip surrounding quotes
                    if (note.len >= 2 and note[0] == '"' and note[note.len - 1] == '"')
                        note = note[1 .. note.len - 1];
                    if (note.len > 0) {
                        const pk = std.fmt.allocPrint(a, "ann.note.{d}", .{ann_note_idx}) catch continue;
                        s.sym_props.append(a, .{
                            .key = pk,
                            .val = a.dupe(u8, note) catch continue,
                        }) catch {};
                        ann_note_idx += 1;
                    }
                },
                .ann_voltages => {
                    // Key-value: "VDD:  1.800"
                    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                        if (key.len > 0 and val.len > 0) {
                            const pk = std.fmt.allocPrint(a, "ann.voltage.{s}", .{key}) catch continue;
                            s.sym_props.append(a, .{
                                .key = pk,
                                .val = a.dupe(u8, val) catch continue,
                            }) catch {};
                        }
                    }
                },
                .includes => {
                    // Store includes as sym_props
                    if (trimmed.len > 0) {
                        s.sym_props.append(a, .{
                            .key = a.dupe(u8, "include") catch continue,
                            .val = a.dupe(u8, trimmed) catch continue,
                        }) catch {};
                    }
                },
                .analyses => {
                    // Store analyses as sym_props with "analysis." prefix
                    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                        const prefixed = std.fmt.allocPrint(a, "analysis.{s}", .{key}) catch continue;
                        s.sym_props.append(a, .{
                            .key = prefixed,
                            .val = a.dupe(u8, val) catch continue,
                        }) catch {};
                    }
                },
                .measures => {
                    // Store measures as sym_props with "measure." prefix
                    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                        const prefixed = std.fmt.allocPrint(a, "measure.{s}", .{key}) catch continue;
                        s.sym_props.append(a, .{
                            .key = prefixed,
                            .val = a.dupe(u8, val) catch continue,
                        }) catch {};
                    }
                },
                .digital => {
                    // Sub-keys within digital: language, behavioral, synthesized
                    if (std.mem.startsWith(u8, trimmed, "language:")) {
                        const val = std.mem.trim(u8, trimmed[9..], " \t");
                        if (HdlLanguage.fromStr(val)) |lang| {
                            if (s.digital) |*d| d.language = lang;
                        }
                    } else if (std.mem.eql(u8, trimmed, "behavioral:")) {
                        subsection = .digital_behavioral;
                    } else if (std.mem.eql(u8, trimmed, "synthesized:")) {
                        subsection = .digital_synthesized;
                    }
                },
                .digital_behavioral => {
                    if (std.mem.startsWith(u8, trimmed, "mode:")) {
                        const val = std.mem.trim(u8, trimmed[5..], " \t");
                        if (s.digital) |*d| {
                            d.behavioral.mode = if (std.mem.eql(u8, val, "file")) .file else .@"inline";
                        }
                    } else if (std.mem.startsWith(u8, trimmed, "top_module:")) {
                        const val = std.mem.trim(u8, trimmed[11..], " \t");
                        if (val.len > 0) {
                            if (s.digital) |*d| d.behavioral.top_module = a.dupe(u8, val) catch null;
                        }
                    } else if (std.mem.startsWith(u8, trimmed, "source:")) {
                        const val = std.mem.trim(u8, trimmed[7..], " \t");
                        if (std.mem.eql(u8, val, "|")) {
                            // Multi-line inline source follows
                            subsection = .digital_inline_source;
                            digital_inline_buf.items.len = 0;
                            digital_indent_base = indent + 1;
                        } else if (val.len > 0) {
                            if (s.digital) |*d| d.behavioral.source = a.dupe(u8, val) catch null;
                        }
                    }
                },
                .digital_inline_source => {
                    // Collect inline source lines until de-indent
                    if (indent >= digital_indent_base) {
                        if (digital_inline_buf.items.len > 0) digital_inline_buf.append(a, '\n') catch {};
                        digital_inline_buf.appendSlice(a, trimmed) catch {};
                        continue;
                    }
                    // De-indented — flush the inline source
                    if (digital_inline_buf.items.len > 0) {
                        if (s.digital) |*d| {
                            d.behavioral.source = digital_inline_buf.toOwnedSlice(a) catch null;
                        }
                    }
                    // Re-parse this line at the correct subsection level
                    subsection = .digital;
                    // Fall through to re-parse (need to handle this line)
                    if (std.mem.startsWith(u8, trimmed, "synthesized:")) {
                        subsection = .digital_synthesized;
                    } else if (std.mem.startsWith(u8, trimmed, "behavioral:")) {
                        subsection = .digital_behavioral;
                    }
                },
                .digital_synthesized => {
                    if (std.mem.startsWith(u8, trimmed, "mode:")) {
                        const val = std.mem.trim(u8, trimmed[5..], " \t");
                        if (s.digital) |*d| {
                            d.synthesized.mode = if (std.mem.eql(u8, val, "inline")) .@"inline" else .file;
                        }
                    } else if (std.mem.startsWith(u8, trimmed, "source:")) {
                        const val = std.mem.trim(u8, trimmed[7..], " \t");
                        if (val.len > 0) {
                            if (s.digital) |*d| d.synthesized.source = a.dupe(u8, val) catch null;
                        }
                    } else if (std.mem.startsWith(u8, trimmed, "liberty:")) {
                        const val = std.mem.trim(u8, trimmed[8..], " \t");
                        if (val.len > 0) {
                            if (s.digital) |*d| d.synthesized.liberty = a.dupe(u8, val) catch null;
                        }
                    } else if (std.mem.startsWith(u8, trimmed, "mapping:")) {
                        const val = std.mem.trim(u8, trimmed[8..], " \t");
                        if (val.len > 0) {
                            if (s.digital) |*d| d.synthesized.mapping = a.dupe(u8, val) catch null;
                        }
                    } else if (std.mem.eql(u8, trimmed, "supply_map:")) {
                        subsection = .digital_supply_map;
                    }
                },
                .digital_supply_map => {
                    // Parse "KEY: VALUE" supply mapping lines
                    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                        if (key.len > 0 and val.len > 0) {
                            if (s.digital) |*d| {
                                d.synthesized.supply_map.append(a, .{
                                    .key = a.dupe(u8, key) catch continue,
                                    .val = a.dupe(u8, val) catch continue,
                                }) catch {};
                            }
                        }
                    } else {
                        // Non-colon line means we're out of supply_map
                        subsection = .digital_synthesized;
                    }
                },
                .drawing, .drawing_lines, .generate, .pin_positions => {},
                .none => {},
            }
        }
    }

    // Flush any pending digital inline source
    if (subsection == .digital_inline_source and digital_inline_buf.items.len > 0) {
        if (s.digital) |*d| {
            d.behavioral.source = digital_inline_buf.toOwnedSlice(a) catch null;
        }
    }

    // Flush any remaining generate block
    if (gen_lines.items.len > 0) {
        flushGenerate(a, s, gen_var, gen_start, gen_end, gen_lines.items, &tagged_conns);
    }

    // Repack tagged conns into contiguous ranges per instance and build nets list.
    repackTaggedConns(a, s, tagged_conns.items);

    s.emit(.info, "parsed v2 {s} \"{s}\": {d} inst, {d} conn, {d} pin, {d} prop", .{
        switch (s.stype) {
            .testbench => "testbench",
            .primitive => "primitive",
            .component => "component",
        },
        s.name,
        s.instances.len,
        s.conns.items.len,
        s.pins.len,
        s.props.items.len,
    });
}

/// Check if a line looks like a type-grouped tabular header: `<name> [N]{...}:`
fn isTypeTableHeader(trimmed: []const u8) bool {
    // Must contain '[', '{', and end with ':'
    if (!std.mem.endsWith(u8, trimmed, ":")) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '[') == null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') == null) return false;
    // Must not be a known sub-section keyword
    if (std.mem.startsWith(u8, trimmed, "pins") or
        std.mem.startsWith(u8, trimmed, "params") or
        std.mem.startsWith(u8, trimmed, "nets") or
        std.mem.startsWith(u8, trimmed, "instances") or
        std.mem.startsWith(u8, trimmed, "op_points"))
        return false;
    return true;
}

/// Parse a type-table header: "nmos [4]{name, w, l, nf, model}:"
fn parseTypeTableHeader(
    a: Allocator,
    trimmed: []const u8,
    type_name: *[]const u8,
    kind: *Devices.DeviceKind,
    cols: *?[]const []const u8,
    remaining: *u32,
) void {
    // Extract type name (everything before the first space or '[')
    const first_delim = blk: {
        for (trimmed, 0..) |c, i| {
            if (c == ' ' or c == '[') break :blk i;
        }
        break :blk trimmed.len;
    };
    type_name.* = a.dupe(u8, trimmed[0..first_delim]) catch "";
    kind.* = typeGroupToKind(type_name.*);

    // Extract count from [N]
    remaining.* = parseCountFromBracket(trimmed[first_delim..]) orelse 0;
    if (remaining.* == 0) {
        // Try finding [ in the rest
        if (std.mem.indexOfScalarPos(u8, trimmed, first_delim, '[')) |bracket_start| {
            remaining.* = parseCountFromBracket(trimmed[bracket_start..]) orelse 0;
        }
    }

    // Extract column names from {col1, col2, ...}
    cols.* = parseColumnNames(a, trimmed);
}

/// Parse a pin row: "<name> <direction> [x=N] [y=N] [width=N]"
fn v2ParsePinRow(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const name = tok_it.next() orelse return;
    const dir_str = tok_it.next() orelse "inout";
    var width: u16 = 1;
    var pin_x: i32 = 0;
    var pin_y: i32 = 0;
    // Check for optional key=value attributes
    while (tok_it.next()) |attr| {
        if (std.mem.startsWith(u8, attr, "width=")) {
            width = std.fmt.parseInt(u16, attr[6..], 10) catch 1;
        } else if (std.mem.startsWith(u8, attr, "x=")) {
            pin_x = std.fmt.parseInt(i32, attr[2..], 10) catch 0;
        } else if (std.mem.startsWith(u8, attr, "y=")) {
            pin_y = std.fmt.parseInt(i32, attr[2..], 10) catch 0;
        }
    }
    s.pins.append(a, .{
        .name = a.dupe(u8, name) catch return,
        .x = pin_x,
        .y = pin_y,
        .dir = PinDir.fromStr(dir_str),
        .num = null,
        .width = width,
    }) catch {};
}

/// Parse a param row: "<name> = <default_value>"
fn v2ParseParamRow(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    // Format: "name = value" or "name=value"
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return;
    const key = std.mem.trim(u8, trimmed[0..eq], " \t");
    const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    if (key.len == 0) return;
    s.sym_props.append(a, .{
        .key = a.dupe(u8, key) catch return,
        .val = a.dupe(u8, val) catch return,
    }) catch {};
}

/// Parse a type-table row: positional values matching column headers.
/// Creates an Instance + Prop entries for each column value.
fn v2ParseTypeTableRow(
    a: Allocator,
    s: *Schemify,
    trimmed: []const u8,
    type_name: []const u8,
    kind: Devices.DeviceKind,
    cols: ?[]const []const u8,
) void {
    const columns = cols orelse return;
    if (columns.len == 0) return;

    var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t");
    var col_idx: usize = 0;

    var inst_name: []const u8 = "";
    var inst_x: i32 = 0;
    var inst_y: i32 = 0;
    var inst_rot: u2 = 0;
    var inst_flip: bool = false;
    const prop_start: u32 = @intCast(s.props.items.len);

    while (tok_it.next()) |val| {
        if (col_idx >= columns.len) break;
        const col = columns[col_idx];

        if (std.mem.eql(u8, col, "name")) {
            inst_name = a.dupe(u8, val) catch "";
        } else if (std.mem.eql(u8, col, "x")) {
            inst_x = std.fmt.parseInt(i32, val, 10) catch 0;
        } else if (std.mem.eql(u8, col, "y")) {
            inst_y = std.fmt.parseInt(i32, val, 10) catch 0;
        } else if (std.mem.eql(u8, col, "rot")) {
            inst_rot = std.fmt.parseInt(u2, val, 10) catch 0;
        } else if (std.mem.eql(u8, col, "flip")) {
            inst_flip = std.fmt.parseInt(u1, val, 10) catch 0 != 0;
        } else {
            // For the last column, consume all remaining text (multi-token values like TABLE).
            const prop_val = if (col_idx == columns.len - 1) blk: {
                // Get everything from this token to end of line.
                const tok_start = @intFromPtr(val.ptr) - @intFromPtr(trimmed.ptr);
                break :blk std.mem.trimRight(u8, trimmed[tok_start..], " \t\r");
            } else val;
            s.props.append(a, .{
                .key = a.dupe(u8, col) catch continue,
                .val = a.dupe(u8, prop_val) catch continue,
            }) catch {};
        }
        col_idx += 1;
    }

    s.instances.append(a, .{
        .name = inst_name,
        .symbol = a.dupe(u8, type_name) catch "",
        .kind = kind,
        .x = inst_x,
        .y = inst_y,
        .rot = inst_rot,
        .flip = inst_flip,
        .prop_start = prop_start,
        .prop_count = @intCast(s.props.items.len - prop_start),
        .conn_start = 0,
        .conn_count = 0,
    }) catch {};
}

/// Parse a generic instance KV line: "XBUF chn/buffer strength=4 fanout=8"
fn v2ParseInstanceKV(a: Allocator, s: *Schemify, trimmed: []const u8) void {
    var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const inst_name = tok_it.next() orelse return;
    const symbol = tok_it.next() orelse return;

    const prop_start: u32 = @intCast(s.props.items.len);
    var inst_x: i32 = 0;
    var inst_y: i32 = 0;
    var inst_rot: u2 = 0;
    var inst_flip: bool = false;

    // Remaining tokens are key=value pairs
    while (tok_it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        const val = kv[eq + 1 ..];
        if (std.mem.eql(u8, key, "x")) {
            inst_x = std.fmt.parseInt(i32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "y")) {
            inst_y = std.fmt.parseInt(i32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "rot")) {
            inst_rot = std.fmt.parseInt(u2, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "flip")) {
            inst_flip = std.fmt.parseInt(u1, val, 10) catch 0 != 0;
        } else {
            s.props.append(a, .{
                .key = a.dupe(u8, key) catch continue,
                .val = a.dupe(u8, val) catch continue,
            }) catch {};
        }
    }

    const kind = typeGroupToKind(symbol);
    s.instances.append(a, .{
        .name = a.dupe(u8, inst_name) catch "",
        .symbol = a.dupe(u8, symbol) catch "",
        .kind = kind,
        .x = inst_x,
        .y = inst_y,
        .rot = inst_rot,
        .flip = inst_flip,
        .prop_start = prop_start,
        .prop_count = @intCast(s.props.items.len - prop_start),
        .conn_start = 0,
        .conn_count = 0,
    }) catch {};
}

/// A tagged conn entry — tracks which instance owns the conn so we can
/// repack into contiguous ranges after the full parse.
const TaggedConn = struct {
    inst_idx: u32,
    pin: []const u8,
    net: []const u8,
};

/// Parse a net row: "<net_name> -> inst.pin, inst.pin, ..."
/// Appends tagged entries to `tagged` for later contiguous repacking.
fn v2ParseNetRow(a: Allocator, s: *Schemify, trimmed: []const u8, tagged: *List(TaggedConn)) void {
    // Split on "->"
    const arrow = std.mem.indexOf(u8, trimmed, "->") orelse return;
    const net_name = std.mem.trim(u8, trimmed[0..arrow], " \t");
    const pins_str = std.mem.trim(u8, trimmed[arrow + 2 ..], " \t");
    if (net_name.len == 0 or pins_str.len == 0) return;

    // Parse comma-separated pin references: "inst.pin" pairs
    var pin_it = std.mem.tokenizeAny(u8, pins_str, ", \t");
    while (pin_it.next()) |pin_ref| {
        // pin_ref is "inst.pin" or "inst.pin->net" (shorthand, rare)
        // Handle the "CL.n->gnd" shorthand: split on -> first
        const actual_ref = blk: {
            if (std.mem.indexOf(u8, pin_ref, "->")) |nested_arrow| {
                break :blk pin_ref[0..nested_arrow];
            }
            break :blk pin_ref;
        };

        // Split on '.' to get instance name and pin name
        const dot = std.mem.indexOfScalar(u8, actual_ref, '.') orelse continue;
        const pin_name = actual_ref[dot + 1 ..];
        if (pin_name.len == 0) continue;

        const inst_idx = findInstanceByName(s, actual_ref[0..dot]) orelse continue;

        tagged.append(a, .{
            .inst_idx = @intCast(inst_idx),
            .pin = a.dupe(u8, pin_name) catch continue,
            .net = a.dupe(u8, net_name) catch continue,
        }) catch {};
    }
}

/// After parsing all net rows, repack tagged conns into contiguous ranges
/// per instance and build the nets list.
fn repackTaggedConns(a: Allocator, s: *Schemify, tagged: []const TaggedConn) void {
    if (tagged.len == 0) return;

    // Build contiguous conns per instance
    for (0..s.instances.len) |i| {
        const start: u16 = @intCast(s.conns.items.len);
        for (tagged) |e| {
            if (e.inst_idx == @as(u32, @intCast(i))) {
                s.conns.append(a, .{ .pin = e.pin, .net = e.net }) catch {};
            }
        }
        const count: u16 = @as(u16, @intCast(s.conns.items.len)) - start;
        s.instances.items(.conn_start)[i] = start;
        s.instances.items(.conn_count)[i] = count;
    }

    // Note: we intentionally do NOT build s.nets here. The CHN format stores
    // net names directly in conn entries (e.g. "VDD", "0", "net1"), not numeric
    // IDs. Leaving s.nets empty prevents resolveNetsForDevice from misinterpreting
    // the ground net "0" as numeric index 0 into the nets array.
}

/// Find an instance index by name.
fn findInstanceByName(s: *Schemify, name: []const u8) ?usize {
    const names = s.instances.items(.name);
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

/// Parse generate header: "generate <var> in <start>..<end>:"
fn parseGenerateHeader(trimmed: []const u8, gen_var: *[]const u8, start: *i32, end: *i32) void {
    // "generate bit in 0..7:"
    var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t:");
    _ = tok_it.next(); // "generate"
    gen_var.* = tok_it.next() orelse "i"; // variable name
    _ = tok_it.next(); // "in"
    const range = tok_it.next() orelse "0..0"; // "0..7"

    // Parse range "start..end"
    if (std.mem.indexOf(u8, range, "..")) |dots| {
        start.* = std.fmt.parseInt(i32, range[0..dots], 10) catch 0;
        end.* = std.fmt.parseInt(i32, range[dots + 2 ..], 10) catch 0;
    }
}

/// Expand a generate block: substitute {var} with each integer in [start..end] (inclusive)
/// and re-parse the expanded lines.
fn flushGenerate(a: Allocator, s: *Schemify, gen_var: []const u8, start: i32, end: i32, lines: []const []const u8, tagged: *List(TaggedConn)) void {
    if (gen_var.len == 0) return;

    // Build the substitution pattern: "{var}"
    const pattern = std.fmt.allocPrint(a, "{{{s}}}", .{gen_var}) catch return;

    var val = start;
    while (val <= end) : (val += 1) {
        const val_str = std.fmt.allocPrint(a, "{d}", .{val}) catch continue;

        // Process lines with substitution, handling type-table blocks and nets
        var i: usize = 0;
        while (i < lines.len) : (i += 1) {
            const expanded = substituteAll(a, lines[i], pattern, val_str) catch continue;
            const trimmed = std.mem.trimLeft(u8, expanded, " ");

            if (isTypeTableHeader(trimmed)) {
                // Parse the type-table header and consume following rows
                var tt_type: []const u8 = "";
                var tt_kind: Devices.DeviceKind = .unknown;
                var tt_cols: ?[]const []const u8 = null;
                var tt_rem: u32 = 0;
                parseTypeTableHeader(a, trimmed, &tt_type, &tt_kind, &tt_cols, &tt_rem);

                var row_count: u32 = 0;
                while (row_count < tt_rem and i + 1 < lines.len) {
                    i += 1;
                    const row_expanded = substituteAll(a, lines[i], pattern, val_str) catch continue;
                    const row_trimmed = std.mem.trimLeft(u8, row_expanded, " ");
                    v2ParseTypeTableRow(a, s, row_trimmed, tt_type, tt_kind, tt_cols);
                    row_count += 1;
                }
            } else if (std.mem.indexOf(u8, trimmed, "->") != null and
                !std.mem.startsWith(u8, trimmed, "nets"))
            {
                // Net declaration line
                v2ParseNetRow(a, s, trimmed, tagged);
            }
            // Skip sub-section headers like "nets:" within generate
        }
    }
}

// =============================================================================
// .chn_prim parenthesized coordinate parsers (runtime)
// =============================================================================

/// Parse a single signed integer from `s[start..]`, returning the value and
/// the index just past the last digit.  Skips leading whitespace.
fn runtimeParseI32(s: []const u8, start: usize) ?struct { val: i32, end: usize } {
    var i = start;
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
        val = val * 10 + @as(i32, s[i] - '0');
        i += 1;
    }
    if (neg) val = -val;
    return .{ .val = val, .end = i };
}

/// Parse "(x0,y0) (x1,y1)" returning [4]i32 {x0,y0,x1,y1} or null.
fn parseParenTwoPoints(s: []const u8) ?[4]i32 {
    // Find first '('
    var i: usize = 0;
    while (i < s.len and s[i] != '(') i += 1;
    if (i >= s.len) return null;
    i += 1;

    const x0r = runtimeParseI32(s, i) orelse return null;
    i = x0r.end;
    while (i < s.len and (s[i] == ',' or s[i] == ' ')) i += 1;
    const y0r = runtimeParseI32(s, i) orelse return null;
    i = y0r.end;

    // Find second '('
    while (i < s.len and s[i] != '(') i += 1;
    if (i >= s.len) return null;
    i += 1;

    const x1r = runtimeParseI32(s, i) orelse return null;
    i = x1r.end;
    while (i < s.len and (s[i] == ',' or s[i] == ' ')) i += 1;
    const y1r = runtimeParseI32(s, i) orelse return null;

    return .{ x0r.val, y0r.val, x1r.val, y1r.val };
}

/// Parse "(cx,cy)" returning [2]i32 or null.
fn parseParenOnePoint(s: []const u8) ?[2]i32 {
    var i: usize = 0;
    while (i < s.len and s[i] != '(') i += 1;
    if (i >= s.len) return null;
    i += 1;

    const xr = runtimeParseI32(s, i) orelse return null;
    i = xr.end;
    while (i < s.len and (s[i] == ',' or s[i] == ' ')) i += 1;
    const yr = runtimeParseI32(s, i) orelse return null;

    return .{ xr.val, yr.val };
}

/// Find "key=value" in a string, parsing value as i32.
fn findNamedI32(s: []const u8, key: []const u8) ?i32 {
    if (std.mem.indexOf(u8, s, key)) |pos| {
        const rv = runtimeParseI32(s, pos + key.len) orelse return null;
        return rv.val;
    }
    return null;
}

/// Parse "circle: (cx,cy) r=N" — expects the part after "circle:".
/// Returns [3]i32 {cx, cy, radius} or null.
fn parseParenCircle(s: []const u8) ?[3]i32 {
    const pt = parseParenOnePoint(s) orelse return null;
    const r = findNamedI32(s, "r=") orelse return null;
    return .{ pt[0], pt[1], r };
}

/// Parse "arc: (cx,cy) r=N start=S sweep=W" — expects the part after "arc:".
/// Returns [5]i32 {cx, cy, radius, start_angle, sweep_angle} or null.
fn parseParenArc(s: []const u8) ?[5]i32 {
    const pt = parseParenOnePoint(s) orelse return null;
    const r = findNamedI32(s, "r=") orelse return null;
    const start_val = findNamedI32(s, "start=") orelse return null;
    const sweep_val = findNamedI32(s, "sweep=") orelse return null;
    return .{ pt[0], pt[1], r, start_val, sweep_val };
}

/// Replace all occurrences of `pattern` with `replacement` in `src`.
fn substituteAll(a: Allocator, src: []const u8, pattern: []const u8, replacement: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, src, pattern) == null) return a.dupe(u8, src);
    var result = List(u8){};
    var pos: usize = 0;
    while (pos < src.len) {
        if (pos + pattern.len <= src.len and std.mem.eql(u8, src[pos..][0..pattern.len], pattern)) {
            try result.appendSlice(a, replacement);
            pos += pattern.len;
        } else {
            try result.append(a, src[pos]);
            pos += 1;
        }
    }
    return result.toOwnedSlice(a);
}
