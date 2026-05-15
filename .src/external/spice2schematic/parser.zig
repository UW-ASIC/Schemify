// parser.zig — SPICE netlist parser.
//
// Parses ngspice/HSPICE netlists into structured data suitable for
// schematic conversion. Handles:
//   - Line continuation (+ prefix)
//   - Comment lines (* prefix) and inline comments ($ or ;)
//   - All standard element types: R C L D M Q J V I E G F H B X
//   - .SUBCKT/.ENDS blocks with ports and parameters
//   - .MODEL statements
//   - .PARAM directives
//   - .GLOBAL declarations
//   - .TITLE directive
//   - .END terminator
//
// Design: Arena-allocated, zero-copy where possible (slices into source).

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

// ── Public types ────────────────────────────────────────────────────────────

pub const Param = struct {
    key: []const u8,
    val: []const u8,
};

pub const Element = struct {
    prefix: u8, // lowercase single char: 'r', 'c', 'm', etc.
    name: []const u8, // e.g. "M1", "R3"
    nodes: []const []const u8, // ordered net names
    value: ?[]const u8 = null, // R/C/L/V value string; null for M/Q/D
    model: ?[]const u8 = null, // model name for M/Q/D/J; subckt name for X
    params: []const Param = &.{}, // key=value pairs
};

pub const Model = struct {
    name: []const u8,
    kind: []const u8, // "nmos", "pmos", "npn", "pnp", "d", etc.
};

pub const Subckt = struct {
    name: []const u8,
    ports: []const []const u8,
    elements: []const Element,
    params: []const Param = &.{},
};

pub const Netlist = struct {
    title: []const u8 = "",
    subckts: []const Subckt = &.{},
    top_elements: []const Element = &.{},
    models: []const Model = &.{},
    params: []const Param = &.{},
    globals: []const []const u8 = &.{},
};

// ── Main entry point ────────────────────────────────────────────────────────

/// Parse a SPICE netlist source string into structured data.
/// All allocations use `arena`. Returned slices are valid for arena lifetime.
pub fn parseNetlist(arena: Allocator, source: []const u8) !Netlist {
    const lines = try collectLogicalLines(arena, source);
    if (lines.len == 0) return .{};

    const title = lines[0];

    var subckts: List(Subckt) = .{};
    var top_elements: List(Element) = .{};
    var models: List(Model) = .{};
    var params: List(Param) = .{};
    var globals: List([]const u8) = .{};

    // Subcircuit parsing state
    var in_subckt = false;
    var sc_name: []const u8 = "";
    var sc_ports: List([]const u8) = .{};
    var sc_elems: List(Element) = .{};
    var sc_params: List(Param) = .{};

    for (lines[1..]) |line| {
        if (line.len == 0) continue;
        const lo0 = std.ascii.toLower(line[0]);

        // Dot commands
        if (lo0 == '.') {
            const toks = try tokenize(arena, line);
            if (toks.len == 0) continue;
            const cmd = try toLowerSlice(arena, toks[0]);

            if (std.mem.eql(u8, cmd, ".subckt")) {
                if (toks.len >= 2) {
                    in_subckt = true;
                    sc_name = toks[1];
                    sc_ports.items.len = 0;
                    sc_elems.items.len = 0;
                    sc_params.items.len = 0;
                    for (toks[2..]) |tok| {
                        if (std.mem.indexOfScalar(u8, tok, '=') != null) {
                            if (parseOneParam(tok)) |param| try sc_params.append(arena, param);
                        } else {
                            try sc_ports.append(arena, tok);
                        }
                    }
                }
            } else if (std.mem.eql(u8, cmd, ".ends")) {
                if (in_subckt) {
                    try subckts.append(arena, .{
                        .name = sc_name,
                        .ports = try arena.dupe([]const u8, sc_ports.items),
                        .elements = try arena.dupe(Element, sc_elems.items),
                        .params = try arena.dupe(Param, sc_params.items),
                    });
                    in_subckt = false;
                }
            } else if (std.mem.eql(u8, cmd, ".model")) {
                if (toks.len >= 3) {
                    try models.append(arena, .{ .name = toks[1], .kind = toks[2] });
                }
            } else if (std.mem.eql(u8, cmd, ".param")) {
                const parsed = try parseParams(arena, toks, 1);
                for (parsed) |p| try params.append(arena, p);
            } else if (std.mem.eql(u8, cmd, ".global")) {
                for (toks[1..]) |g| try globals.append(arena, g);
            } else if (std.mem.eql(u8, cmd, ".end")) {
                break;
            }
            // Skip other dot commands (.op, .dc, .ac, .tran, etc.)
            continue;
        }

        // Element instance line
        if (parseElement(arena, line)) |elem| {
            if (in_subckt) {
                try sc_elems.append(arena, elem);
            } else {
                try top_elements.append(arena, elem);
            }
        } else |_| {
            continue;
        }
    }

    // Handle unclosed subckt (malformed input)
    if (in_subckt and sc_elems.items.len > 0) {
        try subckts.append(arena, .{
            .name = sc_name,
            .ports = try arena.dupe([]const u8, sc_ports.items),
            .elements = try arena.dupe(Element, sc_elems.items),
            .params = try arena.dupe(Param, sc_params.items),
        });
    }

    return .{
        .title = title,
        .subckts = try arena.dupe(Subckt, subckts.items),
        .top_elements = try arena.dupe(Element, top_elements.items),
        .models = try arena.dupe(Model, models.items),
        .params = try arena.dupe(Param, params.items),
        .globals = try arena.dupe([]const u8, globals.items),
    };
}

