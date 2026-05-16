const std = @import("std");
const Allocator = std.mem.Allocator;

pub const VaPort = struct {
    name: []const u8,
    direction: Direction,

    pub const Direction = enum(u2) { input, output, inout };
};

pub const VaParam = struct {
    name: []const u8,
    default_value: ?[]const u8 = null,
};

pub const VaModule = struct {
    name: []const u8,
    ports: []const VaPort,
    params: []const VaParam,
    source: []const u8,
};

pub fn parseVerilogA(arena: Allocator, source: []const u8) !?VaModule {
    // 1. Find `module <name> (<ports>);`
    var mod_name: ?[]const u8 = null;
    var port_names: std.ArrayListUnmanaged([]const u8) = .{};
    var ports: std.ArrayListUnmanaged(VaPort) = .{};
    var params: std.ArrayListUnmanaged(VaParam) = .{};

    // Track which ports have explicit direction declarations
    var has_direction = std.StringHashMapUnmanaged(VaPort.Direction){};

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        // Skip preprocessor directives
        if (line[0] == '`') continue;

        // Skip single-line comments
        if (std.mem.startsWith(u8, line, "//")) continue;

        // Strip trailing comments
        const effective = if (std.mem.indexOf(u8, line, "//")) |ci| std.mem.trimRight(u8, line[0..ci], " \t") else line;

        // Module declaration: `module <name> (<port1>, <port2>, ...);`
        if (mod_name == null) {
            if (std.mem.startsWith(u8, effective, "module ")) {
                const rest = std.mem.trim(u8, effective["module ".len..], " \t");
                // Find the opening paren
                const paren_start = std.mem.indexOf(u8, rest, "(") orelse continue;
                mod_name = try arena.dupe(u8, std.mem.trim(u8, rest[0..paren_start], " \t"));

                // Extract port list (may span multiple lines if no closing paren)
                const after_paren = rest[paren_start + 1 ..];
                if (std.mem.indexOf(u8, after_paren, ")")) |paren_end| {
                    const port_list = after_paren[0..paren_end];
                    try parsePortList(arena, port_list, &port_names);
                }
                continue;
            }
            continue;
        }

        // Direction declarations: `input <port1>, <port2>;`
        if (parseDirectionLine(effective, .input)) |name_list| {
            try recordDirections(arena, name_list, .input, &has_direction);
            continue;
        }
        if (parseDirectionLine(effective, .output)) |name_list| {
            try recordDirections(arena, name_list, .output, &has_direction);
            continue;
        }
        if (parseDirectionLine(effective, .inout)) |name_list| {
            try recordDirections(arena, name_list, .inout, &has_direction);
            continue;
        }

        // Parameter declarations: `parameter real <name> = <value>;`
        if (std.mem.startsWith(u8, effective, "parameter ")) {
            if (try parseParameter(arena, effective)) |param| {
                try params.append(arena, param);
            }
            continue;
        }
    }

    if (mod_name == null) return null;

    // Build port list preserving declaration order, applying directions
    for (port_names.items) |pname| {
        const dir = has_direction.get(pname) orelse .inout;
        try ports.append(arena, .{
            .name = pname,
            .direction = dir,
        });
    }

    return .{
        .name = mod_name.?,
        .ports = try arena.dupe(VaPort, ports.items),
        .params = try arena.dupe(VaParam, params.items),
        .source = source,
    };
}

pub fn isVerilogAFile(content: []const u8) bool {
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    var has_module = false;
    var has_analog = false;
    while (it.next()) |raw| {
        lines += 1;
        if (lines > 100) break;
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "module ")) has_module = true;
        if (std.mem.indexOf(u8, trimmed, "analog begin") != null or
            std.mem.indexOf(u8, trimmed, "analog ") != null) has_analog = true;
        if (std.mem.startsWith(u8, trimmed, "electrical ") or
            std.mem.startsWith(u8, trimmed, "inout ")) has_analog = true;
    }
    return has_module and has_analog;
}

// ── Internal helpers ────────────────────────────────────────────────────────

fn parsePortList(arena: Allocator, list: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var tok = std.mem.splitScalar(u8, list, ',');
    while (tok.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (name.len > 0) {
            try out.append(arena, try arena.dupe(u8, name));
        }
    }
}

fn parseDirectionLine(line: []const u8, dir: VaPort.Direction) ?[]const u8 {
    const prefix = switch (dir) {
        .input => "input ",
        .output => "output ",
        .inout => "inout ",
    };
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    // Strip trailing semicolon
    const trimmed = std.mem.trimRight(u8, rest, " \t;");
    return trimmed;
}

fn recordDirections(
    arena: Allocator,
    name_list: []const u8,
    dir: VaPort.Direction,
    map: *std.StringHashMapUnmanaged(VaPort.Direction),
) !void {
    var tok = std.mem.splitScalar(u8, name_list, ',');
    while (tok.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (name.len > 0) {
            try map.put(arena, try arena.dupe(u8, name), dir);
        }
    }
}

