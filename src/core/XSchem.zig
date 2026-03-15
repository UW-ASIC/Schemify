//! XSchem DOD Format — flat struct-of-arrays storage with integrated reader/writer.
//!
//! Handles XSchem's native .sch / .sym text format and converts it to the
//! canonical Schemify representation. All coordinates are f64 in XSchem
//! (Schemify uses i32); conversion happens via `f2i()` during `toSchemify`.
//!
//! Parser functions never return errors. Failures are logged as warnings with
//! a line number. `writeFile` returns `?[]u8` (null on failure).

const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;
const log = @import("Logger.zig");
const sch = @import("Schemify.zig");
const Schemify = sch.Schemify;
const simd = @import("Parse.zig");

const full_circle_deg: f64 = 360.0;
const pin_half_box: f64 = 5.0;
const layer_max: i32 = 255;

/// Pin direction. Identical variant order to `schemify.PinDir` — direct ordinal cast in `mapPins`.
pub const PinDirection = enum(u8) {
    input,
    output,
    inout,
    power,
    ground,
    pub fn fromStr(s: []const u8) PinDirection {
        if (s.len == 0) return .inout;
        return switch (s[0]) {
            'i' => if (std.mem.eql(u8, s, "io") or std.mem.eql(u8, s, "inout")) .inout else .input,
            'o' => .output,
            'p' => .power,
            'g' => .ground,
            else => .inout,
        };
    }
    pub fn toStr(self: PinDirection) []const u8 {
        return switch (self) {
            .input => "i",
            .output => "o",
            .inout => "io",
            .power => "p",
            .ground => "g",
        };
    }
};

pub const Line = struct { layer: i32, x0: f64, y0: f64, x1: f64, y1: f64 };
pub const Rect = struct { layer: i32, x0: f64, y0: f64, x1: f64, y1: f64, image_data: ?[]const u8 = null };
pub const Arc = struct { layer: i32, cx: f64, cy: f64, radius: f64, start_angle: f64, sweep_angle: f64 };
pub const Circle = struct { layer: i32, cx: f64, cy: f64, radius: f64 };
pub const Wire = struct { x0: f64, y0: f64, x1: f64, y1: f64, net_name: ?[]const u8 = null, bus: bool = false };
pub const Text = struct { content: []const u8, x: f64, y: f64, layer: i32 = 4, size: f64 = 0.4, rotation: i32 = 0 };
pub const Pin = struct { name: []const u8, x: f64, y: f64, direction: PinDirection = .inout, number: ?u32 = null, propag: bool = true };
pub const Instance = struct {
    name: []const u8,
    symbol: []const u8,
    x: f64,
    y: f64,
    rot: i32 = 0,
    flip: bool = false,
    prop_start: u32 = 0,
    prop_count: u16 = 0,
};
pub const Prop = struct { key: []const u8, value: []const u8 };

pub const XSchemType = enum(u1) { schematic, symbol };

/// Main XSchem store. Owns element memory through `arena`.
/// Use `toSchemify` to convert to Schemify representation.
pub const XSchem = struct {
    name: []const u8 = "",

    lines: MAL(Line) = .{},
    rects: MAL(Rect) = .{},
    arcs: MAL(Arc) = .{},
    circles: MAL(Circle) = .{},
    wires: MAL(Wire) = .{},
    texts: MAL(Text) = .{},
    pins: MAL(Pin) = .{},
    instances: MAL(Instance) = .{},
    props: List(Prop) = .{},
    verilog_body: ?[]const u8 = null,
    /// Non-null when the G {} block (VHDL behavioral content) is non-empty.
    /// XSchem suppresses port listing in .subckt headers for such schematics.
    ghdl_body: ?[]const u8 = null,
    /// Raw SPICE body from the S {} block (extracted netlist).
    spice_body: ?[]const u8 = null,

    xtype: XSchemType,
    arena: std.heap.ArenaAllocator,
    logger: ?*log.Logger = null,

    pub fn init(backing: Allocator) XSchem {
        return .{ .xtype = .schematic, .arena = std.heap.ArenaAllocator.init(backing) };
    }
    pub fn deinit(self: *XSchem) void {
        self.arena.deinit();
    }

    fn alloc(self: *XSchem) Allocator {
        return self.arena.allocator();
    }
    fn logWarn(self: *XSchem, comptime fmt: []const u8, args: anytype) void {
        if (self.logger) |l| l.warn("xschem", fmt, args);
    }
    fn logErr(self: *XSchem, comptime fmt: []const u8, args: anytype) void {
        if (self.logger) |l| l.err("xschem", fmt, args);
    }
    fn logInfo(self: *XSchem, comptime fmt: []const u8, args: anytype) void {
        if (self.logger) |l| l.info("xschem", fmt, args);
    }

    /// Auto-detects schematic vs symbol from content and parses.
    pub fn readFile(data: []const u8, backing: Allocator, logger: ?*log.Logger) XSchem {
        var xs = XSchem.init(backing);
        xs.logger = logger;
        xs.xtype = detectSymbol(data);
        if (xs.xtype == .symbol) {
            xs.logInfo("detected symbol format", .{});
            parseSymbol(&xs, data);
        } else {
            xs.logInfo("detected schematic format", .{});
            parseSchematic(&xs, data);
        }
        return xs;
    }

    pub fn toSchemify(self: *const XSchem, backing: Allocator) !sch.Schemify {
        var s = sch.Schemify.init(backing);
        const a = s.alloc();
        s.name = a.dupe(u8, self.name) catch "";
        s.stype = if (self.xtype == .symbol) .primitive else .component;
        try mapWires(a, self, &s);
        try mapInstances(a, self, &s);
        try mapTexts(a, self, &s);
        try mapShapes(a, self, &s);
        try mapPins(a, self, &s);
        try mapSymProps(a, self, &s);
        if (self.verilog_body) |vb| s.verilog_body = try a.dupe(u8, vb);
        if (self.spice_body) |sb| s.spice_body = try a.dupe(u8, sb);
        return s;
    }

    /// Writes to owned buffer. Returns null on failure (logged).
    pub fn writeFile(self: *XSchem, a: Allocator, logger: ?*log.Logger) ?[]u8 {
        self.logger = logger;
        var buf: List(u8) = .{};
        const w = buf.writer(a);
        if (self.xtype == .symbol) {
            self.logInfo("writing symbol: {d} pins, {d} shapes", .{ self.pins.len, self.lines.len + self.rects.len + self.arcs.len + self.circles.len });
            writeSym(w, self) catch |e| {
                self.logErr("write sym failed: {}", .{e});
                buf.deinit(a);
                return null;
            };
        } else {
            self.logInfo("writing schematic: {d} instances, {d} wires", .{ self.instances.len, self.wires.len });
            writeSch(w, self) catch |e| {
                self.logErr("write sch failed: {}", .{e});
                buf.deinit(a);
                return null;
            };
        }
        return buf.toOwnedSlice(a) catch |e| {
            self.logErr("write toOwnedSlice failed: {}", .{e});
            buf.deinit(a);
            return null;
        };
    }
};

/// Auto-detect whether a file is a .sym or .sch.
/// C/N line → schematic; K block with content or G{type=} → symbol.
fn detectSymbol(input: []const u8) XSchemType {
    var saw_sym_hint = false;
    var it = simd.LineIterator.init(input);
    while (it.next()) |raw| {
        const line = std.mem.trimLeft(u8, raw, " \t\r");
        if (line.len < 2) continue;
        if ((line[0] == 'C' or line[0] == 'N') and (line[1] == ' ' or line[1] == '{'))
            return .schematic;
        if (!saw_sym_hint) {
            if (line[0] == 'K' and (line[1] == ' ' or line[1] == '{')) {
                const open = std.mem.indexOfScalar(u8, line, '{') orelse continue;
                if (std.mem.lastIndexOfScalar(u8, line, '}')) |close| {
                    const content = std.mem.trim(u8, line[open + 1 .. close], " \t\r\n");
                    if (content.len > 0) saw_sym_hint = true;
                } else saw_sym_hint = true;
            } else if (std.mem.startsWith(u8, line, "G {") and std.mem.indexOf(u8, line, "type=") != null) {
                saw_sym_hint = true;
            }
        }
    }
    return if (saw_sym_hint) .symbol else .schematic;
}

