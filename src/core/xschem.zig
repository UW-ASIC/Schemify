//! XSchem DOD Format — flat struct-of-arrays storage with integrated reader/writer.
//!
//! Types:
//!   Line/Rect
//!   Arc
//!   Circle
//!   Wire
//!   Text
//!   Pin
//!   Instance
//!   Prop
//!
//! This module handles XSchem's native .sch / .sym text format and converts
//! it to the canonical Schemify representation. All coordinates are f64 in
//! XSchem (with Schemify using i32); conversion happens in `populateSchemify`.
//!
//! ── Error Handling ────────────────────────────────────────────────────────
//!
//! Parser functions (`parseSchematic`, `parseSymbol`) never return errors.
//! Parse failures are logged as warnings via `xs.logWarn` with a line number.
//! This means a corrupt or unknown-format file produces a partial (empty) store
//! rather than an error — check `xs.logger.hasErrors()` after `readFile` to
//! detect significant failures.
//!
//! `writeFile` returns `?[]u8` (null on failure). Check `xs.logger` for details.
//!
//! To surface errors more visibly, set `xs.logger = &app_logger` before use.
//!
//! ── DRY Violation ─────────────────────────────────────────────────────────
//!
//! `PinDirection` (this file) and `schemify.PinDir` are identical enums with
//! the same 5 variants and same string encoding. The `pinDirConvert` function
//! in this file is a trivial 1:1 mapping. Consider unifying them:
//!   - Import `schemify.PinDir` and use it directly in `XSchem.Pin`.
//!   - Or keep both but add a compile-time assertion that the values match:
//!       comptime { std.debug.assert(@intFromEnum(PinDirection.input) ==
//!                                   @intFromEnum(sch.PinDir.input)); }
//!
//! ── PDKLoader Extension ────────────────────────────────────────────────────
//!
//! `inferDeviceKind` is the key function for XSchem → Schemify device mapping.
//! It uses hardcoded PDK prefix strings to recognise PDK cells. To extend it
//! for new PDKs without modifying the source:
//!
//!   Option A: PDKLoader populates a global prefix table that `inferDeviceKind`
//!   consults at runtime:
//!     var g_pdk_prefixes: List(struct { prefix: []const u8, kind: DeviceKind }) = .{};
//!
//!   Option B: After XSchem reads the schematic, the PDKLoader post-processes
//!   instances by looking up each symbol path in EasyPDK.primitives and
//!   EasyPDK.components. If found, overwrite the instance.kind:
//!     for (xs.instances.slice().items(.symbol), 0..) |sym, i| {
//!         if (pdk.resolveKind(sym)) |kind|
//!             instances.items(.kind)[i] = kind;
//!     }
//!
//! Option B is cleaner because it doesn't require modifying this file and
//! operates on the already-converted Schemify store.

const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;
const log = @import("logger.zig");
const sch = @import("schemify.zig");
const Schemify = sch.Schemify;
const simd = @import("simd.zig");

// ── Value Types ─────────────────────────────────────────────────────────── //

/// Pin direction as stored in XSchem .sym files.
///
/// NOTE (DRY): This is structurally identical to `schemify.PinDir`. The two
/// are kept separate to avoid a circular import (xschem.zig imports schemify.zig).
/// `pinDirConvert` maps between them with a trivial switch.
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

// ── DOD Element Structs ─────────────────────────────────────────────────── //
//
// XSchem uses f64 coordinates throughout. Conversion to Schemify i32 happens
// in `f2i()` (round + clamp) during `populateSchemify`.
// XSchem layers are i32 (can be negative in rare cases).

pub const Line = struct { layer: i32, x0: f64, y0: f64, x1: f64, y1: f64 };
pub const Rect = struct { layer: i32, x0: f64, y0: f64, x1: f64, y1: f64 };
pub const Arc = struct { layer: i32, cx: f64, cy: f64, radius: f64, start_angle: f64, sweep_angle: f64 };
pub const Circle = struct { layer: i32, cx: f64, cy: f64, radius: f64 };
pub const Wire = struct { x0: f64, y0: f64, x1: f64, y1: f64, net_name: ?[]const u8 = null };
pub const Text = struct { content: []const u8, x: f64, y: f64, layer: i32 = 4, size: f64 = 0.4, rotation: i32 = 0 };
pub const Pin = struct { name: []const u8, x: f64, y: f64, direction: PinDirection = .inout, number: ?u32 = null };
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

// ── XSchem Store ────────────────────────────────────────────────────────── //

pub const XSchemType = enum(u1) {
    schematic,
    symbol,
};