fn parseParameter(arena: Allocator, line: []const u8) !?VaParam {
    // `parameter real <name> = <value>;` or `parameter integer <name> = <value>;`
    const rest = line["parameter ".len..];
    const trimmed = std.mem.trim(u8, rest, " \t");

    // Skip the type keyword (real, integer)
    var after_type: []const u8 = trimmed;
    for ([_][]const u8{ "real ", "integer " }) |type_kw| {
        if (std.mem.startsWith(u8, trimmed, type_kw)) {
            after_type = trimmed[type_kw.len..];
            break;
        }
    }
    if (std.mem.eql(u8, after_type, trimmed)) return null; // no recognized type

    const name_rest = std.mem.trim(u8, after_type, " \t");

    // Split on '='
    if (std.mem.indexOf(u8, name_rest, "=")) |eq_pos| {
        const name = std.mem.trim(u8, name_rest[0..eq_pos], " \t");
        const val_raw = std.mem.trim(u8, name_rest[eq_pos + 1 ..], " \t;");
        if (name.len == 0) return null;
        return .{
            .name = try arena.dupe(u8, name),
            .default_value = if (val_raw.len > 0) try arena.dupe(u8, val_raw) else null,
        };
    } else {
        // No default value
        const name = std.mem.trimRight(u8, name_rest, " \t;");
        if (name.len == 0) return null;
        return .{
            .name = try arena.dupe(u8, name),
            .default_value = null,
        };
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "isVerilogAFile — detects Verilog-A" {
    const source =
        \\module opamp(out, inp, inn);
        \\  electrical out, inp, inn;
        \\  analog begin
        \\    V(out) <+ 1000 * (V(inp) - V(inn));
        \\  end
        \\endmodule
    ;
    try std.testing.expect(isVerilogAFile(source));
}

test "isVerilogAFile — ignores plain Verilog" {
    const source =
        \\module counter(clk, rst, count);
        \\  input clk, rst;
        \\  output [3:0] count;
        \\  always @(posedge clk)
        \\    count <= count + 1;
        \\endmodule
    ;
    try std.testing.expect(!isVerilogAFile(source));
}

test "isVerilogAFile — rejects empty content" {
    try std.testing.expect(!isVerilogAFile(""));
    try std.testing.expect(!isVerilogAFile("// just a comment\n"));
}

test "parseVerilogA — simple module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\module amp(out, inp, inn, vdd, vss);
        \\  output out;
        \\  input inp, inn;
        \\  inout vdd, vss;
        \\  electrical out, inp, inn, vdd, vss;
        \\  parameter real gain = 100.0;
        \\  parameter real bw = 1e6;
        \\  analog begin
        \\    V(out) <+ gain * (V(inp) - V(inn));
        \\  end
        \\endmodule
    ;
    const va = (try parseVerilogA(a, source)).?;
    try std.testing.expectEqualStrings("amp", va.name);
    try std.testing.expectEqual(@as(usize, 5), va.ports.len);
    try std.testing.expectEqual(VaPort.Direction.output, va.ports[0].direction);
    try std.testing.expectEqual(VaPort.Direction.input, va.ports[1].direction);
    try std.testing.expectEqual(VaPort.Direction.input, va.ports[2].direction);
    try std.testing.expectEqual(VaPort.Direction.inout, va.ports[3].direction);
    try std.testing.expectEqual(@as(usize, 2), va.params.len);
    try std.testing.expectEqualStrings("gain", va.params[0].name);
    try std.testing.expectEqualStrings("100.0", va.params[0].default_value.?);
    try std.testing.expectEqualStrings("bw", va.params[1].name);
    try std.testing.expectEqualStrings("1e6", va.params[1].default_value.?);
}

test "parseVerilogA — no direction defaults to inout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\module res(p, n);
        \\  electrical p, n;
        \\  parameter real r = 1000.0;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / r;
        \\  end
        \\endmodule
    ;
    const va = (try parseVerilogA(a, source)).?;
    try std.testing.expectEqualStrings("res", va.name);
    try std.testing.expectEqual(@as(usize, 2), va.ports.len);
    try std.testing.expectEqual(VaPort.Direction.inout, va.ports[0].direction);
    try std.testing.expectEqual(VaPort.Direction.inout, va.ports[1].direction);
    try std.testing.expectEqual(@as(usize, 1), va.params.len);
}

test "parseVerilogA — integer parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\module dac(out, clk);
        \\  output out;
        \\  input clk;
        \\  electrical out, clk;
        \\  parameter integer bits = 8;
        \\  analog begin
        \\    V(out) <+ 0;
        \\  end
        \\endmodule
    ;
    const va = (try parseVerilogA(a, source)).?;
    try std.testing.expectEqual(@as(usize, 1), va.params.len);
    try std.testing.expectEqualStrings("bits", va.params[0].name);
    try std.testing.expectEqualStrings("8", va.params[0].default_value.?);
}

test "parseVerilogA — returns null for non-module content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expect(try parseVerilogA(arena.allocator(), "// just a comment") == null);
    try std.testing.expect(try parseVerilogA(arena.allocator(), "") == null);
}

test "parseVerilogA — preserves original source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\module buf(out, inp);
        \\  output out;
        \\  input inp;
        \\  electrical out, inp;
        \\  analog begin
        \\    V(out) <+ V(inp);
        \\  end
        \\endmodule
    ;
    const va = (try parseVerilogA(arena.allocator(), source)).?;
    try std.testing.expectEqual(source.len, va.source.len);
    try std.testing.expect(std.mem.eql(u8, source, va.source));
}

test "parseVerilogA — with preprocessor directives and comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\`include "constants.vams"
        \\`include "disciplines.vams"
        \\
        \\// Simple opamp
        \\module opamp(out, inp, inn);
        \\  output out;
        \\  input inp, inn;
        \\  electrical out, inp, inn;
        \\  parameter real gain = 1000.0; // open-loop gain
        \\  analog begin
        \\    V(out) <+ gain * (V(inp) - V(inn));
        \\  end
        \\endmodule
    ;
    const va = (try parseVerilogA(arena.allocator(), source)).?;
    try std.testing.expectEqualStrings("opamp", va.name);
    try std.testing.expectEqual(@as(usize, 3), va.ports.len);
    try std.testing.expectEqual(@as(usize, 1), va.params.len);
    try std.testing.expectEqualStrings("1000.0", va.params[0].default_value.?);
}