/// Parse a .sch (schematic) file into the XSchem store.
fn parseSchematic(xs: *XSchem, input: []const u8) void {
    const a = xs.alloc();

    var it = simd.LineIterator.init(input);
    var cur_inst_idx: ?usize = null;
    var in_props = false;
    var skip_depth: u32 = 0;
    var line_num: u32 = 0;
    var in_mlq = false;
    var mlq_key: []const u8 = "";
    var mlq_buf: List(u8) = .{};
    defer mlq_buf.deinit(a);
    const BlockKind = enum { none, verilog, spice, k_global, g_global, image_props };
    var block_kind = BlockKind.none;
    var block_depth: u32 = 0;
    var block_k_quote = false;
    var v_buf: List(u8) = .{};
    var s_buf: List(u8) = .{};
    var k_buf: List(u8) = .{};
    var g_buf: List(u8) = .{};
    var img_buf: List(u8) = .{};
    defer v_buf.deinit(a);
    defer s_buf.deinit(a);
    defer k_buf.deinit(a);
    defer g_buf.deinit(a);
    defer img_buf.deinit(a);
    var in_wire = false;
    var wire_buf: List(u8) = .{};
    defer wire_buf.deinit(a);

    while (it.next()) |raw| {
        line_num += 1;
        const line = std.mem.trim(u8, raw, " \t\r");

        // Multi-line quoted value accumulation — must run before empty/comment skip.
        if (in_mlq) {
            var close_q: ?usize = null;
            var i_q: usize = 0;
            while (i_q < raw.len) {
                if (raw[i_q] == '\\') {
                    if (i_q + 2 < raw.len and raw[i_q + 1] == '\\' and raw[i_q + 2] == '"') {
                        i_q += 3;
                        continue;
                    }
                    if (i_q + 1 < raw.len and raw[i_q + 1] == '"') {
                        i_q += 2;
                        continue;
                    }
                }
                if (raw[i_q] == '"') {
                    close_q = i_q;
                    break;
                }
                i_q += 1;
            }
            if (close_q) |cq| {
                mlq_buf.appendSlice(a, raw[0..cq]) catch {};
                const val = mlq_buf.items;
                if (cur_inst_idx) |ci| {
                    const kd = a.dupe(u8, mlq_key) catch mlq_key;
                    const vd = a.dupe(u8, val) catch val;
                    xs.props.append(a, .{ .key = kd, .value = vd }) catch {};
                    xs.instances.slice().items(.prop_count)[ci] += 1;
                }
                mlq_buf.clearRetainingCapacity();
                in_mlq = false;
                const rest = std.mem.trim(u8, raw[cq + 1 ..], " \t\r");
                if (rest.len == 0) {
                    // nothing more on this line; props may continue on next line
                } else if (rest[0] == '}') {
                    cur_inst_idx = null;
                    in_props = false;
                } else if (cur_inst_idx) |ci| {
                    // Parse props remaining on the line. If the last token has an unclosed
                    // quoted value, enter in_mlq for the continuation lines.
                    // First, check whether rest ends with '}' (instance close). If so, strip
                    // it and remember to close after parsing.
                    const trimmed_rest = std.mem.trimRight(u8, rest, " \t\r");
                    const ends_with_close = trimmed_rest.len > 0 and trimmed_rest[trimmed_rest.len - 1] == '}';
                    const parse_src = if (ends_with_close)
                        std.mem.trim(u8, trimmed_rest[0 .. trimmed_rest.len - 1], " \t")
                    else
                        rest;
                    const sl2 = xs.instances.slice();
                    var nm2 = sl2.items(.name)[ci];
                    var pt = PropTokenizer.init(parse_src);
                    var got_mlq = false;
                    while (pt.next()) |tok2| {
                        if (pt.last_unclosed) {
                            mlq_key = a.dupe(u8, tok2.key) catch tok2.key;
                            mlq_buf.clearRetainingCapacity();
                            mlq_buf.appendSlice(a, tok2.val) catch {};
                            mlq_buf.append(a, '\n') catch {};
                            in_mlq = true;
                            got_mlq = true;
                            break;
                        }
                        _ = appendPropCore(a, tok2.key, tok2.val, tok2.single_quoted, &xs.props, &nm2) catch {};
                        sl2.items(.prop_count)[ci] += 1;
                    }
                    sl2.items(.name)[ci] = nm2;
                    if (!got_mlq and ends_with_close) {
                        cur_inst_idx = null;
                        in_props = false;
                    }
                }
            } else {
                mlq_buf.appendSlice(a, raw) catch {};
                mlq_buf.append(a, '\n') catch {};
            }
            continue;
        }

        if (line.len == 0) continue;

        // Skip blocks — before comment filter: '}' may appear on a '*' line.
        if (skip_depth > 0) {
            for (line) |c| {
                if (c == '{') skip_depth += 1;
                if (c == '}') {
                    if (skip_depth > 0) skip_depth -= 1;
                    if (skip_depth == 0) break;
                }
            }
            continue;
        }

        if (line[0] == '*') continue;

        switch (block_kind) {
            .verilog => {
                var ended = false;
                for (line) |c| {
                    if (c == '{') block_depth += 1 else if (c == '}') {
                        block_depth -= 1;
                        if (block_depth == 0) {
                            block_kind = .none;
                            ended = true;
                            break;
                        }
                    }
                }
                if (!ended) {
                    v_buf.appendSlice(a, raw) catch {
                        xs.logWarn("line {d}: OOM in V block", .{line_num});
                        continue;
                    };
                    v_buf.append(a, '\n') catch {};
                }
                continue;
            },
            .spice => {
                var ended = false;
                var close_pos: usize = 0;
                for (line, 0..) |c, ci| {
                    if (c == '{') block_depth += 1 else if (c == '}') {
                        if (block_depth > 0) block_depth -= 1;
                        if (block_depth == 0) {
                            block_kind = .none;
                            ended = true;
                            close_pos = ci;
                            break;
                        }
                    }
                }
                if (!ended) {
                    s_buf.appendSlice(a, raw) catch {};
                    s_buf.append(a, '\n') catch {};
                } else if (close_pos > 0) {
                    const partial = std.mem.trim(u8, line[0..close_pos], " \t\r");
                    if (partial.len > 0) {
                        s_buf.appendSlice(a, partial) catch {};
                        s_buf.append(a, '\n') catch {};
                    }
                }
                continue;
            },
            .k_global => {
                if (findKBlockCloseStateful(line, &block_k_quote)) |end| {
                    k_buf.append(a, '\n') catch {};
                    if (end > 0) k_buf.appendSlice(a, line[0..end]) catch {};
                    parsePropsRaw(a, k_buf.items, &xs.props) catch {};
                    k_buf.clearRetainingCapacity();
                    block_kind = .none;
                    block_k_quote = false;
                } else {
                    k_buf.append(a, '\n') catch {};
                    k_buf.appendSlice(a, line) catch {};
                }
                continue;
            },
            .g_global => {
                if (findKBlockCloseStateful(line, &block_k_quote)) |end| {
                    g_buf.append(a, '\n') catch {};
                    if (end > 0) g_buf.appendSlice(a, line[0..end]) catch {};
                    block_kind = .none;
                    block_k_quote = false;
                } else {
                    g_buf.append(a, '\n') catch {};
                    g_buf.appendSlice(a, line) catch {};
                }
                continue;
            },
            .image_props => {
                // Accumulate until closing '}'.
                if (std.mem.indexOfScalar(u8, line, '}') != null) {
                    block_kind = .none;
                    const close = std.mem.lastIndexOfScalar(u8, line, '}') orelse 0;
                    if (close > 0) {
                        img_buf.append(a, '\n') catch {};
                        img_buf.appendSlice(a, line[0..close]) catch {};
                    }
                    // Attach accumulated image_data to last rect.
                    if (xs.rects.len > 0) {
                        const id = std.mem.trim(u8, img_buf.items, " \t\n\r");
                        if (id.len > 0)
                            xs.rects.slice().items(.image_data)[xs.rects.len - 1] = a.dupe(u8, id) catch null;
                    }
                    img_buf.clearRetainingCapacity();
                } else {
                    img_buf.appendSlice(a, raw) catch {};
                    img_buf.append(a, '\n') catch {};
                }
                continue;
            },
            .none => {},
        }

        // V{}/S{} body block openers — unified brace-counting; differ only in target buffer.
        if ((line[0] == 'V' or line[0] == 'S') and (line.len == 1 or line[1] == ' ' or line[1] == '{')) {
            const oi = std.mem.indexOfScalar(u8, line, '{') orelse continue;
            block_depth = 0;
            var ended = false;
            for (line[oi..]) |c| {
                if (c == '{') block_depth += 1 else if (c == '}') {
                    if (block_depth > 0) block_depth -= 1;
                    if (block_depth == 0) {
                        ended = true;
                        break;
                    }
                }
            }
            const buf_ref = if (line[0] == 'V') &v_buf else &s_buf;
            if (!ended) {
                block_kind = if (line[0] == 'V') .verilog else .spice;
                const first = std.mem.trim(u8, line[oi + 1 ..], " \t");
                if (first.len > 0) {
                    buf_ref.appendSlice(a, first) catch {};
                    buf_ref.append(a, '\n') catch {};
                }
            } else {
                const cl = std.mem.lastIndexOfScalar(u8, line, '}') orelse line.len;
                if (cl > oi + 1) {
                    const content = std.mem.trim(u8, line[oi + 1 .. cl], " \t");
                    if (content.len > 0) buf_ref.appendSlice(a, content) catch {};
                }
            }
            continue;
        }

        if (line.len >= 2 and (line[0] == 'K' or line[0] == 'G') and (line[1] == ' ' or line[1] == '{')) {
            const is_g = line[0] == 'G';
            const open = std.mem.indexOfScalar(u8, line, '{') orelse continue;
            const close = std.mem.lastIndexOfScalar(u8, line, '}');
            if (close != null and close.? > open) {
                const content = line[open + 1 .. close.?];
                if (is_g) {
                    const trimmed = std.mem.trim(u8, content, " \t\r\n");
                    // Old XSchem (.sym files pre-3.2) used G-block for properties;
                    // detect by presence of "type=" and treat as K-block in that case.
                    if (trimmed.len > 0 and std.mem.indexOf(u8, trimmed, "type=") != null) {
                        parsePropsRaw(a, content, &xs.props) catch {};
                    } else if (trimmed.len > 0) {
                        xs.ghdl_body = a.dupe(u8, trimmed) catch null;
                    }
                } else {
                    parsePropsRaw(a, content, &xs.props) catch {};
                }
            } else if (close == null or close.? <= open) {
                block_k_quote = false;
                if (is_g) {
                    block_kind = .g_global;
                    g_buf.clearRetainingCapacity();
                    const after_open = line[open + 1 ..];
                    const trimmed_after = std.mem.trim(u8, after_open, " \t");
                    if (trimmed_after.len > 0) {
                        g_buf.appendSlice(a, trimmed_after) catch {};
                        _ = findKBlockCloseStateful(trimmed_after, &block_k_quote);
                    }
                } else {
                    block_kind = .k_global;
                    k_buf.clearRetainingCapacity();
                    const after_open = line[open + 1 ..];
                    const trimmed_after = std.mem.trim(u8, after_open, " \t");
                    if (trimmed_after.len > 0) {
                        k_buf.appendSlice(a, trimmed_after) catch {};
                        _ = findKBlockCloseStateful(trimmed_after, &block_k_quote);
                    }
                }
            }
            continue;
        }

        if (in_wire) {
            wire_buf.append(a, ' ') catch {};
            wire_buf.appendSlice(a, line) catch {};
            if (std.mem.indexOfScalar(u8, line, '}') != null) {
                in_wire = false;
                parseWire(a, wire_buf.items, &xs.wires) catch |e| {
                    xs.logWarn("line {d}: multiline wire parse failed: {}", .{ line_num, e });
                };
                wire_buf.clearRetainingCapacity();
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "v {")) continue;

        if (cur_inst_idx != null and in_props) {
            const raw_trimmed = std.mem.trim(u8, line, " \t\r");
            const trimmed = if (raw_trimmed.len > 0 and raw_trimmed[0] == '+')
                std.mem.trimLeft(u8, raw_trimmed[1..], " \t")
            else
                raw_trimmed;
            if (std.mem.indexOf(u8, trimmed, "=\"")) |eq_q| {
                const open_pos = eq_q + 1;
                var n_quotes_after: usize = 0;
                {
                    const after = trimmed[open_pos + 1 ..];
                    var qi: usize = 0;
                    while (qi < after.len) {
                        if (after[qi] == '\\') {
                            if (qi + 2 < after.len and after[qi + 1] == '\\' and after[qi + 2] == '"') {
                                qi += 3;
                                continue;
                            }
                            if (qi + 1 < after.len and after[qi + 1] == '"') {
                                qi += 2;
                                continue;
                            }
                            qi += 1;
                            continue;
                        }
                        if (after[qi] == '"') n_quotes_after += 1;
                        qi += 1;
                    }
                }
                if (n_quotes_after == 0) {
                    const key_end = eq_q;
                    var key_start = eq_q;
                    while (key_start > 0 and trimmed[key_start - 1] != ' ' and trimmed[key_start - 1] != '\t') key_start -= 1;
                    if (key_start > 0) {
                        const prefix = std.mem.trim(u8, trimmed[0..key_start], " \t");
                        if (prefix.len > 0) parsePropLine(a, prefix, &xs.props, &xs.instances, cur_inst_idx.?) catch {};
                    }
                    mlq_key = a.dupe(u8, trimmed[key_start..key_end]) catch trimmed[key_start..key_end];
                    mlq_buf.clearRetainingCapacity();
                    if (open_pos + 1 < trimmed.len) {
                        mlq_buf.appendSlice(a, trimmed[open_pos + 1 ..]) catch {};
                        mlq_buf.append(a, '\n') catch {};
                    }
                    in_mlq = true;
                    continue;
                }
            }
            if (std.mem.lastIndexOfScalar(u8, trimmed, '}')) |close_idx| {
                const after_close = std.mem.trim(u8, trimmed[close_idx + 1 ..], " \t\r");
                const escaped_close = close_idx > 0 and trimmed[close_idx - 1] == '\\';
                if (after_close.len == 0 and !escaped_close) {
                    const prefix = std.mem.trim(u8, trimmed[0..close_idx], " \t\r");
                    if (prefix.len > 0) {
                        parsePropLine(a, prefix, &xs.props, &xs.instances, cur_inst_idx.?) catch |e| {
                            xs.logWarn("line {d}: prop parse failed: {}", .{ line_num, e });
                        };
                    }
                    cur_inst_idx = null;
                    in_props = false;
                    continue;
                }
            }
            parsePropLine(a, trimmed, &xs.props, &xs.instances, cur_inst_idx.?) catch |e| {
                xs.logWarn("line {d}: prop parse failed: {}", .{ line_num, e });
            };
            continue;
        }

        switch (line[0]) {
            'C' => {
                const idx = xs.instances.len;
                const cr = parseComponent(a, line, &xs.instances, &xs.props) catch |e| {
                    xs.logWarn("line {d}: component parse failed: {}", .{ line_num, e });
                    continue;
                };
                if (cr.multi) {
                    cur_inst_idx = idx;
                    in_props = true;
                    if (cr.mlq_pending_key) |mk| {
                        const inst = xs.instances.slice();
                        const pc = &inst.items(.prop_count)[idx];
                        if (pc.* > 0 and xs.props.items.len > 0) {
                            const last_prop = xs.props.items[xs.props.items.len - 1];
                            mlq_buf.clearRetainingCapacity();
                            mlq_buf.appendSlice(a, last_prop.value) catch {};
                            mlq_buf.append(a, '\n') catch {};
                            xs.props.shrinkRetainingCapacity(xs.props.items.len - 1);
                            pc.* -= 1;
                        }
                        mlq_key = mk;
                        in_mlq = true;
                    }
                }
            },
            'N' => {
                const has_open = std.mem.indexOfScalar(u8, line, '{') != null;
                const has_close = std.mem.lastIndexOfScalar(u8, line, '}') != null;
                if (has_open and !has_close) {
                    in_wire = true;
                    wire_buf.clearRetainingCapacity();
                    wire_buf.appendSlice(a, line) catch {};
                } else {
                    parseWire(a, line, &xs.wires) catch |e| {
                        xs.logWarn("line {d}: wire parse failed: {}", .{ line_num, e });
                    };
                }
            },
            'T' => {
                const ok = parseText(a, line, &xs.texts) catch |e| {
                    xs.logWarn("line {d}: text parse failed: {}", .{ line_num, e });
                    continue;
                };
                if (!ok) {
                    for (line) |c| {
                        if (c == '{') skip_depth += 1;
                        if (c == '}') {
                            if (skip_depth > 0) skip_depth -= 1;
                        }
                    }
                }
            },
            'L' => parseLineShape(a, line, &xs.lines),
            'B' => {
                parseLineShape(a, line, &xs.rects);
                // Check for prop block { ... } — capture if it contains image data.
                if (std.mem.indexOfScalar(u8, line, '{')) |oi| {
                    const ci = std.mem.lastIndexOfScalar(u8, line, '}');
                    const is_image = std.mem.indexOf(u8, line, "flags=image") != null;
                    if (ci != null and ci.? > oi) {
                        // Single-line prop block — capture if image
                        if (is_image and xs.rects.len > 0) {
                            const props_str = std.mem.trim(u8, line[oi + 1 .. ci.?], " \t\r\n");
                            xs.rects.slice().items(.image_data)[xs.rects.len - 1] = a.dupe(u8, props_str) catch null;
                        }
                    } else if (ci == null or ci.? <= oi) {
                        // Multi-line prop block
                        if (is_image) {
                            block_kind = .image_props;
                            img_buf.clearRetainingCapacity();
                            const first = std.mem.trim(u8, line[oi + 1 ..], " \t");
                            if (first.len > 0) img_buf.appendSlice(a, first) catch {};
                        } else {
                            // Non-image multi-line props: skip via skip_depth
                            for (line) |c| {
                                if (c == '{') skip_depth += 1;
                                if (c == '}') {
                                    if (skip_depth > 0) skip_depth -= 1;
                                }
                            }
                        }
                    }
                }
            },
            'A' => parseArcLine(a, line, &xs.arcs, &xs.circles),
            else => {},
        }
    }

    const trimmed = std.mem.trim(u8, v_buf.items, " \t\n\r");
    if (trimmed.len > 0) xs.verilog_body = a.dupe(u8, trimmed) catch null;

    const s_trimmed = std.mem.trim(u8, s_buf.items, " \t\n\r");
    if (s_trimmed.len > 0) xs.spice_body = a.dupe(u8, s_trimmed) catch null;

    // G-block: old XSchem (.sym files pre-3.2) used G-block for properties; detect by
    // presence of "type=" and parse as K-block in that case. Otherwise treat as VHDL.
    if (xs.ghdl_body == null) {
        const g_trimmed = std.mem.trim(u8, g_buf.items, " \t\n\r");
        if (g_trimmed.len > 0) {
            if (std.mem.indexOf(u8, g_trimmed, "type=") != null) {
                parsePropsRaw(a, g_trimmed, &xs.props) catch {};
            } else {
                xs.ghdl_body = a.dupe(u8, g_trimmed) catch null;
            }
        }
    }

    xs.logInfo("parsed schematic: {d} instances, {d} wires, {d} shapes", .{
        xs.instances.len, xs.wires.len, xs.lines.len + xs.rects.len + xs.arcs.len + xs.circles.len,
    });
}

