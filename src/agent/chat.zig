const std = @import("std");
const mcp = @import("types.zig");

pub fn buildSystemPrompt(arena: std.mem.Allocator, sch_summary: ?[]const u8, pyspice_source: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(arena);

    try w.writeAll(
        \\You are Schemify's circuit design assistant. You help design analog and digital circuits.
        \\
        \\IMPORTANT RULES:
        \\1. You write PySpice-RS Python code to define circuits. Never try to manipulate schematic geometry directly.
        \\2. Use the write_pyspice tool to set the circuit definition.
        \\3. Use read_pyspice to see the current circuit definition.
        \\4. Use read_documentation / write_documentation for design notes.
        \\5. Use validate_circuit, check_connectivity, drc_check for verification.
        \\
        \\PySpice-RS code should define a Circuit object. Example:
        \\```python
        \\from pyspice_rs import Circuit
        \\from pyspice_rs.unit import *
        \\circuit = Circuit('Common Source Amplifier')
        \\circuit.V('dd', 'vdd', circuit.gnd, 1.8)
        \\circuit.M(1, 'out', 'in', circuit.gnd, circuit.gnd, model='nmos', w=10e-6, l=180e-9)
        \\circuit.R('load', 'vdd', 'out', 10e3)
        \\```
        \\
    );

    if (sch_summary) |summary| {
        try w.writeAll("\nCurrent schematic context:\n");
        try w.writeAll(summary);
        try w.writeByte('\n');
    }

    if (pyspice_source) |src| {
        try w.writeAll("\nCurrent PySpice source:\n```python\n");
        try w.writeAll(src);
        try w.writeAll("\n```\n");
    }

    return buf.items;
}

/// Format a chat message as JSON for the LLM API.
pub fn formatMessage(arena: std.mem.Allocator, role: []const u8, content: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(arena);
    try w.writeAll("{\"role\":\"");
    try w.writeAll(role);
    try w.writeAll("\",\"content\":");
    try mcp.writeJsonStr(w, content);
    try w.writeByte('}');
    return buf.items;
}

/// Format an array of messages as JSON array.
pub fn formatMessages(arena: std.mem.Allocator, messages: []const struct { role: []const u8, content: []const u8 }) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(arena);
    try w.writeByte('[');
    for (messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        const formatted = try formatMessage(arena, msg.role, msg.content);
        try w.writeAll(formatted);
    }
    try w.writeByte(']');
    return buf.items;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "buildSystemPrompt basic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const prompt = try buildSystemPrompt(a, null, null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "pyspice_rs") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "write_pyspice") != null);
}

test "buildSystemPrompt with context" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const prompt = try buildSystemPrompt(a, "5 instances, 3 nets", "circuit = Circuit('test')");
    try std.testing.expect(std.mem.indexOf(u8, prompt, "5 instances") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "circuit = Circuit('test')") != null);
}

test "formatMessage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const msg = try formatMessage(a, "user", "hello world");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"user\"") != null);
}