// ── Phase 1: Logical line collection ────────────────────────────────────────

/// Join continuation lines (+ prefix), strip comments, return logical lines.
/// First entry is the title. All subsequent entries are content lines.
fn collectLogicalLines(arena: Allocator, source: []const u8) ![]const []const u8 {
    var lines: List([]const u8) = .{};
    var pending: List(u8) = .{};

    var first_line = true;
    var iter = std.mem.splitScalar(u8, source, '\n');

    while (iter.next()) |raw_line| {
        // Strip trailing \r and whitespace
        var line = std.mem.trimRight(u8, raw_line, "\r \t");

        // Strip inline comments
        line = trimInlineComment(line);

        // Title line (first non-blank line in file)
        if (first_line) {
            first_line = false;
            if (line.len > 0 and line[0] == '*') {
                try lines.append(arena, std.mem.trimLeft(u8, line[1..], " \t"));
            } else if (line.len >= 6 and startsWithLower(line, ".title")) {
                try lines.append(arena, std.mem.trimLeft(u8, line[6..], " \t"));
            } else {
                try lines.append(arena, ""); // empty title placeholder
                // Process this line as content
                const trimmed = std.mem.trim(u8, line, " \t");
                if (trimmed.len > 0 and trimmed[0] != '*') {
                    try pending.appendSlice(arena, trimmed);
                }
            }
            continue;
        }

        // Skip blank/comment lines
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '*') continue;

        // Continuation line (+ prefix)
        if (trimmed[0] == '+') {
            const rest = std.mem.trimLeft(u8, trimmed[1..], " \t");
            if (rest.len > 0) {
                if (pending.items.len > 0) {
                    try pending.append(arena, ' ');
                }
                try pending.appendSlice(arena, rest);
            }
            continue;
        }

        // Regular line: flush pending, start new
        if (pending.items.len > 0) {
            const duped = try arena.dupe(u8, pending.items);
            try lines.append(arena, duped);
            pending.items.len = 0;
        }
        try pending.appendSlice(arena, trimmed);
    }

    // Flush final pending
    if (pending.items.len > 0) {
        const duped = try arena.dupe(u8, pending.items);
        try lines.append(arena, duped);
    }

    return lines.items;
}

/// Strip inline comments ($ or ;) respecting quotes.
fn trimInlineComment(line: []const u8) []const u8 {
    var in_single_quote = false;
    var in_double_quote = false;
    for (line, 0..) |c, i| {
        switch (c) {
            '\'' => if (!in_double_quote) {
                in_single_quote = !in_single_quote;
            },
            '"' => if (!in_single_quote) {
                in_double_quote = !in_double_quote;
            },
            '$', ';' => if (!in_single_quote and !in_double_quote) {
                var end = i;
                while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) {
                    end -= 1;
                }
                return line[0..end];
            },
            else => {},
        }
    }
    return line;
}

// ── Element parsing ─────────────────────────────────────────────────────────