/// Parse a .sym (symbol) file into the XSchem store.
fn parseSymbol(xs: *XSchem, input: []const u8) void {
    const a = xs.alloc();

    var it = simd.LineIterator.init(input);
    var in_k = false;
    var in_k_quote = false;
    var in_b = false;
    var k_buf: List(u8) = .{};
    var b_buf: List(u8) = .{};
    defer k_buf.deinit(a);
    defer b_buf.deinit(a);
    var line_num: u32 = 0;

    while (it.next()) |raw| {
        line_num += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '*') continue;

        if (in_b) {
            b_buf.append(a, ' ') catch {};
            b_buf.appendSlice(a, line) catch {};
            if (std.mem.indexOfScalar(u8, line, '}') != null) {
                in_b = false;
                const full = b_buf.items;
                const is_pin = parsePinBox(a, full, &xs.pins) catch |e| blk: {
                    xs.logWarn("line {d}: multiline pin parse failed: {}", .{ line_num, e });
                    break :blk false;
                };
                if (!is_pin) parseLineShape(a, full, &xs.rects);
                b_buf.clearRetainingCapacity();
            }
            continue;
        }

        if (in_k) {
            if (findKBlockCloseStateful(line, &in_k_quote)) |end| {
                k_buf.append(a, '\n') catch {};
                if (end > 0) k_buf.appendSlice(a, line[0..end]) catch {};
                parsePropsRaw(a, k_buf.items, &xs.props) catch |e| {
                    xs.logWarn("line {d}: K block props failed: {}", .{ line_num, e });
                };
                k_buf.clearRetainingCapacity();
                in_k = false;
                in_k_quote = false;
            } else {
                k_buf.append(a, '\n') catch {};
                k_buf.appendSlice(a, line) catch {};
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "v {")) continue;
        if (line.len >= 3 and (line[0] == 'V' or line[0] == 'S' or line[0] == 'E') and line[1] == ' ' and line[2] == '{') continue;

        switch (line[0]) {
            'K', 'G' => {
                const open = std.mem.indexOfScalar(u8, line, '{') orelse continue;
                const close = std.mem.lastIndexOfScalar(u8, line, '}');
                if (close != null and close.? > open) {
                    parsePropsRaw(a, line[open + 1 .. close.?], &xs.props) catch |e| {
                        xs.logWarn("line {d}: K block props failed: {}", .{ line_num, e });
                    };
                } else {
                    in_k = true;
                    in_k_quote = false;
                    k_buf.clearRetainingCapacity();
                    const initial = line[open + 1 ..];
                    k_buf.appendSlice(a, initial) catch {};
                    _ = findKBlockCloseStateful(initial, &in_k_quote);
                }
            },
            'B' => {
                const has_close = std.mem.lastIndexOfScalar(u8, line, '}') != null;
                if (has_close) {
                    const is_pin = parsePinBox(a, line, &xs.pins) catch |e| blk: {
                        xs.logWarn("line {d}: pin parse failed: {}", .{ line_num, e });
                        break :blk false;
                    };
                    if (!is_pin) parseLineShape(a, line, &xs.rects);
                } else if (std.mem.indexOfScalar(u8, line, '{') != null) {
                    in_b = true;
                    b_buf.clearRetainingCapacity();
                    b_buf.appendSlice(a, line) catch {};
                } else {
                    parseLineShape(a, line, &xs.rects);
                }
            },
            'L' => parseLineShape(a, line, &xs.lines),
            'T' => _ = parseText(a, line, &xs.texts) catch |e| {
                xs.logWarn("line {d}: text parse failed: {}", .{ line_num, e });
            },
            'A' => parseArcLine(a, line, &xs.arcs, &xs.circles),
            else => {},
        }
    }

    xs.logInfo("parsed symbol: {d} pins, {d} shapes", .{
        xs.pins.len, xs.lines.len + xs.rects.len + xs.arcs.len + xs.circles.len,
    });
}