/// The main XSchem store. Owns all element memory through `arena`.
///
/// `xtype` is set when the file was detected as a .sym (symbol) or .sch (schematic).
/// Use `toSchemify(backing)` to convert to a Schemify representation.
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

    xtype: XSchemType,

    arena: std.heap.ArenaAllocator,
    logger: ?*log.Logger = null,

    // Initialization Functions
    pub fn init(backing: Allocator) XSchem {
        return .{
            .xtype = .schematic,
            .arena = std.heap.ArenaAllocator.init(backing),
        };
    }
    pub fn deinit(self: *XSchem) void {
        self.arena.deinit();
    }

    // Utilities Functions
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

    /// Auto-detects schematic vs symbol from content.
    /// Presence of a K {} block at line start → symbol, otherwise → schematic.
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

    /// Convert this XSchem schematic to a Schemify representation.
    /// `backing` is the allocator for the returned Schemify's arena.
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
        return s;
    }

    /// Writes to owned buffer. Returns null on failure (logged).
    pub fn writeFile(self: *XSchem, a: Allocator, logger: ?*log.Logger) ?[]u8 {
        self.logger = logger;
        var buf: List(u8) = .{};
        const writer = buf.writer(a);

        if (self.xtype == .symbol) {
            self.logInfo("writing symbol: {d} pins, {d} shapes", .{
                self.pins.len, self.lines.len + self.rects.len + self.arcs.len + self.circles.len,
            });
            writeSym(writer, self) catch |e| {
                self.logErr("write sym failed: {}", .{e});
                buf.deinit(a);
                return null;
            };
        } else {
            self.logInfo("writing schematic: {d} instances, {d} wires", .{ self.instances.len, self.wires.len });
            writeSch(writer, self) catch |e| {
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

// ═══════════════════════════════════════════════════════════════════════════ //
//  Format Detection
// ═══════════════════════════════════════════════════════════════════════════ //

/// Auto-detect whether a file is a .sym (symbol) or .sch (schematic).
///
/// XSchem format markers:
///   - `K {}` (empty) → schematic header (does NOT indicate symbol)
///   - `K {type=subcircuit …}` or multiline K block → symbol
///   - `G {type=…}` → symbol (G block with a `type=` attribute)
///
/// Called by `readFile` before parsing — the correct parser is selected
/// based on the return value.
fn detectSymbol(input: []const u8) XSchemType {
    // Phase 1: If any C (instance) or N (wire) lines are present, it is
    // definitively a schematic. Real .sym files never contain C or N lines.
    // Hierarchical schematics that define their own subcircuit interface have
    // a non-empty K block BUT also have C/N lines — treat them as schematics.
    {
        var it = simd.LineIterator.init(input);
        while (it.next()) |raw| {
            const line = std.mem.trimLeft(u8, raw, " \t\r");
            if (line.len >= 2 and (line[0] == 'C' or line[0] == 'N') and
                (line[1] == ' ' or line[1] == '{'))
            {
                return .schematic;
            }
        }
    }

    // Phase 2: No C/N lines — use K/G block heuristics to distinguish a
    // pure symbol file from an empty schematic.
    var it = simd.LineIterator.init(input);
    while (it.next()) |raw| {
        const line = std.mem.trimLeft(u8, raw, " \t\r");

        // K block check — only a symbol marker when the block has non-empty content.
        // Schematics have `K {}` (empty); symbols have `K {type=subcircuit …}` or multiline.
        if (line.len >= 2 and line[0] == 'K' and (line[1] == ' ' or line[1] == '{')) {
            const open = std.mem.indexOfScalar(u8, line, '{') orelse continue;
            if (std.mem.lastIndexOfScalar(u8, line, '}')) |close| {
                if (close > open) {
                    const content = std.mem.trim(u8, line[open + 1 .. close], " \t\r\n");
                    if (content.len > 0) return .symbol;
                }
                // close <= open or empty braces → schematic `K {}` header
            } else {
                // No closing brace on same line → multiline K block → symbol
                return .symbol;
            }
        }

        // G block with any `type=` attribute marks a symbol (primitive, subcircuit, etc.).
        // Schematics always have `G {}` (empty).
        if (std.mem.startsWith(u8, line, "G {") and std.mem.indexOf(u8, line, "type=") != null) {
            return .symbol;
        }
    }
    return .schematic;
}

// ═══════════════════════════════════════════════════════════════════════════ //
//  Reader — .sch
// ═══════════════════════════════════════════════════════════════════════════ //

/// Parse a .sch (schematic) file into the XSchem store.
///
/// Dispatch table (first character of each non-empty, non-comment line):
///   C → component instance (+ optional multiline prop block)
///   N → wire (+ optional multiline label block)
///   T → text label
///   L → line shape
///   B → rectangle (B 5 = pin box in symbols; B N = regular rect in schematics)
///   A → arc or circle
///   V → Verilog body block (accumulated into `verilog_body`)
///   * → comment line (skipped)
///   other header chars (v, G, K, S, …) → skipped
///
/// The `skip_depth` counter tracks brace nesting for blocks we skip entirely
/// (e.g. T-blocks with multiline content we don't use).
fn parseSchematic(xs: *XSchem, input: []const u8) void {
    const a = xs.alloc();

    var it = simd.LineIterator.init(input);
    var cur_inst_idx: ?usize = null;
    var in_props = false;
    var skip_depth: u32 = 0;
    var line_num: u32 = 0;

    var in_v: bool = false;
    var v_depth: u32 = 0;
    var v_buf: List(u8) = .{};
    defer v_buf.deinit(a);

    // Multiline wire label state: buffer for `N x0 y0 x1 y1 {\nlab=X\n}` spans
    var in_wire: bool = false;
    var wire_buf: List(u8) = .{};
    defer wire_buf.deinit(a);

    while (it.next()) |raw| {
        line_num += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '*') continue;

        // ── V {} Verilog body capture ──────────────────────────────
        if (in_v) {
            var ended = false;
            for (line) |c| {
                if (c == '{') v_depth += 1 else if (c == '}') {
                    v_depth -= 1;
                    if (v_depth == 0) {
                        in_v = false;
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
        }
        if (line.len >= 1 and line[0] == 'V' and (line.len == 1 or line[1] == ' ' or line[1] == '{')) {
            const open_idx = std.mem.indexOfScalar(u8, line, '{') orelse continue;
            v_depth = 0;
            var ended = false;
            for (line[open_idx..]) |c| {
                if (c == '{') v_depth += 1 else if (c == '}') {
                    v_depth -= 1;
                    if (v_depth == 0) {
                        ended = true;
                        break;
                    }
                }
            }
            if (!ended) {
                in_v = true;
                const after = open_idx + 1;
                if (after < line.len) {
                    const first = std.mem.trim(u8, line[after..], " \t");
                    if (first.len > 0) {
                        v_buf.appendSlice(a, first) catch {};
                        v_buf.append(a, '\n') catch {};
                    }
                }
            } else {
                const after = open_idx + 1;
                const close = std.mem.lastIndexOfScalar(u8, line, '}') orelse line.len;
                if (close > after) {
                    const content = std.mem.trim(u8, line[after..close], " \t");
                    if (content.len > 0) v_buf.appendSlice(a, content) catch {};
                }
            }
            continue;
        }

        // ── Multiline wire label ───────────────────────────────────
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

        // ── Skip blocks ────────────────────────────────────────────
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
        if (std.mem.startsWith(u8, line, "v {")) continue;
        if (line.len == 1 and isHeaderChar(line[0])) continue;
        if (line.len >= 3 and isHeaderChar(line[0]) and line[1] == ' ' and line[2] == '{') continue;

        // ── Multiline instance props ───────────────────────────────
        if (cur_inst_idx != null and in_props) {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.indexOfScalar(u8, trimmed, '}')) |close_idx| {
                // Support inline multiline termination like `...;}` (common in
                // use.sym/code blocks). Parse only the prefix before `}`.
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
            parsePropLine(a, line, &xs.props, &xs.instances, cur_inst_idx.?) catch |e| {
                xs.logWarn("line {d}: prop parse failed: {}", .{ line_num, e });
            };
            continue;
        }

        // ── Line dispatch ──────────────────────────────────────────
        switch (line[0]) {
            'C' => {
                const idx = xs.instances.len;
                const multi = parseComponent(a, line, &xs.instances, &xs.props) catch |e| {
                    xs.logWarn("line {d}: component parse failed: {}", .{ line_num, e });
                    continue;
                };
                if (multi) {
                    cur_inst_idx = idx;
                    in_props = true;
                }
            },
            'N' => {
                // Detect multiline wire label: `N x0 y0 x1 y1 {` with no closing `}`
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
                if (!ok) countBraces(line, &skip_depth);
            },
            'L' => parseLine(a, line, &xs.lines),
            'B' => {
                parseRect(a, line, &xs.rects);
                countBraces(line, &skip_depth);
            },
            'A' => parseArcLine(a, line, &xs.arcs, &xs.circles),
            else => {},
        }
    }

    const trimmed = std.mem.trim(u8, v_buf.items, " \t\n\r");
    if (trimmed.len > 0)
        xs.verilog_body = a.dupe(u8, trimmed) catch null;

    xs.logInfo("parsed schematic: {d} instances, {d} wires, {d} shapes", .{
        xs.instances.len, xs.wires.len, xs.lines.len + xs.rects.len + xs.arcs.len + xs.circles.len,
    });
}

// ═══════════════════════════════════════════════════════════════════════════ //
//  Reader — .sym
// ═══════════════════════════════════════════════════════════════════════════ //

/// Parse a .sym (symbol) file into the XSchem store.
///
/// Dispatch table (first character of each non-empty, non-comment line):
///   K → symbol property block (K { key=val ... }) — may be multiline
///   B → pin box (B 5 { pin=name … }) or regular rect — may be multiline
///   L → line shape
///   T → text label
///   A → arc or circle
///   other header chars → skipped via the same isHeaderChar guard as schematic
///
/// Pin detection: `parsePinBox` returns true when the B line contains
/// `{ type=pin … }` attributes, false for regular rects.
///
/// NOTE: Symbol files do not have C (component) or N (wire) lines. If found,
/// they will be silently ignored (no matching case in the switch).
fn parseSymbol(xs: *XSchem, input: []const u8) void {
    const a = xs.alloc();

    var it = simd.LineIterator.init(input);
    var in_k = false;
    var in_b = false; // multiline B 5 pin/rect block
    var k_buf: List(u8) = .{};
    var b_buf: List(u8) = .{}; // accumulates a multiline B line
    defer k_buf.deinit(a);
    defer b_buf.deinit(a);
    var line_num: u32 = 0;

    while (it.next()) |raw| {
        line_num += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '*') continue;

        // Accumulate continuation of a multiline B block
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
                if (!is_pin) parseRect(a, full, &xs.rects);
                b_buf.clearRetainingCapacity();
            }
            continue;
        }

        if (in_k) {
            if (std.mem.indexOfScalar(u8, line, '}')) |end| {
                if (end > 0) k_buf.appendSlice(a, line[0..end]) catch {};
                parsePropsRaw(a, k_buf.items, &xs.props) catch |e| {
                    xs.logWarn("line {d}: K block props failed: {}", .{ line_num, e });
                };
                k_buf.clearRetainingCapacity();
                in_k = false;
            } else {
                k_buf.append(a, ' ') catch {};
                k_buf.appendSlice(a, line) catch {};
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "v {")) continue;
        if (line.len >= 3 and isHeaderChar(line[0]) and line[0] != 'K' and line[0] != 'G' and line[1] == ' ' and line[2] == '{') continue;

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
                    k_buf.clearRetainingCapacity();
                    k_buf.appendSlice(a, line[open + 1 ..]) catch {};
                }
            },
            'B' => {
                // Check if the prop block closes on this line
                const has_close = std.mem.lastIndexOfScalar(u8, line, '}') != null;
                if (has_close) {
                    const is_pin = parsePinBox(a, line, &xs.pins) catch |e| blk: {
                        xs.logWarn("line {d}: pin parse failed: {}", .{ line_num, e });
                        break :blk false;
                    };
                    if (!is_pin) parseRect(a, line, &xs.rects);
                } else if (std.mem.indexOfScalar(u8, line, '{') != null) {
                    // Multiline B block — buffer and accumulate
                    in_b = true;
                    b_buf.clearRetainingCapacity();
                    b_buf.appendSlice(a, line) catch {};
                } else {
                    parseRect(a, line, &xs.rects);
                }
            },
            'L' => parseLine(a, line, &xs.lines),
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

// ═══════════════════════════════════════════════════════════════════════════ //
//  Writer — .sch
// ═══════════════════════════════════════════════════════════════════════════ //

/// Write all shape elements (lines, rects, arcs, circles) in XSchem format.
///
/// Each element is written as a fixed-width prefix char + layer number + coords.
/// Circles are encoded as arcs with `start_angle=0 sweep_angle=360`.
///
/// The [96]u8 stack buffer is large enough for the longest possible line:
///   "A " + layer(3) + 4×coords(each max 12) + 2×angles(each max 5) + " {}\n"
///   ≈ 2 + 3 + 48 + 10 + 5 = 68 bytes. 96 gives comfortable headroom.
fn writeShapesXS(w: anytype, xs: *const XSchem) !void {
    var buf: [96]u8 = undefined;

    const ls = xs.lines.slice();
    for (0..xs.lines.len) |i| {
        var n: usize = 0;
        buf[n] = 'L';
        n += 1;
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], ls.items(.layer)[i]);
        n += bufWriteF64_4(&buf, n, ls.items(.x0)[i], ls.items(.y0)[i], ls.items(.x1)[i], ls.items(.y1)[i]);
        try w.writeAll(buf[0..n]);
        try w.writeAll(" {}\n");
    }

    const rs = xs.rects.slice();
    for (0..xs.rects.len) |i| {
        var n: usize = 0;
        buf[n] = 'B';
        n += 1;
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], rs.items(.layer)[i]);
        n += bufWriteF64_4(&buf, n, rs.items(.x0)[i], rs.items(.y0)[i], rs.items(.x1)[i], rs.items(.y1)[i]);
        try w.writeAll(buf[0..n]);
        try w.writeAll(" {}\n");
    }

    const as_ = xs.arcs.slice();
    for (0..xs.arcs.len) |i| {
        var n: usize = 0;
        buf[n] = 'A';
        n += 1;
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], as_.items(.layer)[i]);
        n += bufWriteF64_4(&buf, n, as_.items(.cx)[i], as_.items(.cy)[i], as_.items(.radius)[i], as_.items(.start_angle)[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeF64(buf[n..], as_.items(.sweep_angle)[i]);
        try w.writeAll(buf[0..n]);
        try w.writeAll(" {}\n");
    }

    const cs = xs.circles.slice();
    for (0..xs.circles.len) |i| {
        var n: usize = 0;
        buf[n] = 'A';
        n += 1;
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], cs.items(.layer)[i]);
        n += bufWriteF64_3(&buf, n, cs.items(.cx)[i], cs.items(.cy)[i], cs.items(.radius)[i]);
        try w.writeAll(buf[0..n]);
        try w.writeAll(" 0 360 {}\n");
    }
}