/// Parse a single element instance line. Returns error if not parseable.
pub fn parseElement(arena: Allocator, line: []const u8) !Element {
    if (line.len == 0) return error.EmptyLine;
    const prefix = std.ascii.toLower(line[0]);

    const toks = try tokenize(arena, line);
    if (toks.len < 2) return error.TooFewTokens;
    const name = toks[0];

    switch (prefix) {
        'r', 'c', 'l' => {
            // R/C/L name node1 node2 value [params...]
            if (toks.len < 4) return error.TooFewTokens;
            return .{
                .prefix = prefix,
                .name = name,
                .nodes = try arena.dupe([]const u8, toks[1..3]),
                .value = toks[3],
                .params = try parseParams(arena, toks, 4),
            };
        },
        'd' => {
            // D name anode cathode model [params...]
            if (toks.len < 4) return error.TooFewTokens;
            return .{
                .prefix = 'd',
                .name = name,
                .nodes = try arena.dupe([]const u8, toks[1..3]),
                .model = toks[3],
                .params = try parseParams(arena, toks, 4),
            };
        },
        'm' => {
            // M name D G S B model [params...]
            if (toks.len < 7) return error.TooFewTokens;
            return .{
                .prefix = 'm',
                .name = name,
                .nodes = try arena.dupe([]const u8, toks[1..5]),
                .model = toks[5],
                .params = try parseParams(arena, toks, 6),
            };
        },
        'q' => {
            // Q name C B E [S] model [params...]
            if (toks.len < 5) return error.TooFewTokens;
            var param_start: usize = toks.len;
            for (toks[1..], 1..) |tok, i| {
                if (std.mem.indexOfScalar(u8, tok, '=') != null) {
                    param_start = i;
                    break;
                }
            }
            if (param_start < 3) return error.TooFewTokens;
            const model_idx = param_start - 1;
            return .{
                .prefix = 'q',
                .name = name,
                .nodes = try arena.dupe([]const u8, toks[1..model_idx]),
                .model = toks[model_idx],
                .params = try parseParams(arena, toks, param_start),
            };
        },
        'j' => {
            // J name D G S model [params...]
            if (toks.len < 5) return error.TooFewTokens;
            return .{
                .prefix = 'j',
                .name = name,
                .nodes = try arena.dupe([]const u8, toks[1..4]),
                .model = toks[4],
                .params = try parseParams(arena, toks, 5),
            };
        },
        'v', 'i' => {
            // V/I name n+ n- [value]
            if (toks.len < 3) return error.TooFewTokens;
            return .{
                .prefix = prefix,
                .name = name,
                .nodes = try arena.dupe([]const u8, toks[1..3]),
                .value = if (toks.len > 3) toks[3] else null,
            };
        },
        'e', 'g' => {
            // E/G name n+ n- nc+ nc- gain_or_expr
            if (toks.len < 6) return error.TooFewTokens;
            return .{
                .prefix = prefix,
                .name = name,
                .nodes = try arena.dupe([]const u8, toks[1..5]),
                .value = toks[5],
            };
        },
        'f', 'h' => {
            // F/H name n+ n- vname gain
            if (toks.len < 5) return error.TooFewTokens;
            return .{
                .prefix = prefix,
                .name = name,
                .nodes = try arena.dupe([]const u8, toks[1..3]),
                .model = toks[3], // controlling voltage source name
                .value = toks[4],
            };
        },
        'b' => {
            // B name n+ n- V={expr} or I={expr}
            if (toks.len < 4) return error.TooFewTokens;
            return .{
                .prefix = 'b',
                .name = name,
                .nodes = try arena.dupe([]const u8, toks[1..3]),
                .value = toks[3],
            };
        },
        'x' => {
            // X name node... subckt_name [key=val...]
            if (toks.len < 3) return error.TooFewTokens;
            var param_start: usize = toks.len;
            for (toks[1..], 1..) |tok, i| {
                if (std.mem.indexOfScalar(u8, tok, '=') != null) {
                    param_start = i;
                    break;
                }
            }
            const subckt_idx = param_start - 1;
            if (subckt_idx < 2) return error.TooFewTokens;
            return .{
                .prefix = 'x',
                .name = name,
                .nodes = try arena.dupe([]const u8, toks[1..subckt_idx]),
                .model = toks[subckt_idx],
                .params = try parseParams(arena, toks, param_start),
            };
        },
        else => return error.UnknownPrefix,
    }
}

// ── Token / param helpers ───────────────────────────────────────────────────

/// Split line into whitespace-delimited tokens (arena-allocated).
fn tokenize(arena: Allocator, line: []const u8) ![]const []const u8 {
    var toks: List([]const u8) = .{};
    var iter = std.mem.tokenizeAny(u8, line, " \t");
    while (iter.next()) |tok| {
        try toks.append(arena, tok);
    }
    return toks.items;
}

/// Parse key=value params from token list starting at `start` index.
fn parseParams(arena: Allocator, toks: []const []const u8, start: usize) ![]const Param {
    if (start >= toks.len) return &.{};
    var result: List(Param) = .{};
    for (toks[start..]) |tok| {
        if (parseOneParam(tok)) |p| {
            try result.append(arena, p);
        }
    }
    return result.items;
}

/// Parse a single "key=value" token. Returns null if no '=' found or key is empty.
fn parseOneParam(tok: []const u8) ?Param {
    const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return null;
    if (eq == 0) return null;
    return .{
        .key = tok[0..eq],
        .val = if (eq + 1 < tok.len) tok[eq + 1 ..] else "",
    };
}

/// Lowercase a string slice (arena-allocated copy).
fn toLowerSlice(arena: Allocator, s: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf;
}