fn writeShapesXS(w: anytype, xs: *const XSchem) !void {
    var buf: [128]u8 = undefined;

    buf[1] = ' ';
    {
        const sl = xs.lines.slice();
        for (0..xs.lines.len) |i| {
            buf[0] = 'L';
            var n: usize = 2 + simd.writeI32(buf[2..], sl.items(.layer)[i]);
            n += bufWriteF64_4(&buf, n, sl.items(.x0)[i], sl.items(.y0)[i], sl.items(.x1)[i], sl.items(.y1)[i]);
            try w.writeAll(buf[0..n]);
            try w.writeAll(" {}\n");
        }
    }
    {
        const sr = xs.rects.slice();
        for (0..xs.rects.len) |i| {
            buf[0] = 'B';
            var n: usize = 2 + simd.writeI32(buf[2..], sr.items(.layer)[i]);
            n += bufWriteF64_4(&buf, n, sr.items(.x0)[i], sr.items(.y0)[i], sr.items(.x1)[i], sr.items(.y1)[i]);
            try w.writeAll(buf[0..n]);
            try w.writeAll(" {}\n");
        }
    }
    {
        const sa = xs.arcs.slice();
        for (0..xs.arcs.len) |i| {
            buf[0] = 'A';
            var n: usize = 2 + simd.writeI32(buf[2..], sa.items(.layer)[i]);
            n += bufWriteF64_4(&buf, n, sa.items(.cx)[i], sa.items(.cy)[i], sa.items(.radius)[i], sa.items(.start_angle)[i]);
            buf[n] = ' ';
            n += 1;
            n += simd.writeF64(buf[n..], sa.items(.sweep_angle)[i]);
            try w.writeAll(buf[0..n]);
            try w.writeAll(" {}\n");
        }
    }
    {
        const sc = xs.circles.slice();
        for (0..xs.circles.len) |i| {
            buf[0] = 'A';
            var n: usize = 2 + simd.writeI32(buf[2..], sc.items(.layer)[i]);
            n += bufWriteF64_3(&buf, n, sc.items(.cx)[i], sc.items(.cy)[i], sc.items(.radius)[i]);
            try w.writeAll(buf[0..n]);
            try w.writeAll(" 0 360 {}\n");
        }
    }
}