fn writeTextsXS(w: anytype, xs: *const XSchem) !void {
    var buf: [96]u8 = undefined;
    const ts = xs.texts.slice();
    for (0..xs.texts.len) |i| {
        try w.writeAll("T {");
        try w.writeAll(ts.items(.content)[i]);
        try w.writeAll("} ");
        var n: usize = 0;
        n += simd.writeF64(buf[n..], ts.items(.x)[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeF64(buf[n..], ts.items(.y)[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], ts.items(.layer)[i]);
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

fn bufWriteF64_3(buf: *[96]u8, start: usize, a: f64, b: f64, c: f64) usize {
    var n: usize = 0;
    buf[start + n] = ' ';
    n += 1;
    n += simd.writeF64(buf[start + n ..], a);
    buf[start + n] = ' ';
    n += 1;
    n += simd.writeF64(buf[start + n ..], b);
    buf[start + n] = ' ';
    n += 1;
    n += simd.writeF64(buf[start + n ..], c);
    return n;
}

fn bufWriteF64_4(buf: *[96]u8, start: usize, a: f64, b: f64, c: f64, d: f64) usize {
    var n = bufWriteF64_3(buf, start, a, b, c);
    buf[start + n] = ' ';
    n += 1;
    n += simd.writeF64(buf[start + n ..], d);
    return n;
}

fn writeSch(w: anytype, xs: *const XSchem) !void {
    try w.writeAll("v {xschem version=3.4.4 file_version=1.2\n}\nG {}\nK {}\nV {}\nS {}\nE {}\n");

    var buf: [96]u8 = undefined;
    const ws = xs.wires.slice();
    for (0..xs.wires.len) |i| {
        var n: usize = 0;
        buf[n] = 'N';
        n += 1;
        n += bufWriteF64_4(&buf, n, ws.items(.x0)[i], ws.items(.y0)[i], ws.items(.x1)[i], ws.items(.y1)[i]);
        buf[n] = ' ';
        n += 1;
        buf[n] = '{';
        n += 1;
        try w.writeAll(buf[0..n]);
        if (ws.items(.net_name)[i]) |name| {
            try w.writeAll("lab=");
            try w.writeAll(name);
        }
        try w.writeAll("}\n");
    }

    const ins = xs.instances.slice();
    for (0..xs.instances.len) |i| {
        try w.writeAll("C {");
        try w.writeAll(ins.items(.symbol)[i]);
        try w.writeAll("} ");
        var n: usize = 0;
        n += simd.writeF64(buf[n..], ins.items(.x)[i]);
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
        n += 1;
        buf[n] = '{';
        n += 1;
        try w.writeAll(buf[0..n]);
        const nm = ins.items(.name)[i];
        if (nm.len > 0) {
            try w.writeAll("name=");
            try w.writeAll(nm);
            try w.writeAll("\n");
        }
        const ps = ins.items(.prop_start)[i];
        const pc = ins.items(.prop_count)[i];
        for (xs.props.items[ps..][0..pc]) |p| {
            if (std.mem.eql(u8, p.key, "name")) continue;
            try writePropKV(w, p.key, p.value);
        }
        try w.writeAll("}\n");
    }

    try writeTextsXS(w, xs);
    try writeShapesXS(w, xs);
}

// ═══════════════════════════════════════════════════════════════════════════ //
//  Writer — .sym
// ═══════════════════════════════════════════════════════════════════════════ //

fn writeSym(w: anytype, xs: *const XSchem) !void {
    try w.writeAll("v {xschem version=3.4.4 file_version=1.2\n}\nG {}\n");
    try w.writeAll("K {type=subcircuit\nformat=\"@name @pinlist @symname\"\ntemplate=\"name=x1\"\n");
    for (xs.props.items) |p| {
        if (std.mem.eql(u8, p.key, "type") or std.mem.eql(u8, p.key, "format") or std.mem.eql(u8, p.key, "template")) continue;
        try writePropKV(w, p.key, p.value);
    }
    try w.writeAll("}\nV {}\nS {}\nE {}\n");

    try writeShapesXS(w, xs);

    var buf: [96]u8 = undefined;
    const ps = xs.pins.slice();
    const h: f64 = 5.0;
    for (0..xs.pins.len) |i| {
        const px = ps.items(.x)[i];
        const py = ps.items(.y)[i];
        var n: usize = 0;
        @memcpy(buf[n..][0..4], "B 5 ");
        n += 4;
        n += bufWriteF64_4(&buf, n, px - h / 2, py - h / 2, px + h / 2, py + h / 2);
        try w.writeAll(buf[0..n]);
        try w.writeAll(" {name=");
        try w.writeAll(ps.items(.name)[i]);
        try w.writeAll(" dir=");
        try w.writeAll(ps.items(.direction)[i].toStr());
        if (ps.items(.number)[i]) |num| {
            try w.writeAll(" pinnumber=");
            var nb: [11]u8 = undefined;
            const nlen = simd.writeI32(nb[0..], @as(i32, @intCast(num)));
            try w.writeAll(nb[0..nlen]);
        }
        try w.writeAll("}\n");
    }

    try writeTextsXS(w, xs);
}

// ═══════════════════════════════════════════════════════════════════════════ //
//  Internals — Parsing
// ═══════════════════════════════════════════════════════════════════════════ //

fn isHeaderChar(c: u8) bool {
    return c == 'G' or c == 'K' or c == 'V' or c == 'S' or c == 'E';
}

fn countBraces(line: []const u8, depth: *u32) void {
    for (line) |c| {
        if (c == '{') depth.* += 1;
        if (c == '}') {
            if (depth.* > 0) depth.* -= 1;
        }
    }
}

fn parseComponent(a: Allocator, line: []const u8, instances: *MAL(Instance), props: *List(Prop)) !bool {
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

    const ps = simd.findByte(rest, '{');
    if (ps) |p| {
        const pe = std.mem.lastIndexOfScalar(u8, rest, '}');
        if (pe) |q| {
            try parsePropsInto(a, rest[p + 1 .. q], props, &inst_name);
        } else {
            try parsePropsInto(a, rest[p + 1 ..], props, &inst_name);
            multi = true;
        }
    }

    try instances.append(a, .{
        .name = inst_name,
        .symbol = sym,
        .x = x,
        .y = y,
        .rot = rot,
        .flip = flp != 0,
        .prop_start = prop_start,
        .prop_count = @intCast(props.items.len - prop_start),
    });
    return multi;
}

fn parseWire(a: Allocator, line: []const u8, wires: *MAL(Wire)) !void {
    if (line.len < 3) return;
    const data = line[2..];
    var pos: usize = 0;
    const x0 = simd.nextF64(data, &pos) orelse return;
    const y0 = simd.nextF64(data, &pos) orelse return;
    const x1 = simd.nextF64(data, &pos) orelse return;
    const y1 = simd.nextF64(data, &pos) orelse return;
    var net: ?[]const u8 = null;
    if (simd.findByte(line, '{')) |s| {
        if (std.mem.lastIndexOfScalar(u8, line, '}')) |e| {
            net = try extractLabel(a, line[s + 1 .. e]);
        }
    }

    try wires.append(a, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .net_name = net });
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
    try texts.append(a, .{ .content = content, .x = x, .y = y, .layer = layer });
    return true;
}

fn parseLine(a: Allocator, line: []const u8, lines: *MAL(Line)) void {
    if (line.len < 3) return;
    const end = simd.findByte(line, '{') orelse line.len;
    const data = line[2..end];
    var pos: usize = 0;
    const ly = simd.nextI32(data, &pos) orelse return;
    const x0 = simd.nextF64(data, &pos) orelse return;
    const y0 = simd.nextF64(data, &pos) orelse return;
    const x1 = simd.nextF64(data, &pos) orelse return;
    const y1 = simd.nextF64(data, &pos) orelse return;
    lines.append(a, .{ .layer = ly, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }) catch return;
}

fn parseRect(a: Allocator, line: []const u8, rects: *MAL(Rect)) void {
    if (line.len < 3) return;
    const end = simd.findByte(line, '{') orelse line.len;
    const data = line[2..end];
    var pos: usize = 0;
    const ly = simd.nextI32(data, &pos) orelse return;
    const x0 = simd.nextF64(data, &pos) orelse return;
    const y0 = simd.nextF64(data, &pos) orelse return;
    const x1 = simd.nextF64(data, &pos) orelse return;
    const y1 = simd.nextF64(data, &pos) orelse return;
    rects.append(a, .{ .layer = ly, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }) catch return;
}

fn parseArcLine(a: Allocator, line: []const u8, arcs: *MAL(Arc), circles: *MAL(Circle)) void {
    if (line.len < 3) return;
    const end = simd.findByte(line, '{') orelse line.len;
    const data = line[2..end];
    var pos: usize = 0;
    const ly = simd.nextI32(data, &pos) orelse return;
    const cx = simd.nextF64(data, &pos) orelse return;
    const cy = simd.nextF64(data, &pos) orelse return;
    const r = simd.nextF64(data, &pos) orelse return;
    const sa = simd.nextF64(data, &pos) orelse return;
    const sw = simd.nextF64(data, &pos) orelse return;
    if (sa == 0 and sw == 360) {
        circles.append(a, .{ .layer = ly, .cx = cx, .cy = cy, .radius = r }) catch return;
    } else {
        arcs.append(a, .{ .layer = ly, .cx = cx, .cy = cy, .radius = r, .start_angle = sa, .sweep_angle = sw }) catch return;
    }
}

fn parsePinBox(a: Allocator, line: []const u8, pins: *MAL(Pin)) !bool {
    const sb = simd.findByte(line, '{') orelse return false;
    const eb = std.mem.lastIndexOfScalar(u8, line, '}') orelse return false;
    if (sb >= eb) return false;

    var pname: ?[]const u8 = null;
    var have_primary_name = false;
    var dir = PinDirection.inout;
    var num: ?u32 = null;
    var ptok = PropTokenizer.init(line[sb + 1 .. eb]);
    while (ptok.next()) |p| {
        if (std.mem.eql(u8, p.key, "name")) {
            // XSchem pin boxes can repeat `name=` where the first value is the
            // logical pin label and a later one is an internal identifier (p1..).
            // Keep the first name so exported .subckt pin names match xschem.
            if (!have_primary_name) {
                pname = try a.dupe(u8, stripQ(p.val));
                have_primary_name = true;
            }
        } else if (std.mem.eql(u8, p.key, "dir")) {
            dir = PinDirection.fromStr(p.val);
        } else if (std.mem.eql(u8, p.key, "pinnumber")) {
            num = std.fmt.parseInt(u32, p.val, 10) catch null;
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
    try pins.append(a, .{ .name = pname.?, .x = (x0 + x1) / 2, .y = (y0 + y1) / 2, .direction = dir, .number = num });
    return true;
}

// ── Property helpers ────────────────────────────────────────────────────── //

fn parsePropLine(a: Allocator, line: []const u8, props: *List(Prop), instances: *MAL(Instance), idx: usize) !void {
    var tok = PropTokenizer.init(line);
    while (tok.next()) |p| {
        const k = try a.dupe(u8, p.key);
        const v = try a.dupe(u8, stripQ(p.val));
        if (std.mem.eql(u8, k, "name"))
            instances.slice().items(.name)[idx] = v;
        try props.append(a, .{ .key = k, .value = v });
        instances.slice().items(.prop_count)[idx] += 1;
    }
}

fn parsePropsInto(a: Allocator, s: []const u8, props: *List(Prop), name: *[]const u8) !void {
    var tok = PropTokenizer.init(s);
    while (tok.next()) |p| {
        const k = try a.dupe(u8, p.key);
        const v = try a.dupe(u8, stripQ(p.val));
        if (std.mem.eql(u8, k, "name")) name.* = v;
        try props.append(a, .{ .key = k, .value = v });
    }
}

fn parsePropsRaw(a: Allocator, s: []const u8, props: *List(Prop)) !void {
    var tok = PropTokenizer.init(s);
    while (tok.next()) |p|
        try props.append(a, .{ .key = try a.dupe(u8, p.key), .value = try a.dupe(u8, stripQ(p.val)) });
}

fn extractLabel(a: Allocator, s: []const u8) !?[]const u8 {
    var tok = PropTokenizer.init(s);
    while (tok.next()) |p| if (std.mem.eql(u8, p.key, "lab")) return try a.dupe(u8, stripQ(p.val));
    return null;
}

fn stripQ(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\'')))
        return s[1 .. s.len - 1];
    return s;
}

fn needsQ(v: []const u8) bool {
    for (v) |c| if (c == ' ' or c == '\t' or c == '"' or c == '\'' or c == '@' or c == '\n') return true;
    return false;
}

fn writePropKV(w: anytype, key: []const u8, value: []const u8) !void {
    try w.writeAll(key);
    try w.writeAll("=");
    if (needsQ(value)) {
        try w.writeAll("\"");
        try w.writeAll(value);
        try w.writeAll("\"\n");
    } else {
        try w.writeAll(value);
        try w.writeAll("\n");
    }
}

// ── Property Tokenizer ──────────────────────────────────────────────────── //

const PropTokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    const Tok = struct { key: []const u8, val: []const u8 };

    fn init(src: []const u8) PropTokenizer {
        return .{ .src = src };
    }

    fn next(self: *PropTokenizer) ?Tok {
        while (self.pos < self.src.len and isWs(self.src[self.pos])) self.pos += 1;
        if (self.pos >= self.src.len) return null;
        const ks = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '=') self.pos += 1;
        if (self.pos >= self.src.len) return null;
        const key = self.src[ks..self.pos];
        self.pos += 1;
        if (self.pos >= self.src.len) return null;
        if (self.src[self.pos] == '"' or self.src[self.pos] == '\'') {
            const q = self.src[self.pos];
            self.pos += 1;
            const vs = self.pos;
            // Handle escaped quotes (\" inside "..." values)
            while (self.pos < self.src.len) {
                if (self.src[self.pos] == q and (self.pos == vs or self.src[self.pos - 1] != '\\')) break;
                self.pos += 1;
            }
            const val = self.src[vs..self.pos];
            if (self.pos < self.src.len) self.pos += 1;
            return .{ .key = key, .val = val };
        }
        const vs = self.pos;
        while (self.pos < self.src.len and !isWs(self.src[self.pos])) self.pos += 1;
        return .{ .key = key, .val = self.src[vs..self.pos] };
    }

    fn isWs(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

// ═══════════════════════════════════════════════════════════════════════════ //
//  XSchem → Schemify Conversion Helpers
// ═══════════════════════════════════════════════════════════════════════════ //

fn f2i(v: f64) i32 {
    const clamped = @max(@as(f64, -2147483648.0), @min(@as(f64, 2147483647.0), v));
    return @intFromFloat(@round(clamped));
}

fn mapWires(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    const ws = xs.wires.slice();
    try s.wires.ensureTotalCapacity(a, xs.wires.len);
    for (0..xs.wires.len) |i| {
        const net: ?[]const u8 = if (ws.items(.net_name)[i]) |n| try a.dupe(u8, n) else null;
        s.wires.appendAssumeCapacity(.{
            .x0 = f2i(ws.items(.x0)[i]),
            .y0 = f2i(ws.items(.y0)[i]),
            .x1 = f2i(ws.items(.x1)[i]),
            .y1 = f2i(ws.items(.y1)[i]),
            .net_name = net,
        });
    }
}

fn mapInstances(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    const ins = xs.instances.slice();
    try s.instances.ensureTotalCapacity(a, xs.instances.len);
    for (0..xs.instances.len) |i| {
        const prop_start: u32 = @intCast(s.props.items.len);
        const ps = ins.items(.prop_start)[i];
        const pc = ins.items(.prop_count)[i];
        for (xs.props.items[ps..][0..pc]) |p| {
            try s.props.append(a, .{
                .key = try a.dupe(u8, p.key),
                .val = try a.dupe(u8, p.value),
            });
        }
        const sym = try a.dupe(u8, ins.items(.symbol)[i]);
        const kind = inferDeviceKind(sym);
        s.instances.appendAssumeCapacity(.{
            .name = try a.dupe(u8, ins.items(.name)[i]),
            .symbol = sym,
            .kind = kind,
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
        const ly = ts.items(.layer)[i];
        s.texts.appendAssumeCapacity(.{
            .content = try a.dupe(u8, ts.items(.content)[i]),
            .x = f2i(ts.items(.x)[i]),
            .y = f2i(ts.items(.y)[i]),
            .layer = if (ly >= 0 and ly <= 255) @intCast(ly) else 4,
        });
    }
}

fn mapShapes(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    try s.lines.ensureTotalCapacity(a, xs.lines.len);
    const ls = xs.lines.slice();
    for (0..xs.lines.len) |i| {
        const ly = ls.items(.layer)[i];
        s.lines.appendAssumeCapacity(.{
            .layer = if (ly >= 0 and ly <= 255) @intCast(ly) else 0,
            .x0 = f2i(ls.items(.x0)[i]),
            .y0 = f2i(ls.items(.y0)[i]),
            .x1 = f2i(ls.items(.x1)[i]),
            .y1 = f2i(ls.items(.y1)[i]),
        });
    }
    try s.rects.ensureTotalCapacity(a, xs.rects.len);
    const rs = xs.rects.slice();
    for (0..xs.rects.len) |i| {
        const ly = rs.items(.layer)[i];
        s.rects.appendAssumeCapacity(.{
            .layer = if (ly >= 0 and ly <= 255) @intCast(ly) else 0,
            .x0 = f2i(rs.items(.x0)[i]),
            .y0 = f2i(rs.items(.y0)[i]),
            .x1 = f2i(rs.items(.x1)[i]),
            .y1 = f2i(rs.items(.y1)[i]),
        });
    }
    try s.arcs.ensureTotalCapacity(a, xs.arcs.len);
    const as_ = xs.arcs.slice();
    for (0..xs.arcs.len) |i| {
        const ly = as_.items(.layer)[i];
        s.arcs.appendAssumeCapacity(.{
            .layer = if (ly >= 0 and ly <= 255) @intCast(ly) else 0,
            .cx = f2i(as_.items(.cx)[i]),
            .cy = f2i(as_.items(.cy)[i]),
            .radius = f2i(as_.items(.radius)[i]),
            .start_angle = @truncate(f2i(as_.items(.start_angle)[i])),
            .sweep_angle = @truncate(f2i(as_.items(.sweep_angle)[i])),
        });
    }
    try s.circles.ensureTotalCapacity(a, xs.circles.len);
    const cs = xs.circles.slice();
    for (0..xs.circles.len) |i| {
        const ly = cs.items(.layer)[i];
        s.circles.appendAssumeCapacity(.{
            .layer = if (ly >= 0 and ly <= 255) @intCast(ly) else 0,
            .cx = f2i(cs.items(.cx)[i]),
            .cy = f2i(cs.items(.cy)[i]),
            .radius = f2i(cs.items(.radius)[i]),
        });
    }
}

fn mapPins(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    const ps = xs.pins.slice();
    try s.pins.ensureTotalCapacity(a, xs.pins.len);
    for (0..xs.pins.len) |i| {
        s.pins.appendAssumeCapacity(.{
            .name = try a.dupe(u8, ps.items(.name)[i]),
            .x = f2i(ps.items(.x)[i]),
            .y = f2i(ps.items(.y)[i]),
            .dir = pinDirConvert(ps.items(.direction)[i]),
            .num = if (ps.items(.number)[i]) |n| @truncate(n) else null,
        });
    }
}

fn mapSymProps(a: Allocator, xs: *const XSchem, s: *Schemify) !void {
    for (xs.props.items) |p| {
        // Only add recognized symbol-level props
        if (std.mem.eql(u8, p.key, "type") or
            std.mem.eql(u8, p.key, "format") or
            std.mem.eql(u8, p.key, "template") or
            std.mem.eql(u8, p.key, "spice_ignore"))
        {
            try s.sym_props.append(a, .{
                .key = try a.dupe(u8, p.key),
                .val = try a.dupe(u8, p.value),
            });
        }
    }
}

fn pinDirConvert(d: PinDirection) sch.PinDir {
    return switch (d) {
        .input => .input,
        .output => .output,
        .inout => .inout,
        .power => .power,
        .ground => .ground,
    };
}

/// Infer DeviceKind from the XSchem symbol path.
fn inferDeviceKind(symbol: []const u8) sch.DeviceKind {
    // Strip directory prefix to get the base name
    const base = if (std.mem.lastIndexOfScalar(u8, symbol, '/')) |idx| symbol[idx + 1 ..] else symbol;
    // Check well-known XSchem symbol names
    const map = .{
        .{ "res.sym", sch.DeviceKind.resistor },
        .{ "capa.sym", sch.DeviceKind.capacitor },
        .{ "ind.sym", sch.DeviceKind.inductor },
        .{ "diode.sym", sch.DeviceKind.diode },
        .{ "nmos4.sym", sch.DeviceKind.mosfet },
        .{ "pmos4.sym", sch.DeviceKind.mosfet },
        .{ "npn.sym", sch.DeviceKind.bjt },
        .{ "pnp.sym", sch.DeviceKind.bjt },
        .{ "njfet.sym", sch.DeviceKind.jfet },
        .{ "pjfet.sym", sch.DeviceKind.jfet },
        .{ "vsource.sym", sch.DeviceKind.vsource },
        .{ "isource.sym", sch.DeviceKind.isource },
        .{ "ammeter.sym", sch.DeviceKind.ammeter },
        .{ "vcvs.sym", sch.DeviceKind.vcvs },
        .{ "vccs.sym", sch.DeviceKind.vccs },
        .{ "ccvs.sym", sch.DeviceKind.ccvs },
        .{ "cccs.sym", sch.DeviceKind.cccs },
        .{ "gnd.sym", sch.DeviceKind.gnd },
        .{ "vdd.sym", sch.DeviceKind.vdd },
        .{ "lab_pin.sym", sch.DeviceKind.lab_pin },
        .{ "lab_wire.sym", sch.DeviceKind.lab_pin },
        .{ "code.sym", sch.DeviceKind.code },
        .{ "code_shown.sym", sch.DeviceKind.code },
        .{ "graph.sym", sch.DeviceKind.graph },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, base, entry[0])) return entry[1];
    }
    // PDK prefix heuristics
    if (std.mem.startsWith(u8, base, "nfet") or std.mem.startsWith(u8, base, "pfet"))
        return .mosfet;
    return .unknown;
}