/// Case-insensitive prefix check.
fn startsWithLower(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "parse simple netlist with MOSFET" {
    const source =
        \\* Simple Inverter
        \\.subckt inv in out vdd vss
        \\M1 out in vdd vdd sky130_fd_pr__pfet_01v8 W=1u L=0.18u
        \\M2 out in vss vss sky130_fd_pr__nfet_01v8 W=0.5u L=0.18u
        \\.ends inv
        \\.end
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const netlist = try parseNetlist(arena, source);

    try std.testing.expectEqualStrings("Simple Inverter", netlist.title);
    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);

    const sc = netlist.subckts[0];
    try std.testing.expectEqualStrings("inv", sc.name);
    try std.testing.expectEqual(@as(usize, 4), sc.ports.len);
    try std.testing.expectEqual(@as(usize, 2), sc.elements.len);

    const m1 = sc.elements[0];
    try std.testing.expectEqual(@as(u8, 'm'), m1.prefix);
    try std.testing.expectEqualStrings("M1", m1.name);
    try std.testing.expectEqual(@as(usize, 4), m1.nodes.len);
    try std.testing.expectEqualStrings("sky130_fd_pr__pfet_01v8", m1.model.?);
    try std.testing.expectEqual(@as(usize, 2), m1.params.len);
    try std.testing.expectEqualStrings("W", m1.params[0].key);
    try std.testing.expectEqualStrings("1u", m1.params[0].val);
}

test "parse continuation lines" {
    const source =
        \\* Test
        \\R1 a b 10k
        \\+ m=2
        \\.end
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const netlist = try parseNetlist(arena, source);
    try std.testing.expectEqual(@as(usize, 1), netlist.top_elements.len);

    const r1 = netlist.top_elements[0];
    try std.testing.expectEqualStrings("R1", r1.name);
    try std.testing.expectEqual(@as(usize, 1), r1.params.len);
    try std.testing.expectEqualStrings("m", r1.params[0].key);
}

test "parse inline comments" {
    const line = "R1 a b 10k $ this is a comment";
    const trimmed = trimInlineComment(line);
    try std.testing.expectEqualStrings("R1 a b 10k", trimmed);
}

test "parse subcircuit instance (X)" {
    const source =
        \\* test
        \\X1 in out vdd vss inv W=1u
        \\.end
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const netlist = try parseNetlist(arena, source);
    try std.testing.expectEqual(@as(usize, 1), netlist.top_elements.len);

    const x1 = netlist.top_elements[0];
    try std.testing.expectEqual(@as(u8, 'x'), x1.prefix);
    try std.testing.expectEqualStrings("X1", x1.name);
    try std.testing.expectEqualStrings("inv", x1.model.?);
    try std.testing.expectEqual(@as(usize, 4), x1.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), x1.params.len);
}

test "parse .model and .global" {
    const source =
        \\* test
        \\.model NMOD nmos
        \\.model PMOD pmos
        \\.global vdd gnd
        \\.end
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const netlist = try parseNetlist(arena, source);
    try std.testing.expectEqual(@as(usize, 2), netlist.models.len);
    try std.testing.expectEqualStrings("NMOD", netlist.models[0].name);
    try std.testing.expectEqualStrings("nmos", netlist.models[0].kind);
    try std.testing.expectEqual(@as(usize, 2), netlist.globals.len);
    try std.testing.expectEqualStrings("vdd", netlist.globals[0]);
}

test "parse voltage and current sources" {
    const source =
        \\* test
        \\V1 vdd 0 1.8
        \\I1 out 0 10u
        \\.end
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const netlist = try parseNetlist(arena, source);
    try std.testing.expectEqual(@as(usize, 2), netlist.top_elements.len);

    const v1 = netlist.top_elements[0];
    try std.testing.expectEqual(@as(u8, 'v'), v1.prefix);
    try std.testing.expectEqualStrings("1.8", v1.value.?);
    try std.testing.expectEqual(@as(usize, 2), v1.nodes.len);
}

test "parse BJT with substrate" {
    const source =
        \\* test
        \\Q1 col base emit sub QNPN area=2
        \\.end
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const netlist = try parseNetlist(arena, source);
    try std.testing.expectEqual(@as(usize, 1), netlist.top_elements.len);

    const q1 = netlist.top_elements[0];
    try std.testing.expectEqual(@as(u8, 'q'), q1.prefix);
    try std.testing.expectEqualStrings("QNPN", q1.model.?);
    try std.testing.expectEqual(@as(usize, 4), q1.nodes.len);
    try std.testing.expectEqualStrings("col", q1.nodes[0]);
    try std.testing.expectEqual(@as(usize, 1), q1.params.len);
    try std.testing.expectEqualStrings("area", q1.params[0].key);
}