fn writeTextsXS(w: anytype, xs: *const XSchem) !void {
    var buf: [128]u8 = undefined;
    const ts = xs.texts.slice();
    for (0..xs.texts.len) |i| {
        try w.writeAll("T {");
        try w.writeAll(ts.items(.content)[i]);
        try w.writeAll("} ");
        var n: usize = simd.writeF64(buf[0..], ts.items(.x)[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeF64(buf[n..], ts.items(.y)[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], ts.items(.layer)[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], ts.items(.rotation)[i]);
        @memcpy(buf[n..][0..3], " 0 ");
        n += 3;
        n += simd.writeF64(buf[n..], ts.items(.size)[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeF64(buf[n..], ts.items(.size)[i]);
        try w.writeAll(buf[0..n]);
        try w.writeAll(" {}\n");
    }
}

fn bufWriteF64_3(buf: *[128]u8, s: usize, a: f64, b: f64, c: f64) usize {
    var n: usize = 0;
    inline for (&[_]f64{ a, b, c }) |v| {
        buf[s + n] = ' ';
        n += 1;
        n += simd.writeF64(buf[s + n ..], v);
    }
    return n;
}

fn bufWriteF64_4(buf: *[128]u8, s: usize, a: f64, b: f64, c: f64, d: f64) usize {
    var n = bufWriteF64_3(buf, s, a, b, c);
    buf[s + n] = ' ';
    n += 1;
    n += simd.writeF64(buf[s + n ..], d);
    return n;
}

fn writeSch(w: anytype, xs: *const XSchem) !void {
    try w.writeAll("v {xschem version=3.4.5 file_version=1.2}\nG {}\nK {}\nV {}\nS {}\nE {}\n");

    var buf: [128]u8 = undefined;
    const ins = xs.instances.slice();
    for (0..xs.instances.len) |i| {
        try w.writeAll("C {");
        try w.writeAll(ins.items(.symbol)[i]);
        try w.writeAll("} ");
        var n: usize = simd.writeF64(buf[0..], ins.items(.x)[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeF64(buf[n..], ins.items(.y)[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], ins.items(.rot)[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], if (ins.items(.flip)[i]) @as(i32, 1) else 0);
        buf[n] = ' ';
        buf[n + 1] = '{';
        n += 2;
        try w.writeAll(buf[0..n]);
        const nm = ins.items(.name)[i];
        var first_prop = nm.len == 0;
        if (!first_prop) {
            try w.writeAll("name=");
            try w.writeAll(nm);
        }
        for (xs.props.items[ins.items(.prop_start)[i]..][0..ins.items(.prop_count)[i]]) |p| {
            if (std.mem.eql(u8, p.key, "name")) continue;
            if (!first_prop) try w.writeAll(" ");
            try writePropKVInline(w, p.key, p.value);
            first_prop = false;
        }
        try w.writeAll("}\n");
    }

    {
        const ws = xs.wires.slice();
        buf[0] = 'N';
        for (0..xs.wires.len) |i| {
            var n: usize = 1 + bufWriteF64_4(&buf, 1, ws.items(.x0)[i], ws.items(.y0)[i], ws.items(.x1)[i], ws.items(.y1)[i]);
            buf[n] = ' ';
            buf[n + 1] = '{';
            n += 2;
            try w.writeAll(buf[0..n]);
            var fw = true;
            if (ws.items(.bus)[i]) {
                try w.writeAll("bus=true");
                fw = false;
            }
            if (ws.items(.net_name)[i]) |name| {
                if (!fw) try w.writeAll(" ");
                try writePropKVInline(w, "lab", name);
            }
            try w.writeAll("}\n");
        }
    }

    try writeTextsXS(w, xs);
    try writeShapesXS(w, xs);
}

// Header keys emitted verbatim in K{} block — skipped in trailing loop to avoid duplication.
const sym_header_keys = std.StaticStringMap(void).initComptime(.{
    .{ "type", {} }, .{ "format", {} }, .{ "template", {} },
});

fn writeSym(w: anytype, xs: *const XSchem) !void {
    try w.writeAll("v {xschem version=3.4.5 file_version=1.2}\nG {}\n");
    try w.writeAll("K {type=subcircuit\nformat=\"@name @pinlist @symname\"\ntemplate=\"name=x1\"\n");
    for (xs.props.items) |p| {
        if (sym_header_keys.has(p.key)) continue;
        try writePropKVInline(w, p.key, p.value);
        try w.writeAll("\n");
    }
    try w.writeAll("}\nV {}\nS {}\nE {}\n");

    try writeShapesXS(w, xs);

    var buf: [128]u8 = undefined;
    @memcpy(buf[0..4], "B 5 ");
    const ps = xs.pins.slice();
    for (0..xs.pins.len) |i| {
        const px = ps.items(.x)[i];
        const py = ps.items(.y)[i];
        const n = 4 + bufWriteF64_4(&buf, 4, px - pin_half_box / 2, py - pin_half_box / 2, px + pin_half_box / 2, py + pin_half_box / 2);
        try w.writeAll(buf[0..n]);
        try w.writeAll(" {name=");
        try w.writeAll(ps.items(.name)[i]);
        try w.writeAll(" dir=");
        try w.writeAll(ps.items(.direction)[i].toStr());
        if (ps.items(.number)[i]) |num| {
            var nb: [11]u8 = undefined;
            try w.writeAll(" pinnumber=");
            try w.writeAll(nb[0..simd.writeI32(nb[0..], @as(i32, @intCast(num)))]);
        }
        try w.writeAll("}\n");
    }

    try writeTextsXS(w, xs);
}

/// Find the K-block closing `}` skipping `}` inside `"..."`. `in_quote` is stateful.
fn findKBlockCloseStateful(line: []const u8, in_quote: *bool) ?usize {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (!in_quote.*) {
            if (c == '"') {
                in_quote.* = true;
                i += 1;
                continue;
            }
            if (c == '}') return i;
        } else {
            if (c == '\\' and i + 1 < line.len and line[i + 1] == '"') {
                i += 2;
                continue;
            }
            if (c == '"') in_quote.* = false;
        }
        i += 1;
    }
    return null;
}

const ComponentResult = struct { multi: bool, mlq_pending_key: ?[]const u8 = null };

fn parseComponent(a: Allocator, line: []const u8, instances: *MAL(Instance), props: *List(Prop)) !ComponentResult {
    const s = simd.findByte(line, '{') orelse return error.InvalidFormat;
    const e = simd.findByteFrom(line, s + 1, '}') orelse return error.InvalidFormat;
    const sym = try a.dupe(u8, line[s + 1 .. e]);
    const rest = line[e + 1 ..];
    var pos: usize = 0;

    const x = simd.nextF64(rest, &pos) orelse return error.InvalidNumber;
    const y = simd.nextF64(rest, &pos) orelse return error.InvalidNumber;
    const rot = simd.nextI32(rest, &pos) orelse return error.InvalidNumber;
    const flp = simd.nextI32(rest, &pos) orelse return error.InvalidNumber;

    const prop_start: u32 = @intCast(props.items.len);
    var inst_name: []const u8 = "";
    var multi = false;
    var mlq_key: ?[]const u8 = null;

    const ps = simd.findByte(rest, '{');
    if (ps) |p| {
        const pe: ?usize = blk: {
            var ri: usize = rest.len;
            while (ri > p + 1) {
                ri -= 1;
                if (rest[ri] == '}') {
                    if (ri > 0 and rest[ri - 1] == '\\') continue;
                    break :blk ri;
                }
            }
            break :blk null;
        };
        if (pe) |q| {
            _ = try parsePropsInto(a, rest[p + 1 .. q], props, &inst_name);
        } else {
            mlq_key = try parsePropsInto(a, rest[p + 1 ..], props, &inst_name);
            multi = true;
        }
    }

    try instances.append(a, .{ .name = inst_name, .symbol = sym, .x = x, .y = y, .rot = rot, .flip = flp != 0, .prop_start = prop_start, .prop_count = @intCast(props.items.len - prop_start) });
    return .{ .multi = multi, .mlq_pending_key = mlq_key };
}

fn parseWire(a: Allocator, line: []const u8, wires: *MAL(Wire)) !void {
    if (line.len < 3) return;
    var pos: usize = 0;
    const x0 = simd.nextF64(line[2..], &pos) orelse return;
    const y0 = simd.nextF64(line[2..], &pos) orelse return;
    const x1 = simd.nextF64(line[2..], &pos) orelse return;
    const y1 = simd.nextF64(line[2..], &pos) orelse return;
    var net: ?[]const u8 = null;
    var bus: bool = false;
    if (simd.findByte(line, '{')) |sb| if (std.mem.lastIndexOfScalar(u8, line, '}')) |eb| {
        var tok = PropTokenizer.init(line[sb + 1 .. eb]);
        while (tok.next()) |p| {
            if (std.mem.eql(u8, p.key, "lab")) net = try a.dupe(u8, stripQ(p.val)) else if (std.mem.eql(u8, p.key, "bus")) bus = std.mem.eql(u8, p.val, "true");
        }
    };
    try wires.append(a, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .net_name = net, .bus = bus });
}

fn parseText(a: Allocator, line: []const u8, texts: *MAL(Text)) !bool {
    const s = simd.findByte(line, '{') orelse return false;
    const e = simd.findByteFrom(line, s + 1, '}') orelse return false;
    const content = try a.dupe(u8, line[s + 1 .. e]);
    const rest = line[e + 1 ..];
    var pos: usize = 0;
    const x = simd.nextF64(rest, &pos) orelse return false;
    const y = simd.nextF64(rest, &pos) orelse return false;
    const layer = simd.nextI32(rest, &pos) orelse 4;
    const rot = simd.nextI32(rest, &pos) orelse 0;
    _ = simd.nextI32(rest, &pos); // flip — consume but not stored
    const xscale = simd.nextF64(rest, &pos) orelse 0.4; // text size
    try texts.append(a, .{ .content = content, .x = x, .y = y, .layer = layer, .rotation = rot, .size = xscale });
    return true;
}

/// Parse `<tag> <layer> <x0> <y0> <x1> <y1>` — works for Line and Rect (same fields).
fn parseLineShape(a: Allocator, line: []const u8, out: anytype) void {
    if (line.len < 3) return;
    var pos: usize = 0;
    const data = line[2 .. simd.findByte(line, '{') orelse line.len];
    const ly = simd.nextI32(data, &pos) orelse return;
    const x0 = simd.nextF64(data, &pos) orelse return;
    const y0 = simd.nextF64(data, &pos) orelse return;
    const x1 = simd.nextF64(data, &pos) orelse return;
    const y1 = simd.nextF64(data, &pos) orelse return;
    out.append(a, .{ .layer = ly, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }) catch return;
}

fn parseArcLine(a: Allocator, line: []const u8, arcs: *MAL(Arc), circles: *MAL(Circle)) void {
    if (line.len < 3) return;
    var pos: usize = 0;
    const data = line[2 .. simd.findByte(line, '{') orelse line.len];
    const ly = simd.nextI32(data, &pos) orelse return;
    const cx = simd.nextF64(data, &pos) orelse return;
    const cy = simd.nextF64(data, &pos) orelse return;
    const r = simd.nextF64(data, &pos) orelse return;
    const sa = simd.nextF64(data, &pos) orelse return;
    const sw = simd.nextF64(data, &pos) orelse return;
    if (sa == 0 and sw == full_circle_deg)
        circles.append(a, .{ .layer = ly, .cx = cx, .cy = cy, .radius = r }) catch return
    else
        arcs.append(a, .{ .layer = ly, .cx = cx, .cy = cy, .radius = r, .start_angle = sa, .sweep_angle = sw }) catch return;
}

fn parsePinBox(a: Allocator, line: []const u8, pins: *MAL(Pin)) !bool {
    const sb = simd.findByte(line, '{') orelse return false;
    const eb = std.mem.lastIndexOfScalar(u8, line, '}') orelse return false;
    if (sb >= eb) return false;

    var pname: ?[]const u8 = null;
    var have_primary_name = false;
    var dir = PinDirection.inout;
    var num: ?u32 = null;

    const PinKey = enum { name, dir, pinnumber, propag, other };
    const pin_key_map = std.StaticStringMap(PinKey).initComptime(.{
        .{ "name", .name }, .{ "dir", .dir }, .{ "pinnumber", .pinnumber }, .{ "propag", .propag },
    });

    var propag: bool = true;
    var ptok = PropTokenizer.init(line[sb + 1 .. eb]);
    while (ptok.next()) |p| {
        switch (pin_key_map.get(p.key) orelse .other) {
            .name => if (!have_primary_name) {
                pname = try a.dupe(u8, stripQ(p.val));
                have_primary_name = true;
            },
            .dir => dir = PinDirection.fromStr(p.val),
            .pinnumber => num = std.fmt.parseInt(u32, p.val, 10) catch null,
            .propag => propag = !std.mem.eql(u8, p.val, "0"),
            .other => {},
        }
    }
    if (pname == null) return false;

    const geo = line[2..sb];
    var gpos: usize = 0;
    _ = simd.nextToken(geo, &gpos); // layer
    const x0 = simd.nextF64(geo, &gpos) orelse return false;
    const y0 = simd.nextF64(geo, &gpos) orelse return false;
    const x1 = simd.nextF64(geo, &gpos) orelse return false;
    const y1 = simd.nextF64(geo, &gpos) orelse return false;
    try pins.append(a, .{ .name = pname.?, .x = (x0 + x1) / 2, .y = (y0 + y1) / 2, .direction = dir, .number = num, .propag = propag });
    return true;
}

inline fn appendPropCore(a: Allocator, key: []const u8, val: []const u8, single_quoted: bool, props: *List(Prop), name_out: ?*[]const u8) ![]const u8 {
    const k = try a.dupe(u8, key);
    const v = if (single_quoted) try std.fmt.allocPrint(a, "'{s}'", .{val}) else try a.dupe(u8, val);
    if (name_out) |n| {
        if (std.mem.eql(u8, k, "name")) n.* = v;
    }
    try props.append(a, .{ .key = k, .value = v });
    return k;
}

fn parsePropLine(a: Allocator, line: []const u8, props: *List(Prop), instances: *MAL(Instance), idx: usize) !void {
    var tok = PropTokenizer.init(line);
    const sl = instances.slice();
    while (tok.next()) |p| {
        var nm = sl.items(.name)[idx];
        _ = try appendPropCore(a, p.key, p.val, p.single_quoted, props, &nm);
        sl.items(.name)[idx] = nm;
        sl.items(.prop_count)[idx] += 1;
    }
}

/// Parse key=value pairs into `props`. Returns key of last token if its quoted value was unclosed.
fn parsePropsInto(a: Allocator, s: []const u8, props: *List(Prop), name: *[]const u8) !?[]const u8 {
    var tok = PropTokenizer.init(s);
    var unclosed_key: ?[]const u8 = null;
    while (tok.next()) |p| {
        const k = try appendPropCore(a, p.key, p.val, p.single_quoted, props, name);
        unclosed_key = if (tok.last_unclosed) k else null;
    }
    return unclosed_key;
}

fn parsePropsRaw(a: Allocator, s: []const u8, props: *List(Prop)) !void {
    var tok = PropTokenizer.init(s);
    while (tok.next()) |p| {
        _ = try appendPropCore(a, p.key, p.val, p.single_quoted, props, null);
    }
}

fn stripQ(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\'')))
        return s[1 .. s.len - 1];
    return s;
}

fn writePropKVInline(w: anytype, key: []const u8, value: []const u8) !void {
    try w.writeAll(key);
    try w.writeAll("=");
    const needs_q = if (value.len == 0) true else for (value) |c| {
        if (c == ' ' or c == '\t' or c == '"' or c == '\'' or c == '@' or c == '\n') break true;
    } else false;
    if (needs_q) {
        try w.writeAll("\"");
        var line_it = std.mem.splitScalar(u8, value, '\n');
        var first = true;
        while (line_it.next()) |vline| {
            if (!first) try w.writeByte('\n');
            first = false;
            try w.writeAll(std.mem.trimRight(u8, vline, " \t"));
        }
        try w.writeAll("\"");
    } else try w.writeAll(value);
}

const PropTokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    last_unclosed: bool = false,
    const Tok = struct { key: []const u8, val: []const u8, single_quoted: bool = false };
    fn init(src: []const u8) PropTokenizer {
        return .{ .src = src };
    }

    fn next(self: *PropTokenizer) ?Tok {
        self.last_unclosed = false;
        const s = self.src;
        // skip leading whitespace
        while (self.pos < s.len and (s[self.pos] == ' ' or s[self.pos] == '\t' or s[self.pos] == '\n' or s[self.pos] == '\r')) self.pos += 1;
        if (self.pos >= s.len) return null;
        const ks = self.pos;
        while (self.pos < s.len and s[self.pos] != '=') self.pos += 1;
        if (self.pos >= s.len) return null;
        const key = std.mem.trim(u8, s[ks..self.pos], " \t");
        if (key.len == 0) {
            while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
            return self.next();
        }
        // Validate key: must contain only word chars (a-z A-Z 0-9 _ -) and no spaces.
        // Lines from non-key=value content (e.g. VHDL/Verilog source code) often have
        // an '=' inside a string literal, producing bogus keys with '(', '"', spaces.
        // Reject those so they don't pollute the property list.
        for (key) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                // Invalid key character — skip to end of line and retry next line.
                while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
                return self.next();
            }
        }
        self.pos += 1;
        while (self.pos < s.len and s[self.pos] != '\n' and (s[self.pos] == ' ' or s[self.pos] == '\t')) self.pos += 1;
        if (self.pos >= s.len) return null;
        if (s[self.pos] == '"' or s[self.pos] == '\'') {
            const q = s[self.pos];
            self.pos += 1;
            const vs = self.pos;
            while (self.pos < s.len and !(s[self.pos] == q and (self.pos == vs or s[self.pos - 1] != '\\'))) self.pos += 1;
            const val = s[vs..self.pos];
            if (self.pos < s.len) self.pos += 1 else self.last_unclosed = true;
            return .{ .key = key, .val = val, .single_quoted = q == '\'' };
        }
        const vs = self.pos;
        while (self.pos < s.len and s[self.pos] != ' ' and s[self.pos] != '\t' and s[self.pos] != '\n' and s[self.pos] != '\r') self.pos += 1;
        return .{ .key = key, .val = s[vs..self.pos] };
    }
};

/// Clamp and round f64 → i32 safely.
fn f2i(v: f64) i32 {
    const clamped = @max(@as(f64, -2147483648.0), @min(@as(f64, 2147483647.0), v));
    return @intFromFloat(@round(clamped));
}

inline fn clampLayer(ly: i32, default: u8) u8 {
    return if (ly >= 0 and ly <= layer_max) @intCast(ly) else default;
}

fn mapWires(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    const ws = xs.wires.slice();
    try s.wires.ensureTotalCapacity(a, xs.wires.len);
    for (0..xs.wires.len) |i| s.wires.appendAssumeCapacity(.{
        .x0 = f2i(ws.items(.x0)[i]),
        .y0 = f2i(ws.items(.y0)[i]),
        .x1 = f2i(ws.items(.x1)[i]),
        .y1 = f2i(ws.items(.y1)[i]),
        .net_name = if (ws.items(.net_name)[i]) |n| try a.dupe(u8, n) else null,
        .bus = ws.items(.bus)[i],
    });
}

fn mapInstances(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    const ins = xs.instances.slice();
    try s.instances.ensureTotalCapacity(a, xs.instances.len);
    for (0..xs.instances.len) |i| {
        const prop_start: u32 = @intCast(s.props.items.len);
        for (xs.props.items[ins.items(.prop_start)[i]..][0..ins.items(.prop_count)[i]]) |p|
            try s.props.append(a, .{ .key = try a.dupe(u8, p.key), .val = try a.dupe(u8, p.value) });
        const sym = try a.dupe(u8, ins.items(.symbol)[i]);
        s.instances.appendAssumeCapacity(.{
            .name = try a.dupe(u8, ins.items(.name)[i]),
            .symbol = sym,
            .kind = inferDeviceKind(sym),
            .x = f2i(ins.items(.x)[i]),
            .y = f2i(ins.items(.y)[i]),
            .rot = @truncate(@as(u32, @bitCast(ins.items(.rot)[i]))),
            .flip = ins.items(.flip)[i],
            .prop_start = prop_start,
            .prop_count = @intCast(s.props.items.len - prop_start),
        });
    }
}

fn mapTexts(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    const ts = xs.texts.slice();
    try s.texts.ensureTotalCapacity(a, xs.texts.len);
    for (0..xs.texts.len) |i| {
        // size: xscale * 10, clamped to [1, 255]
        const raw_sz = @round(ts.items(.size)[i] * 10.0);
        const sz: u8 = if (raw_sz < 1.0) 1 else if (raw_sz > 255.0) 255 else @intCast(@as(i32, @intFromFloat(raw_sz)));
        // rotation: i32 → u2 via bitcast truncation
        const rot: u2 = @truncate(@as(u32, @bitCast(ts.items(.rotation)[i])));
        s.texts.appendAssumeCapacity(.{
            .content = try a.dupe(u8, ts.items(.content)[i]),
            .x = f2i(ts.items(.x)[i]),
            .y = f2i(ts.items(.y)[i]),
            .layer = clampLayer(ts.items(.layer)[i], 4),
            .size = sz,
            .rotation = rot,
        });
    }
}

fn mapShapes(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    {
        try s.lines.ensureTotalCapacity(a, xs.lines.len);
        const sl = xs.lines.slice();
        for (0..xs.lines.len) |i| s.lines.appendAssumeCapacity(.{
            .layer = clampLayer(sl.items(.layer)[i], 0),
            .x0 = f2i(sl.items(.x0)[i]),
            .y0 = f2i(sl.items(.y0)[i]),
            .x1 = f2i(sl.items(.x1)[i]),
            .y1 = f2i(sl.items(.y1)[i]),
        });
    }
    {
        try s.rects.ensureTotalCapacity(a, xs.rects.len);
        const sr = xs.rects.slice();
        for (0..xs.rects.len) |i| s.rects.appendAssumeCapacity(.{
            .layer = clampLayer(sr.items(.layer)[i], 0),
            .x0 = f2i(sr.items(.x0)[i]),
            .y0 = f2i(sr.items(.y0)[i]),
            .x1 = f2i(sr.items(.x1)[i]),
            .y1 = f2i(sr.items(.y1)[i]),
            .image_data = if (sr.items(.image_data)[i]) |id| try a.dupe(u8, id) else null,
        });
    }
    {
        try s.arcs.ensureTotalCapacity(a, xs.arcs.len);
        const sa = xs.arcs.slice();
        for (0..xs.arcs.len) |i| s.arcs.appendAssumeCapacity(.{
            .layer = clampLayer(sa.items(.layer)[i], 0),
            .cx = f2i(sa.items(.cx)[i]),
            .cy = f2i(sa.items(.cy)[i]),
            .radius = f2i(sa.items(.radius)[i]),
            .start_angle = @truncate(f2i(sa.items(.start_angle)[i])),
            .sweep_angle = @truncate(f2i(sa.items(.sweep_angle)[i])),
        });
    }
    {
        try s.circles.ensureTotalCapacity(a, xs.circles.len);
        const sc = xs.circles.slice();
        for (0..xs.circles.len) |i| s.circles.appendAssumeCapacity(.{
            .layer = clampLayer(sc.items(.layer)[i], 0),
            .cx = f2i(sc.items(.cx)[i]),
            .cy = f2i(sc.items(.cy)[i]),
            .radius = f2i(sc.items(.radius)[i]),
        });
    }
}

fn mapPins(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    const ps = xs.pins.slice();
    try s.pins.ensureTotalCapacity(a, xs.pins.len);
    // PinDirection and sch.PinDir share identical variant order (u8), direct cast is safe.
    for (0..xs.pins.len) |i| s.pins.appendAssumeCapacity(.{
        .name = try a.dupe(u8, ps.items(.name)[i]),
        .x = f2i(ps.items(.x)[i]),
        .y = f2i(ps.items(.y)[i]),
        .dir = @enumFromInt(@intFromEnum(ps.items(.direction)[i])),
        .num = if (ps.items(.number)[i]) |n| @truncate(n) else null,
    });
}

fn mapSymProps(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    // Copy all K/G block global properties (no whitelist filter).
    // Instance props are excluded: they are covered by xs.instances prop_start/prop_count ranges.
    // Build a set of indices covered by any instance to identify instance-owned props.
    var inst_owned = std.AutoHashMapUnmanaged(u32, void){};
    defer inst_owned.deinit(a);
    const ins = xs.instances.slice();
    for (0..xs.instances.len) |i| {
        const ps = ins.items(.prop_start)[i];
        const pc = ins.items(.prop_count)[i];
        var j: u32 = ps;
        while (j < ps + pc) : (j += 1) inst_owned.put(a, j, {}) catch {};
    }
    for (xs.props.items, 0..) |p, idx|
        if (!inst_owned.contains(@intCast(idx)))
            try s.sym_props.append(a, .{ .key = try a.dupe(u8, p.key), .val = try a.dupe(u8, p.value) });
}

const device_kind_map = std.StaticStringMap(sch.DeviceKind).initComptime(.{
    // ── Passives ──
    .{ "res.sym", .resistor },            .{ "res3.sym", .resistor },                 .{ "res_ac.sym", .resistor },
    .{ "var_res.sym", .resistor },        .{ "capa.sym", .capacitor },                .{ "capa-2.sym", .capacitor },
    .{ "ind.sym", .inductor },

    // ── Semiconductors ──
               .{ "diode.sym", .diode },                   .{ "zener.sym", .diode },
    .{ "nmos.sym", .mosfet },             .{ "pmos.sym", .mosfet },                   .{ "nmos3.sym", .mosfet },
    .{ "pmos3.sym", .mosfet },            .{ "nmos4.sym", .mosfet },                  .{ "pmos4.sym", .mosfet },
    .{ "nmos-sub.sym", .mosfet },         .{ "pmos-sub.sym", .mosfet },               .{ "nmoshv4.sym", .mosfet },
    .{ "pmoshv4.sym", .mosfet },          .{ "npn.sym", .bjt },                       .{ "pnp.sym", .bjt },
    .{ "njfet.sym", .jfet },              .{ "pjfet.sym", .jfet },                    .{ "mesfet.sym", .mesfet },

    // ── Sources ──
    .{ "vsource.sym", .vsource },         .{ "vsource_arith.sym", .vsource },         .{ "vsource_pwl.sym", .vsource },
    .{ "isource.sym", .isource },         .{ "isource_arith.sym", .isource },         .{ "isource_pwl.sym", .isource },
    .{ "ammeter.sym", .ammeter },         .{ "bsource.sym", .behavioral },            .{ "asrc.sym", .behavioral },
    .{ "behavioral.sym", .behavioral },

    // ── Specialized ──
      .{ "vcvs.sym", .vcvs },                     .{ "vccs.sym", .vccs },
    .{ "ccvs.sym", .ccvs },               .{ "cccs.sym", .cccs },                     .{ "k.sym", .coupling },
    .{ "tline.sym", .tline },             .{ "tline_lossy.sym", .tline_lossy },       .{ "switch.sym", .vswitch },
    .{ "vswitch.sym", .vswitch },         .{ "sw.sym", .vswitch },                    .{ "switch_ngspice.sym", .vswitch },
    .{ "switch_v_xyce.sym", .vswitch },   .{ "iswitch.sym", .iswitch },               .{ "csw.sym", .iswitch },

    // ── Non-electrical / UI ──
    .{ "gnd.sym", .gnd },                 .{ "vdd.sym", .vdd },                       .{ "lab_pin.sym", .lab_pin },
    .{ "lab_wire.sym", .lab_pin },        .{ "ipin.sym", .lab_pin },                  .{ "opin.sym", .lab_pin },
    .{ "iopin.sym", .lab_pin },           .{ "code.sym", .code },                     .{ "code_shown.sym", .code },
    .{ "simulator_commands.sym", .code }, .{ "simulator_commands_shown.sym", .code }, .{ "graph.sym", .graph },
    .{ "launcher.sym", .graph },          .{ "noconn.sym", .graph },                  .{ "title.sym", .graph },
    .{ "ngspice_probe.sym", .graph },     .{ "verilog_timescale.sym", .graph },       .{ "lab_show.sym", .graph },
});

/// Infer DeviceKind from symbol basename; falls through prefix checks then returns .unknown.
pub fn inferDeviceKind(symbol: []const u8) sch.DeviceKind {
    const base = if (std.mem.lastIndexOfScalar(u8, symbol, '/')) |idx| symbol[idx + 1 ..] else symbol;
    if (device_kind_map.get(base)) |kind| return kind;

    // ── Heuristics (prefix-based) ──
    if (std.mem.startsWith(u8, base, "nfet") or std.mem.startsWith(u8, base, "pfet")) return .mosfet;
    if (std.mem.startsWith(u8, base, "nmos") or std.mem.startsWith(u8, base, "pmos")) return .mosfet;
    if (std.mem.startsWith(u8, base, "res_")) return .resistor;
    if (std.mem.startsWith(u8, base, "cap_")) return .capacitor;
    if (std.mem.startsWith(u8, base, "ind_")) return .inductor;
    if (std.mem.startsWith(u8, base, "diode_")) return .diode;
    if (std.mem.startsWith(u8, base, "npn_") or std.mem.startsWith(u8, base, "pnp_")) return .bjt;

    // ── Extension-based ──
    if (std.mem.endsWith(u8, base, ".sch")) return .subckt;

    return .unknown;
}

test "Expose struct size for xschem" {
    const print = @import("std").debug.print;
    print("XSchem: {d}B\n", .{@sizeOf(XSchem)});
}
